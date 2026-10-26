package k4

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"

// --overview: every workspace at once (the Kestrel design's Overview, Super+Tab). A
// fullscreen layer on the focused output, clear of the bar, dims the desktop; the window is
// centred (1360×720 at most): a search field, a card per workspace (its hover preview at a
// larger size: the miniature, up to three windows, "N more") in a 4-wide grid, key hints.
// ←→↑↓ pick a workspace, ↵ goes there, 1–9 jump; Tab steps into its windows (↵ focuses one, x
// closes it); ⇧↵ moves the focused window to the picked workspace; typing finds windows by
// app and title across all cards (↑↓ the matches, ↵ goes). Esc clears, steps back, closes.
// Tests: K4_BAR_WORKSPACES, K4_BAR_CLIENTS and K4_BAR_MONITORS stand in for the compositor.

OV_W, OV_H :: 1360, 720

Ov_Card :: struct {
	ws: Ws,
	name: string,
	wins: [dynamic]Prev_Win,
}

Ov :: struct {
	cards: [dynamic]Ov_Card,
	cur, win: int, // the picked card, and its picked window (-1: the card)
	hi: int, // the match ↑↓ is on
	toast: string,
	hypr: bool,
	ipc: linux.Fd,
	f7, f8, f9b, f10, f11, f12, f12b, f16: ^Font,
	x, y, w, h: int, // the window as drawn (buffer px)
}

ov_setup :: proc(a: ^App) {
	o := new(Ov)
	a.ov = o
	o.win, o.ipc = -1, -1
	fixture := os.get_env("K4_BAR_WORKSPACES", context.temp_allocator) != "" // tests: never the real compositor
	o.hypr = !fixture && hypr_dir() != ""
	if !o.hypr && !fixture do if fd, ok := ipc_connect(); ok do o.ipc = fd
	o.f7, o.f8, o.f10, o.f11 = font_sized(&a.font, 7), font_sized(&a.font, 8), font_sized(&a.font, 10), font_sized(&a.font, 11)
	o.f16, o.f12 = font_sized(&a.font, 16), font_sized(&a.font, 12)
	o.f9b, o.f12b = font_sized(&a.font, 9), font_sized(&a.font, 12)
	if b, ok := bold_font(a, 9); ok do o.f9b = b
	if b, ok := bold_font(a, 12); ok do o.f12b = b
	append(&a.fonts, o.f7, o.f8, o.f9b, o.f10, o.f11, o.f12, o.f12b, o.f16)
	ov_load(a)
	for c, i in o.cards do if c.ws.focused { o.cur = i; break }
}

// The workspaces and their windows; 1–8 are always there (the grid's two rows).
ov_load :: proc(a: ^App) {
	o := a.ov
	clear(&o.cards)
	wss: [dynamic]Ws
	if path := os.get_env("K4_BAR_WORKSPACES", context.temp_allocator); path != "" {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil do if l, ok := ws_parse(data); ok do wss = l
	} else if o.hypr {
		if l, ok := hypr_workspaces(); ok do wss = l
	} else if o.ipc >= 0 {
		if l, ok := ipc_workspaces(o.ipc); ok do wss = l
	}
	out := ""
	for w in wss do if w.focused { out = w.output; break }
	if out == "" && len(wss) > 0 do out = wss[0].output
	list := make([dynamic]Ws, 0, 12, context.temp_allocator)
	for w in wss do if w.num > 0 do append(&list, w)
	for n := 1; len(list) < 8 && n <= 8; n += 1 {
		have := false
		for w in list do if w.num == n { have = true; break }
		if !have do append(&list, Ws{name = fmt.aprintf("%d", n), num = n, output = out, empty = true})
	}
	for i in 1 ..< len(list) { j := i; for j > 0 && list[j - 1].num > list[j].num { list[j - 1], list[j] = list[j], list[j - 1]; j -= 1 } }
	for w in list {
		p: Prev
		if o.hypr || os.get_env("K4_BAR_CLIENTS", context.temp_allocator) != "" do prev_load_hypr(&p, w)
		else if o.ipc >= 0 do prev_load_sway(&p, w, i32(o.ipc))
		label, named := ws_label(w)
		name := named ? label[strings.index_byte(label, ' ') + 1:] : fmt.tprintf("Workspace %d", w.num)
		append(&o.cards, Ov_Card{ws = w, name = strings.clone(name), wins = p.wins})
	}
	o.cur = clamp(o.cur, 0, max(len(o.cards) - 1, 0))
}

