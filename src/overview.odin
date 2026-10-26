package k4

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"
import "logic"

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
	label: string, // a named workspace's name ("web"), else empty
	wins: [dynamic]Prev_Win,
}

Ov :: struct {
	cards: [dynamic]Ov_Card,
	cur, win: int, // the picked card, and its picked window (-1: the card)
	hi: int, // the match ↑↓ is on
	toast: string,
	hypr: bool,
	ipc: linux.Fd,
	f7, f8, f8b, f9, f9b, f10, f10b, f11, f11b, f12, f12b, f14b, f15, f16, f16b, f24b: ^Font,
	outputs_line: string, // "DP-1 3440×1440 · HDMI-A-1" for the header
	x, y, w, h: int, // the window as drawn (buffer px)
}

ov_setup :: proc(a: ^App) {
	o := new(Ov)
	a.ov = o
	o.win, o.ipc = -1, -1
	fixture := os.get_env("K4_BAR_WORKSPACES", context.temp_allocator) != "" // tests: never the real compositor
	o.hypr = !fixture && hypr_dir() != ""
	if !o.hypr && !fixture do if fd, ok := ipc_connect(); ok do o.ipc = fd
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	o.f7, o.f8, o.f9, o.f10, o.f11, o.f12, o.f15, o.f16 = reg(a, 7), reg(a, 8), reg(a, 9), reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 15), reg(a, 16)
	o.f8b, o.f9b, o.f10b, o.f11b, o.f12b, o.f14b, o.f16b, o.f24b = bld(a, 8), bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 14), bld(a, 16), bld(a, 24)
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
		append(&o.cards, Ov_Card{ws = w, name = strings.clone(name), label = named ? strings.clone(name) : "", wins = p.wins})
	}
	o.cur = clamp(o.cur, 0, max(len(o.cards) - 1, 0))
	o.outputs_line = ""
	if o.hypr {
		if mb, ok := hypr_request("j/monitors"); ok {
			M :: struct { name: string, width, height: int }
			ms: []M
			if json.unmarshal(mb, &ms, allocator = context.temp_allocator) == nil {
				parts := make([dynamic]string, 0, 4, context.temp_allocator)
				for m, i in ms do append(&parts, i == 0 ? fmt.tprintf("%s %d×%d", m.name, m.width, m.height) : m.name)
				o.outputs_line = strings.join(parts[:], " · ")
			}
		}
	} else {
		seen := make(map[string]bool, 4, context.temp_allocator)
		parts := make([dynamic]string, 0, 4, context.temp_allocator)
		for c in o.cards do if c.ws.output != "" && !seen[c.ws.output] { seen[c.ws.output] = true; append(&parts, c.ws.output) }
		o.outputs_line = strings.join(parts[:], " · ")
	}
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
	o.toast = fmt.aprintf("TERMINATED · %s", strings.to_upper(w.app, context.temp_allocator))
	o.win = -1
	ov_reload(a)
}

// ⇧↵: the focused window to the picked workspace (it stays where it was focused).
@(private)
ov_move :: proc(a: ^App) {
	o := a.ov
	from := -1
	for c, i in o.cards do if c.ws.focused { from = i; break }
	if from < 0 || from == o.cur { o.toast = "SELECT ANOTHER SECTOR AS TARGET"; return }
	src := -1
	for w, i in o.cards[from].wins do if w.focused { src = i; break }
	if src < 0 && len(o.cards[from].wins) > 0 do src = 0
	if src < 0 { o.toast = "NO WINDOW TO TRANSFER"; return }
	w := o.cards[from].wins[src]
	dst := o.cards[o.cur].ws.name
	if o.hypr do hypr_dispatch_lua(strings.concatenate({"hl.dsp.window.move({ workspace = \"", dst, "\", follow = false })"}, context.temp_allocator), strings.concatenate({"movetoworkspacesilent ", dst}, context.temp_allocator))
	else if o.ipc >= 0 do ipc_query(o.ipc, IPC_RUN_COMMAND, fmt.tprintf("move container to workspace \"%s\"", dst), context.temp_allocator)
	o.toast = fmt.aprintf("TRANSFER COMPLETE · %s → %s", strings.to_upper(w.app, context.temp_allocator), ws_hud_label(o.cards[o.cur]))
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

// The HUD design's palette, taken from the theme: its background darkened for the window, the
// accent for everything lit, red for alarms, green for the link; lines and panels are the
// background mixed toward the accent and the foreground. K4_OVERVIEW_ACCENT=#RRGGBB overrides
// the accent.
HUD :: struct { bg, panel, screen, fg, dim, faint, line, acc, hot, ok, card, card_sel, win, hint, meter: u32 }
hud :: proc(t: logic.Theme) -> HUD {
	acc := t.accent
	if v := os.get_env("K4_OVERVIEW_ACCENT", context.temp_allocator); len(v) == 7 && v[0] == '#' {
		if n, ok := strconv.parse_u64_of_base(v[1:], 16); ok do acc = u32(n)
	}
	bg := mix(t.bg, 0, 0.35)
	return {bg = bg, panel = mix(bg, t.fg, 0.04), screen = mix(t.bg, 0, 0.5), fg = t.fg_bright, dim = t.fg_dim,
		faint = mix(bg, t.fg_dim, 0.45), line = mix(bg, acc, 0.16), acc = acc, hot = t.red, ok = t.green,
		card = mix(bg, t.fg, 0.015), card_sel = mix(bg, acc, 0.07), win = mix(bg, t.fg, 0.05),
		hint = mix(t.fg_dim, bg, 0.35), meter = mix(bg, acc, 0.1)}
}

// Text with letter spacing (the HUD's tracked capitals), and its width.
@(private)
spaced_w :: proc(f: ^Font, s: string, sp: int) -> int {
	w, n := 0, 0
	for r in s { w += tw(f, utf8.runes_to_string({r}, context.temp_allocator)); n += 1 }
	return w + sp * max(n - 1, 0)
}
@(private)
spaced :: proc(cv: ^Canvas, f: ^Font, s: string, x, y, h: int, c: u32, sp: int, glow := false) {
	xx := x
	for r in s {
		ch := utf8.runes_to_string({r}, context.temp_allocator)
		if glow { // a faint halo: the glyph again, offset, see-through
			for d in ([4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do text_in(cv, f, ch, xx + d[0], y + d[1], h, argb(c, 0x40))
		}
		text_in(cv, f, ch, xx, y, h, argb(c, 0xff))
		xx += tw(f, ch) + sp
	}
}
@(private)
spaced_fit :: proc(f: ^Font, s: string, sp, w: int) -> string { // cut with an ellipsis to fit
	if spaced_w(f, s, sp) <= w do return s
	r := utf8.string_to_runes(s, context.temp_allocator)
	for n := len(r) - 1; n > 0; n -= 1 {
		t := strings.concatenate({utf8.runes_to_string(r[:n], context.temp_allocator), "…"}, context.temp_allocator)
		if spaced_w(f, t, sp) <= w do return t
	}
	return ""
}

// A rectangle with its top-right and bottom-left corners cut (the HUD's cards).
@(private)
cut_rect :: proc(cv: ^Canvas, x, y, w, h, c: int, color: u32) {
	for yy in 0 ..< h {
		l, r := x, x + w
		if yy < c do r = x + w - (c - yy)
		if yy >= h - c do l = x + (yy - (h - c))
		fill_rect(cv, l, y + yy, r - l, 1, color)
	}
}

@(private)
pad2 :: proc(n: int) -> string { return n < 10 ? fmt.tprintf("0%d", n) : fmt.tprintf("%d", n) }

@(private)
ws_hud_label :: proc(c: Ov_Card) -> string {
	return c.label != "" ? fmt.tprintf("WS %s %s", pad2(c.ws.num), strings.to_upper(c.label, context.temp_allocator)) : fmt.tprintf("WS %s", pad2(c.ws.num))
}

// One window in a card's miniature, HUD style: lit (focused, the cursor's, a match) in the
// accent with a glow, alarms in pink, the rest faint; title bar, the mark large, the app.
@(private)
ov_mini :: proc(a: ^App, cv: ^Canvas, S, mx, my, MW, MH: int, wi: Prev_Win, on, hit, faded: bool, H: HUD) -> [4]int {
	o := a.ov
	g := wi.full ? 0 : 3 * S
	bx := mx + int(wi.x * f32(MW)) + g
	by := my + int(wi.y * f32(MH)) + g
	bw := max(int(wi.w * f32(MW)) - 2 * g, 8 * S)
	bh := max(int(wi.h * f32(MH)) - 2 * g, 8 * S)
	bx, by = clamp(bx, mx, mx + MW - bw), clamp(by, my, my + MH - bh)
	lit := on || hit || wi.focused
	col := wi.urgent ? H.hot : (lit ? H.acc : H.faint)
	if wi.floating do fill_rect(cv, bx + 2 * S, by + 8 * S, bw, bh, argb(0, 0xcc))
	if lit || wi.urgent do for k in 1 ..= 3 do rounded_rect(cv, bx - k * S, by - k * S, bw + 2 * k * S, bh + 2 * k * S, 0, 0, f32(S), argb(wi.urgent ? H.hot : H.acc, u8(0x30 / k)))
	fill_rect(cv, bx, by, bw, bh, argb(H.screen, 0xff))
	fill_rect(cv, bx, by, bw, bh, wi.urgent ? argb(H.hot, 0x1f) : (on ? argb(H.acc, 0x38) : (lit ? argb(H.acc, 0x14) : argb(H.win, 0xff))))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(on ? H.fg : col, 0xff))
	top := by + S
	if !wi.full {
		th := 10 * S
		text_in(cv, o.f7, ellipsize(o.f7, wi.title, bw - 8 * S), bx + 3 * S, top, th, argb(lit ? H.fg : H.dim, 0xff))
		fill_rect(cv, bx, top + th, bw, S, argb(on ? H.fg : col, 0xff))
		top += th + S
	}
	small := bw < int(f32(MW) * 0.45) || bh < int(f32(MH) * 0.45)
	mf := small ? o.f11b : o.f16b
	app := strings.to_upper(wi.app, context.temp_allocator)
	total := int(mf.line_h) + 3 * S + int(o.f7.line_h)
	cy := top + max((by + bh - top - total) / 2, 0)
	mc := wi.urgent ? H.hot : (lit ? H.acc : H.dim)
	if cy + int(mf.line_h) <= by + bh {
		mw := spaced_w(mf, wi.mono, S)
		spaced(cv, mf, wi.mono, bx + (bw - mw) / 2, cy, int(mf.line_h), mc, S, lit || wi.urgent)
	}
	if cy + total <= by + bh {
		aw := spaced_w(o.f7, app, 2 * S)
		if aw <= bw - 6 * S do spaced(cv, o.f7, app, bx + (bw - aw) / 2, cy + int(mf.line_h) + 3 * S, int(o.f7.line_h), H.dim, 2 * S)
	}
	if faded do fill_rect(cv, bx - 3 * S, by - 3 * S, bw + 6 * S, bh + 6 * S, argb(H.card, 0xbf))
	return {bx, by, bw, bh}
}

ov_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	o := a.ov
	H := hud(a.theme)
	canvas_clear(cv)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(0x02060A, 0xb8)) // the dimmed desktop
	w := min(OV_W * S, cv.w - 40 * S)
	h := min(OV_H * S, cv.h - 40 * S)
	x, y := (cv.w - w) / 2, (cv.h - h) / 2
	o.x, o.y, o.w, o.h = x, y, w, h
	fill_rect(cv, x, y, w, h, argb(H.bg, 0xff))
	for gx := x; gx < x + w; gx += 32 * S do fill_rect(cv, gx, y, S, h, argb(H.acc, 0x0b)) // the grid
	for gy := y; gy < y + h; gy += 32 * S do fill_rect(cv, x, gy, w, S, argb(H.acc, 0x0b))
	for sy := y; sy < y + h; sy += 3 * S do fill_rect(cv, x, sy, w, S, argb(0xffffff, 0x06)) // scanlines
	rounded_rect(cv, x, y, w, h, 0, 0, f32(S), argb(H.line, 0xff))
	cl := 26 * S
	for c in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) { // the corner brackets
		cx := c[0] == 0 ? x : x + w - cl
		cy := c[1] == 0 ? y : y + h - cl
		fill_rect(cv, cx, c[1] == 0 ? cy : cy + cl - 2 * S, cl, 2 * S, argb(H.acc, 0xff))
		fill_rect(cv, c[0] == 0 ? cx : cx + cl - 2 * S, cy, 2 * S, cl, argb(H.acc, 0xff))
	}
	hit_add(a, x, y, w, h, .Web, -1, -1)
	q := ov_query(a)
	hits := ov_hits(a)
	// header: the title · the query box · the link and outputs
	hy, hh := y, 64 * S
	px := x + 30 * S
	title := "◢ K4://OVERVIEW"
	tw1 := spaced_w(o.f14b, title, 3 * S)
	sub := "WORKSPACE MATRIX · SUPER+TAB"
	tw2 := spaced_w(o.f9, sub, 3 * S)
	ty := hy + (hh - int(o.f14b.line_h) - 3 * S - int(o.f9.line_h)) / 2
	spaced(cv, o.f14b, title, px, ty, int(o.f14b.line_h), H.acc, 3 * S, true)
	spaced(cv, o.f9, sub, px, ty + int(o.f14b.line_h) + 3 * S, int(o.f9.line_h), H.dim, 3 * S)
	px += max(tw1, tw2) + 22 * S
	link := o.hypr ? "HYPRLAND IPC · LINKED" : (o.ipc >= 0 ? "SWAY IPC · LINKED" : "IPC · OFFLINE")
	outs := o.outputs_line
	t := libc_now_hms()
	line2 := outs != "" ? fmt.tprintf("%s · %s", outs, t) : t
	rw := max(spaced_w(o.f10, link, 2 * S) + 13 * S, spaced_w(o.f10, line2, 2 * S))
	rx := x + w - 30 * S - rw
	ry := hy + (hh - 2 * int(o.f10.line_h) - 3 * S) / 2
	lx := x + w - 30 * S - spaced_w(o.f10, link, 2 * S)
	fill_rect(cv, lx - 13 * S, ry + (int(o.f10.line_h) - 6 * S) / 2, 6 * S, 6 * S, argb(o.hypr || o.ipc >= 0 ? H.ok : H.hot, 0xff))
	spaced(cv, o.f10, link, lx, ry, int(o.f10.line_h), H.fg, 2 * S)
	spaced(cv, o.f10, line2, x + w - 30 * S - spaced_w(o.f10, line2, 2 * S), ry + int(o.f10.line_h) + 3 * S, int(o.f10.line_h), H.dim, 2 * S)
	// the query box
	bx, bw := px, rx - 22 * S - px
	bh := 36 * S
	by := hy + (hh - bh) / 2
	fill_rect(cv, bx, by, bw, bh, argb(H.panel, 0xff))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, bx, by, 3 * S, bh, argb(H.acc, 0xff))
	spaced(cv, o.f16b, "›", bx + 12 * S, by, bh, H.acc, 0, true)
	total := 0
	for c in o.cards do total += len(c.wins)
	count := q != "" ? (len(hits) == 1 ? "1 HIT" : fmt.tprintf("%d HITS", len(hits))) : fmt.tprintf("%s SECTORS · %s WINDOWS", pad2(len(o.cards)), pad2(total))
	cw := spaced_w(o.f10, count, 2 * S)
	spaced(cv, o.f10, count, bx + bw - 12 * S - cw, by, bh, q != "" ? H.acc : H.dim, 2 * S)
	qx := bx + 12 * S + tw(o.f16b, "›") + 10 * S
	qclip := bx + bw - 24 * S - cw
	qt := string(a.query[:])
	if qt == "" do text_in(cv, o.f15, "query windows · 1–9 jump · arrows navigate", qx, by, bh, argb(H.hint, 0xff), qclip)
	else do text_in(cv, o.f15, qt, qx, by, bh, argb(H.fg, 0xff), qclip)
	qs := shape(o.f15, qt)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	caret := qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)])
	fill_rect(cv, caret, by + (bh - int(o.f15.line_h)) / 2, max(S, 2), int(o.f15.line_h), argb(H.acc, 0xff))
	fill_rect(cv, x, hy + hh, w, S, argb(H.line, 0xff))
	// footer: » status · the hints
	fh := 38 * S
	fy := y + h - fh
	fill_rect(cv, x, fy, w, S, argb(H.line, 0xff))
	status := o.toast
	if status == "" {
		if q != "" do status = fmt.tprintf("SCANNING · %d SIGNAL%s FOUND", len(hits), len(hits) == 1 ? "" : "S")
		else if o.cur < len(o.cards) do status = fmt.tprintf("TARGET · %s · %d WINDOWS", ws_hud_label(o.cards[o.cur]), len(o.cards[o.cur].wins))
	}
	sc := o.toast != "" ? H.acc : H.dim
	spaced(cv, o.f10b, "»", x + 30 * S, fy, fh, sc, 0, o.toast != "")
	HK: [][2]string
	switch {
	case q != "": HK = {{"↑↓", "NEXT MATCH"}, {"↵", "ENGAGE"}, {"ESC", "CLEAR"}}
	case o.win >= 0: HK = {{"TAB", "CYCLE"}, {"↵", "FOCUS"}, {"⇧↵", "TRANSFER"}, {"X", "TERMINATE"}, {"ESC", "BACK"}}
	case: HK = {{"←→↑↓", "SECTOR"}, {"↵", "JUMP"}, {"1–9", "DIRECT"}, {"TAB", "WINDOWS"}, {"⇧↵", "TRANSFER"}, {"ESC", "CLOSE"}}
	}
	hw := 0
	for k in HK do hw += tw(o.f10b, k[0]) + 10 * S + 6 * S + spaced_w(o.f10, k[1], 2 * S) + 18 * S
	hx := x + w - 30 * S - hw + 18 * S
	spaced(cv, o.f10, spaced_fit(o.f10, status, 2 * S, hx - 18 * S - (x + 30 * S + 14 * S)), x + 30 * S + 14 * S, fy, fh, sc, 2 * S, o.toast != "")
	for k in HK {
		kw := tw(o.f10b, k[0]) + 10 * S
		kh := 16 * S
		fill_rect(cv, hx, fy + (fh - kh) / 2, kw, kh, argb(H.panel, 0xff))
		rounded_rect(cv, hx, fy + (fh - kh) / 2, kw, kh, 0, 0, f32(S), argb(H.acc, 0x59))
		text_in(cv, o.f10b, k[0], hx + 5 * S, fy + (fh - kh) / 2, kh, argb(H.acc, 0xff))
		hx += kw + 6 * S
		spaced(cv, o.f10, k[1], hx, fy, fh, H.dim, 2 * S)
		hx += spaced_w(o.f10, k[1], 2 * S) + 18 * S
	}
	// the cards: 4 to a row, cut corners
	gx, gy := x + 30 * S, hy + hh + S + 20 * S
	gw, gh := w - 60 * S, fy - 16 * S - gy
	cols := 4
	rows := max((len(o.cards) + cols - 1) / cols, 1)
	gap := 18 * S
	cardw := (gw - (cols - 1) * gap) / cols
	cardh := (gh - (rows - 1) * gap) / rows
	for c, ci in o.cards {
		cx := gx + (ci % cols) * (cardw + gap)
		cy := gy + (ci / cols) * (cardh + gap)
		on := ci == o.cur
		ws := c.ws
		n := len(c.wins)
		any_hit := q == ""
		for wv in c.wins do if ov_match(wv, q) { any_hit = true; break }
		cut := 16 * S
		if on do for k in 1 ..= 4 do cut_rect(cv, cx - k * 2 * S, cy - k * 2 * S, cardw + k * 4 * S, cardh + k * 4 * S, cut + k * S, argb(H.acc, u8(0x12 / k + 2)))
		edge := on ? argb(H.acc, 0xff) : (ws.urgent ? argb(H.hot, 0x88) : (ws.focused ? argb(H.acc, 0x80) : argb(H.line, 0xff)))
		cut_rect(cv, cx, cy, cardw, cardh, cut, edge)
		cut_rect(cv, cx + S, cy + S, cardw - 2 * S, cardh - 2 * S, cut - S, argb(on ? H.card_sel : H.card, 0xff))
		// header: 02 · NAME / meta · tag
		hh2 := 40 * S
		hit_add(a, cx, cy, cardw, hh2, .Row, ci, -1)
		num := pad2(ws.num)
		numc := on || ws.focused ? H.acc : (ws.urgent ? H.hot : H.fg)
		spaced(cv, o.f24b, num, cx + 12 * S, cy, hh2, numc, 0, on || ws.focused || ws.urgent)
		nx := cx + 12 * S + tw(o.f24b, num) + 10 * S
		tag, tagc, tagbg := "STANDBY", H.dim, u32(0)
		switch {
		case ws.focused: tag, tagc, tagbg = "ACTIVE", H.acc, argb(H.acc, 0x1f)
		case ws.urgent: tag, tagc, tagbg = "ALERT", H.hot, argb(H.hot, 0x1a)
		case ws.visible: tag, tagc = fmt.tprintf("LIVE · %s", strings.to_upper(ws.output, context.temp_allocator)), H.acc
		case n == 0: tag, tagc = "IDLE", H.faint
		}
		tgw := spaced_w(o.f9b, tag, 2 * S) + 10 * S
		tgx := cx + cardw - 12 * S - tgw
		tgy := cy + (hh2 - 14 * S) / 2
		if tagbg != 0 do fill_rect(cv, tgx, tgy, tgw, 14 * S, tagbg)
		rounded_rect(cv, tgx, tgy, tgw, 14 * S, 0, 0, f32(S), argb(tagc, 0xff))
		spaced(cv, o.f9b, tag, tgx + 5 * S, tgy, 14 * S, tagc, 2 * S)
		name := c.label != "" ? strings.to_upper(c.label, context.temp_allocator) : "UNASSIGNED"
		meta := fmt.tprintf("%s · %s", n == 0 ? "NO WINDOWS" : (n == 1 ? "1 WINDOW" : fmt.tprintf("%d WINDOWS", n)), strings.to_upper(ws.output, context.temp_allocator))
		nmw := tgx - 10 * S - nx
		ny := cy + (hh2 - int(o.f11b.line_h) - 2 * S - int(o.f9.line_h)) / 2
		spaced(cv, o.f11b, spaced_fit(o.f11b, name, 3 * S, nmw), nx, ny, int(o.f11b.line_h), n == 0 && !on ? H.dim : H.fg, 3 * S)
		spaced(cv, o.f9, spaced_fit(o.f9, meta, 2 * S, nmw), nx, ny + int(o.f11b.line_h) + 2 * S, int(o.f9.line_h), H.dim, 2 * S)
		// the meter: a segment per window, 8 at most
		my0 := cy + hh2
		segw := (cardw - 24 * S - 7 * 3 * S) / 8
		for i in 0 ..< 8 {
			sxx := cx + 12 * S + i * (segw + 3 * S)
			lit := i < n
			sc2 := lit ? (ws.urgent ? H.hot : (on || ws.focused ? H.acc : H.dim)) : H.meter
			if lit && (on || ws.focused) do fill_rect(cv, sxx - S, my0 - S, segw + 2 * S, 5 * S, argb(sc2, 0x40))
			fill_rect(cv, sxx, my0, segw, 3 * S, argb(sc2, 0xff))
		}
		// the miniature: 16:9 on a fine grid
		mx, my := cx + 10 * S, my0 + 3 * S + 6 * S
		MW := cardw - 20 * S
		MH := MW * 9 / 16
		fill_rect(cv, mx, my, MW, MH, argb(H.screen, 0xff))
		for gx2 := mx; gx2 < mx + MW; gx2 += 12 * S do fill_rect(cv, gx2, my, S, MH, argb(H.acc, 0x0f))
		for gy2 := my; gy2 < my + MH; gy2 += 12 * S do fill_rect(cv, mx, gy2, MW, S, argb(H.acc, 0x0f))
		rounded_rect(cv, mx, my, MW, MH, 0, 0, f32(S), argb(H.line, 0xff))
		if n == 0 {
			l1, l2 := "NO SIGNAL", "— IDLE SECTOR —"
			w1, w2 := spaced_w(o.f10, l1, 3 * S), spaced_w(o.f8, l2, 2 * S)
			yy := my + (MH - int(o.f10.line_h) - 4 * S - int(o.f8.line_h)) / 2
			spaced(cv, o.f10, l1, mx + (MW - w1) / 2, yy, int(o.f10.line_h), H.dim, 3 * S)
			spaced(cv, o.f8, l2, mx + (MW - w2) / 2, yy + int(o.f10.line_h) + 4 * S, int(o.f8.line_h), H.faint, 2 * S)
		}
		for pass in 0 ..< 2 do for wv, wi in c.wins {
			if wv.hidden || (pass == 0) == wv.floating do continue
			r := ov_mini(a, cv, S, mx, my, MW, MH, wv, on && o.win == wi, q != "" && ov_match(wv, q), q != "" && !ov_match(wv, q), H)
			hit_add(a, r[0], r[1], r[2], r[3], .Item, ci, wi)
		}
		// up to three windows, then "+N MORE IN SECTOR"
		ry2 := my + MH + 6 * S
		rh := 21 * S
		for wv, wi in c.wins {
			if wi >= 3 || ry2 + rh > cy + cardh - 6 * S do break
			ron := on && o.win == wi
			if ron do fill_rect(cv, cx + S, ry2, cardw - 2 * S, rh, argb(H.acc, 0xff))
			else if wv.focused do fill_rect(cv, cx + S, ry2, 2 * S, rh, argb(H.acc, 0x99))
			rx2 := cx + 12 * S
			mc := ron ? H.bg : (wv.urgent ? H.hot : (wv.focused ? H.acc : H.dim))
			text_in(cv, o.f9b, wv.mono, rx2, ry2, rh, argb(mc, 0xff))
			rx2 += 18 * S + 7 * S
			tag2, tc2 := "", H.dim
			switch {
			case wv.urgent: tag2, tc2 = "ALERT", H.hot
			case wv.floating: tag2 = "FLOAT"
			case wv.full: tag2 = "FULL"
			case len(wv.group) > 1: tag2 = "TAB"
			case wv.focused: tag2, tc2 = "ACTIVE", H.acc
			}
			right := cx + cardw - 12 * S
			if tag2 != "" {
				tw3 := spaced_w(o.f8b, tag2, 2 * S)
				spaced(cv, o.f8b, tag2, right - tw3, ry2, rh, ron ? H.bg : tc2, 2 * S)
				right -= tw3 + 7 * S
			}
			label := fmt.tprintf("%s :: %s", strings.to_upper(wv.app, context.temp_allocator), wv.title)
			fc := ron ? H.bg : (wv.focused ? H.fg : H.dim)
			lab := ellipsize(o.f10, label, right - rx2)
			at := q != "" ? strings.index(strings.to_lower(lab, context.temp_allocator), q) : -1
			if at >= 0 && at + len(q) <= len(lab) { // the match bold in the accent
				pre, hp, post := lab[:at], lab[at:at + len(q)], lab[at + len(q):]
				text_in(cv, o.f10, pre, rx2, ry2, rh, argb(fc, 0xff))
				hx2 := rx2 + tw(o.f10, pre)
				spaced(cv, o.f10b, hp, hx2, ry2, rh, ron ? H.bg : H.acc, 0, !ron)
				text_in(cv, o.f10, post, hx2 + tw(o.f10b, hp), ry2, rh, argb(fc, 0xff))
			} else do text_in(cv, o.f10, lab, rx2, ry2, rh, argb(fc, 0xff))
			if q != "" && !ov_match(wv, q) do fill_rect(cv, cx + S, ry2, cardw - 2 * S, rh, argb(on ? H.card_sel : H.card, 0xa6))
			hit_add(a, cx, ry2, cardw, rh, .Item, ci, wi)
			ry2 += rh
		}
		if n > 3 && ry2 + rh <= cy + cardh - 6 * S {
			text_in(cv, o.f9b, fmt.tprintf("+%d", n - 3), cx + 12 * S, ry2, rh, argb(H.dim, 0xff))
			spaced(cv, o.f10, "MORE IN SECTOR", cx + 12 * S + 25 * S, ry2, rh, H.dim, S)
		}
		if on { // ◉ LOCK on the top edge
			lk := "◉ LOCK"
			lw := spaced_w(o.f8b, lk, 3 * S) + 10 * S
			lx2 := cx + cardw - 18 * S - lw
			fill_rect(cv, lx2, cy - 7 * S, lw, 13 * S, argb(H.bg, 0xff))
			spaced(cv, o.f8b, lk, lx2 + 5 * S, cy - 7 * S, 13 * S, H.acc, 3 * S, true)
		}
		fade: u8 = 0
		if q != "" && !any_hit do fade = 0xa6
		else if n == 0 && !on do fade = 0x4d
		if fade > 0 do cut_rect(cv, cx - 9 * S, cy - 9 * S, cardw + 18 * S, cardh + 18 * S, cut + 9 * S, argb(H.bg, fade))
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