@(private)
ov_query :: proc(a: ^App) -> string { return strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator) }

@(private)
ov_match :: proc(w: Prev_Win, q: string) -> bool {
	if q == "" do return true
	return strings.contains(strings.to_lower(w.app, context.temp_allocator), q) || strings.contains(strings.to_lower(w.title, context.temp_allocator), q)
}

// Every matching window, card by card.
@(private)
ov_hits :: proc(a: ^App) -> [][2]int {
	o := a.ov
	q := ov_query(a)
	out := make([dynamic][2]int, 0, 8, context.temp_allocator)
	if q == "" do return out[:]
	for c, ci in o.cards do for w, wi in c.wins do if ov_match(w, q) do append(&out, [2]int{ci, wi})
	return out[:]
}

// ---------- what the keys do ----------

@(private)
ov_close :: proc(a: ^App) { a.exit = 0; a.done = true }

@(private)
ov_go :: proc(a: ^App, ci: int) {
	o := a.ov
	if ci < 0 || ci >= len(o.cards) do return
	name := o.cards[ci].ws.name
	if o.hypr do hypr_focus_workspace(name)
	else if o.ipc >= 0 do ipc_query(o.ipc, IPC_RUN_COMMAND, fmt.tprintf("workspace \"%s\"", name), context.temp_allocator)
	a.result = fmt.aprintf("workspace %s", name)
	ov_close(a)
}

@(private)
ov_focus :: proc(a: ^App, ci, wi: int) {
	o := a.ov
	if ci < 0 || ci >= len(o.cards) || wi < 0 || wi >= len(o.cards[ci].wins) do return
	addr := o.cards[ci].wins[wi].addr
	if o.hypr do hypr_focus_window(addr)
	else if o.ipc >= 0 do ipc_query(o.ipc, IPC_RUN_COMMAND, fmt.tprintf("[con_id=%s] focus", addr), context.temp_allocator)
	a.result = fmt.aprintf("window %s", addr)
	ov_close(a)
}

// x: close the picked window (Hyprland: focus it, then close the focused one, as Super+X does).
@(private)
ov_kill :: proc(a: ^App) {
	o := a.ov
	ci, wi := o.cur, o.win
	if wi < 0 || wi >= len(o.cards[ci].wins) do return
	w := o.cards[ci].wins[wi]
	if o.hypr {
		hypr_focus_window(w.addr)
		hypr_dispatch_lua("hl.dsp.window.close()", "killactive")
	} else if o.ipc >= 0 do ipc_query(o.ipc, IPC_RUN_COMMAND, fmt.tprintf("[con_id=%s] kill", w.addr), context.temp_allocator)
	o.toast = fmt.aprintf("Closed  %s", w.app)
	o.win = -1
	ov_reload(a)
}

// ⇧↵: the focused window to the picked workspace (it stays where it was focused).
@(private)
ov_move :: proc(a: ^App) {
	o := a.ov
	from := -1
	for c, i in o.cards do if c.ws.focused { from = i; break }
	if from < 0 || from == o.cur { o.toast = "Pick another workspace to move the window to"; return }
	src := -1
	for w, i in o.cards[from].wins do if w.focused { src = i; break }
	if src < 0 && len(o.cards[from].wins) > 0 do src = 0
	if src < 0 { o.toast = "No window to move"; return }
	w := o.cards[from].wins[src]
	dst := o.cards[o.cur].ws.name
	if o.hypr do hypr_dispatch_lua(strings.concatenate({"hl.dsp.window.move({ workspace = \"", dst, "\", follow = false })"}, context.temp_allocator), strings.concatenate({"movetoworkspacesilent ", dst}, context.temp_allocator))
	else if o.ipc >= 0 do ipc_query(o.ipc, IPC_RUN_COMMAND, fmt.tprintf("move container to workspace \"%s\"", dst), context.temp_allocator)
	o.toast = fmt.aprintf("Moved  %s  to %s", w.app, dst)
	ov_reload(a)
}

@(private)
ov_reload :: proc(a: ^App) {
	if os.get_env("K4_BAR_CLIENTS", context.temp_allocator) != "" do return // tests: the files do not change
	cur := a.ov.cur
	ov_load(a)
	a.ov.cur = clamp(cur, 0, max(len(a.ov.cards) - 1, 0))
}

ov_key :: proc(a: ^App, k: Key, ctrl, shift: bool, ch: rune, text: string) -> bool {
	o := a.ov
	q := ov_query(a)
	n := len(o.cards)
	if n == 0 { if k == .Escape do ov_close(a); return true }
	o.toast = ""
	hits := ov_hits(a)
	switch {
	case ctrl && (ch == 'c' || ch == 'g'): a.exit = 1; a.done = true
	case k == .Escape:
		if q != "" { clear_query(a); o.win, o.hi = -1, 0 }
		else if o.win >= 0 do o.win = -1
		else { a.exit = 1; a.done = true }
	case k == .Enter && shift: ov_move(a)
	case k == .Enter:
		if q != "" { if len(hits) > 0 { h := hits[o.hi % len(hits)]; ov_focus(a, h[0], h[1]) } }
		else if o.win >= 0 do ov_focus(a, o.cur, o.win)
		else do ov_go(a, o.cur)
	case q != "" && (k == .Down || k == .Up):
		if len(hits) > 0 {
			o.hi = (o.hi + (k == .Down ? 1 : -1) + len(hits)) % len(hits)
			o.cur, o.win = hits[o.hi][0], hits[o.hi][1]
		}
	case k == .Tab || k == .Back_Tab:
		l := len(o.cards[o.cur].wins)
		if l > 0 do o.win = o.win < 0 ? 0 : (o.win + (k == .Back_Tab ? -1 : 1) + l) % l
	case q == "" && len(text) == 1 && text[0] >= '1' && text[0] <= '9':
		for c, i in o.cards do if c.ws.num == int(text[0] - '0') { o.cur, o.win = i, -1; ov_go(a, i); break }
	case q == "" && (text == "x" || k == .Delete) && o.win >= 0: ov_kill(a)
	case k == .Left || k == .Right || k == .Up || k == .Down:
		if q != "" && (k == .Left || k == .Right) do return app_edit_key(a, k, ctrl, ch, text)
		mv := k == .Left ? -1 : (k == .Right ? 1 : (k == .Up ? -4 : 4))
		o.cur, o.win = (o.cur + mv + n) % n, -1
	case:
		before := len(a.query)
		r := app_edit_key(a, k, ctrl, ch, text)
		if len(a.query) != before {
			o.hi, o.win = 0, -1
			if hs := ov_hits(a); len(hs) > 0 do o.cur = hs[0][0]
		}
		return r
	}
	return true
}

// ---------- drawing ----------

ov_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	o := a.ov
	t := a.theme
	canvas_clear(cv)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(0, 0x80)) // the dimmed desktop
	w := min(OV_W * S, cv.w - 40 * S)
	h := min(OV_H * S, cv.h - 40 * S)
	x, y := (cv.w - w) / 2, (cv.h - h) / 2
	o.x, o.y, o.w, o.h = x, y, w, h
	fill_rect(cv, x, y, w, h, argb(t.bg, 0xff))
	rounded_rect(cv, x, y, w, h, 0, 0, f32(2 * S), argb(t.accent, 0xff))
	hit_add(a, x, y, w, h, .Web, -1, -1)
	sel := t.selection
	B := 2 * S
	q := ov_query(a)
	hits := ov_hits(a)
	// header: OVERVIEW · the search · the count · Super+Tab
	hy, hh := y + B, 50 * S
	chip := "OVERVIEW"
	cw := tw(o.f12b, chip) + 16 * S
	chh := int(o.f12b.line_h) + 8 * S
	fill_rect(cv, x + 18 * S, hy + (hh - chh) / 2, cw, chh, argb(t.accent, 0xff))
	text_in(cv, o.f12b, chip, x + 18 * S + 8 * S, hy + (hh - chh) / 2, chh, argb(t.bg, 0xff))
	key := "Super+Tab"
	kw := tw(o.f11, key) + 12 * S
	kx := x + w - 18 * S - kw
	rounded_rect(cv, kx, hy + (hh - 20 * S) / 2, kw, 20 * S, 0, 0, f32(S), argb(sel, 0xff))
	text_in(cv, o.f11, key, kx + 6 * S, hy, hh, argb(t.fg_dim, 0xff))
	total := 0
	for c in o.cards do total += len(c.wins)
	count := q != "" ? (len(hits) == 1 ? "1 match" : fmt.tprintf("%d matches", len(hits))) : fmt.tprintf("%d workspaces · %d windows", len(o.cards), total)
	cnt_x := kx - 14 * S - tw(o.f12, count)
	text_in(cv, o.f12, count, cnt_x, hy, hh, argb(t.fg_dim, 0xff))
	qx := x + 18 * S + cw + 14 * S
	qtext := string(a.query[:])
	if qtext == "" do text_in(cv, o.f16, "Type to find a window…   1–9 jump to a workspace", qx, hy, hh, argb(t.fg_dim, 0xff), cnt_x - 14 * S)
	else do text_in(cv, o.f16, qtext, qx, hy, hh, argb(t.fg, 0xff), cnt_x - 14 * S)
	qs := shape(o.f16, qtext)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	caret := qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)])
	fill_rect(cv, caret, hy + (hh - int(o.f16.line_h)) / 2, max(S, 2), int(o.f16.line_h), argb(t.accent, 0xff))
	fill_rect(cv, x + B, hy + hh, w - 2 * B, S, argb(sel, 0xff))
	// footer: hints or what happened
	fh := 32 * S
	fy := y + h - B - fh
	fill_rect(cv, x + B, fy, w - 2 * B, S, argb(sel, 0xff))
	if o.toast != "" do text_in(cv, o.f11, o.toast, x + 18 * S, fy, fh, argb(t.accent, 0xff))
	else {
		H: [][2]string
		switch {
		case q != "": H = {{"↑↓", "Next match"}, {"↵", "Go to match"}, {"Esc", "Clear"}}
		case o.win >= 0: H = {{"Tab", "Next window"}, {"↵", "Focus window"}, {"⇧↵", "Move here"}, {"x", "Close window"}, {"Esc", "Back"}}
		case: H = {{"←→↑↓", "Workspace"}, {"↵", "Go"}, {"1–9", "Jump"}, {"Tab", "Windows"}, {"⇧↵", "Move focused window here"}, {"type", "Find a window"}, {"Esc", "Close"}}
		}
		hx := x + 18 * S
		for k in H {
			kw2 := tw(o.f10, k[0]) + 10 * S
			kh := int(o.f10.line_h) + 2 * S
			fill_rect(cv, hx, fy + (fh - kh) / 2, kw2, kh, argb(sel, 0xff))
			text_in(cv, o.f10, k[0], hx + 5 * S, fy + (fh - kh) / 2, kh, argb(t.fg, 0xff))
			hx += kw2 + 5 * S
			text_in(cv, o.f11, k[1], hx, fy, fh, argb(t.fg_dim, 0xff))
			hx += tw(o.f11, k[1]) + 16 * S
		}
	}
	// the cards, four to a row
	gx, gy := x + 18 * S, hy + hh + S + 16 * S
	gw, gh := w - 36 * S, fy - 16 * S - gy
	cols := 4
	rows := max((len(o.cards) + cols - 1) / cols, 1)
	gap := 14 * S
	cardw := (gw - (cols - 1) * gap) / cols
	cardh := (gh - (rows - 1) * gap) / rows
	mf := Mini_Fonts{o.f7, o.f8, o.f9b, o.f12b}
	for c, ci in o.cards {
		cx := gx + (ci % cols) * (cardw + gap)
		cy := gy + (ci / cols) * (cardh + gap)
		on := ci == o.cur
		any_hit := q == ""
		for wv in c.wins do if ov_match(wv, q) { any_hit = true; break }
		if on do fill_rect(cv, cx, cy, cardw, cardh, argb(mix(t.bg, t.fg, 0.04), 0xff))
		rounded_rect(cv, cx, cy, cardw, cardh, 0, 0, f32(2 * S), argb(on ? t.accent : sel, 0xff))
		// the card's header: number, name, output · windows
		ch := 30 * S
		hit_add(a, cx, cy, cardw, ch, .Row, ci, -1)
		num := fmt.tprintf("%d", c.ws.num)
		nw := tw(o.f12b, num) + 12 * S
		ny := cy + (ch - 18 * S) / 2
		switch {
		case c.ws.focused: fill_rect(cv, cx + 10 * S, ny, nw, 18 * S, argb(t.accent, 0xff))
		case c.ws.urgent: fill_rect(cv, cx + 10 * S, ny, nw, 18 * S, argb(t.red, 0xff))
		case c.ws.visible: rounded_rect(cv, cx + 10 * S, ny, nw, 18 * S, 0, 0, f32(S), argb(t.accent, 0xff))
		case: rounded_rect(cv, cx + 10 * S, ny, nw, 18 * S, 0, 0, f32(S), argb(sel, 0xff))
		}
		text_in(cv, o.f12b, num, cx + 10 * S + 6 * S, ny, 18 * S, argb(c.ws.focused || c.ws.urgent ? t.bg : (c.ws.visible ? t.accent : t.fg), 0xff))
		nwin := len(c.wins)
		meta := nwin == 0 ? "empty" : (nwin == 1 ? "1 window" : fmt.tprintf("%d windows", nwin))
		mw := tw(o.f11, meta)
		text_in(cv, o.f11, meta, cx + cardw - 10 * S - mw, cy, ch, argb(t.fg_dim, 0xff))
		text_in(cv, o.f12b, ellipsize(o.f12b, c.name, cardw - 40 * S - nw - mw), cx + 10 * S + nw + 8 * S, cy, ch, argb(t.fg, 0xff))
		// the miniature, 16:9
		mx, my := cx + 8 * S, cy + ch
		MW := cardw - 16 * S
		MH := MW * 9 / 16
		fill_rect(cv, mx, my, MW, MH, argb(mix(t.bg, t.blue, 0.16), 0xff))
		if nwin == 0 do text_in(cv, o.f11, "empty", mx + (MW - tw(o.f11, "empty")) / 2, my, MH, argb(t.fg_dim, 0xff))
		for pass in 0 ..< 2 do for wv, wi in c.wins {
			if wv.hidden || (pass == 0) == wv.floating do continue
			r := mini_win(a, cv, S, mx, my, MW, MH, wv, on && o.win == wi, mf, q != "" && !ov_match(wv, q))
			hit_add(a, r[0], r[1], r[2], r[3], .Item, ci, wi)
		}
		// up to three windows, then "N more"
		ry := my + MH + 4 * S
		rh := 22 * S
		for wv, wi in c.wins {
			if wi >= 3 || ry + rh > cy + cardh - 2 * S do break
			ron := on && o.win == wi
			if ron do fill_rect(cv, cx + 2 * S, ry, cardw - 4 * S, rh, argb(t.accent, 0xff))
			rx := cx + 10 * S
			fill_rect(cv, rx, ry + 5 * S, 20 * S, 12 * S, argb(token(t, wv.tok, t.fg), 0xff))
			text_in(cv, o.f9b, wv.mono, rx + (20 * S - tw(o.f9b, wv.mono)) / 2, ry + 5 * S, 12 * S, argb(t.bg, 0xff))
			rx += 26 * S
			tag, tc := "", t.fg_dim
			switch {
			case wv.urgent: tag, tc = "URGENT", t.red
			case wv.floating: tag = "FLOAT"
			case wv.full: tag = "FULL"
			case len(wv.group) > 1: tag = "TAB"
			}
			right := cx + cardw - 10 * S
			if tag != "" {
				tw2 := tw(o.f9b, tag) + 6 * S
				rounded_rect(cv, right - tw2, ry + 5 * S, tw2, 12 * S, 0, 0, f32(S), argb(ron ? t.bg : tc, 0xff))
				text_in(cv, o.f9b, tag, right - tw2 + 3 * S, ry + 5 * S, 12 * S, argb(ron ? t.bg : tc, 0xff))
				right -= tw2 + 6 * S
			}
			label := fmt.tprintf("%s · %s", wv.app, wv.title)
			fc := ron ? t.bg : (wv.focused ? t.fg : t.fg_dim)
			lab := ellipsize(o.f11, label, right - rx)
			at := q != "" ? strings.index(strings.to_lower(lab, context.temp_allocator), q) : -1
			if at >= 0 && at + len(q) <= len(lab) { // the match bold in the accent
				pre, hitp, post := lab[:at], lab[at:at + len(q)], lab[at + len(q):]
				text_in(cv, o.f11, pre, rx, ry, rh, argb(fc, 0xff))
				hx2 := rx + tw(o.f11, pre)
				text_in(cv, o.f12b, hitp, hx2, ry, rh, argb(ron ? t.bg : t.accent, 0xff))
				text_in(cv, o.f11, post, hx2 + tw(o.f12b, hitp), ry, rh, argb(fc, 0xff))
			} else do text_in(cv, o.f11, lab, rx, ry, rh, argb(fc, 0xff))
			if q != "" && !ov_match(wv, q) do fill_rect(cv, cx + 2 * S, ry, cardw - 4 * S, rh, argb(t.bg, 0x99))
			hit_add(a, cx, ry, cardw, rh, .Item, ci, wi)
			ry += rh
		}
		if nwin > 3 && ry + rh <= cy + cardh - 2 * S {
			text_in(cv, o.f11, fmt.tprintf("+ %d more", nwin - 3), cx + 10 * S, ry, rh, argb(t.fg_dim, 0xff))
		}
		if !any_hit do fill_rect(cv, cx, cy, cardw, cardh, argb(t.bg, 0x8c))
	}
}

// ---------- the pointer ----------

ov_click :: proc(a: ^App, x, y, button: int) -> bool {
	o := a.ov
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true } // the dimmed desktop: close
	#partial switch h.kind {
	case .Row: o.cur, o.win = h.a, -1; ov_go(a, h.a)
	case .Item: o.cur, o.win = h.a, h.b; ov_focus(a, h.a, h.b)
	}
	return true
}

ov_dump :: proc(a: ^App) -> string {
	o := a.ov
	q := ov_query(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "overview %s", q != "" ? fmt.tprintf("%q · %s", q, len(ov_hits(a)) == 1 ? "1 match" : fmt.tprintf("%d matches", len(ov_hits(a)))) : fmt.tprintf("%d workspaces", len(o.cards)))
	for c, ci in o.cards {
		fmt.sbprintf(&sb, "%s %d %s:", ci == o.cur ? "*" : " ", c.ws.num, c.name)
		for w, wi in c.wins do fmt.sbprintf(&sb, " [%s%s%s]", ci == o.cur && wi == o.win ? ">" : "", w.app, q != "" && ov_match(w, q) ? " hit" : "")
		fmt.sbprintln(&sb)
	}
	if o.toast != "" do fmt.sbprintfln(&sb, "toast %s", o.toast)
	return strings.to_string(sb)
}
