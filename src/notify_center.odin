package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// --notify-center: the notification centre (the Kestrel design's, Super+N or the bar's bell):
// 420×720 at the top right under the bar. Do not disturb, then the history, newest first, an
// app with several in a group (␣ folds it). ↑↓ (j k) move, ↵ runs the picked one's action (a
// group: folds it), its buttons' letters run them, x dismisses (⇧x or on a group: the whole
// app), d do not disturb, c clears all, Esc closes. It reads and changes the service's state
// through k4 --notify-ctl's socket and follows it while open.

NC_W, NC_H :: 420, 720

Nc_Note :: struct {
	id: u32,
	app, title, body, image: string,
	urgency, progress: int,
	at: i64,
	actions: [][2]string,
}

Nc_Row :: struct {
	group: string, // a group's head: the app
	count: int, // a group: how many; a folded note: how many more
	note: int, // index in notes (-1 for a head)
	head: bool, // the first note of an app without a group head: "App · title"
}

Nc :: struct {
	notes: [dynamic]Nc_Note,
	rows: [dynamic]Nc_Row,
	folded: map[string]bool,
	dnd, offline: bool,
	cur, scroll: int,
	toast: string,
	f9b, f10, f10b, f11, f11b, f12b, f13, f13b, f14b, icon, big: ^Font,
	list_y, list_h, content_h: int,
	row_y: [dynamic][2]int, // each row's top and height (unscrolled, buffer px)
}

nc_setup :: proc(a: ^App) {
	c := new(Nc)
	a.nc = c
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	c.f10, c.f11, c.f13, c.icon, c.big = reg(a, 10), reg(a, 11), reg(a, 13), reg(a, 18), reg(a, 36)
	c.f9b, c.f10b, c.f11b, c.f12b, c.f13b, c.f14b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 14)
	if !a.opts.popup.set { a.opts.anchor = .Top_Right; a.opts.margin = 10 }
	nc_load(a)
}

nc_size :: proc(a: ^App) -> (int, int) { return NC_W, NC_H }

// The service's state again (after a change, and every second while open).
nc_load :: proc(a: ^App) {
	c := a.nc
	text: string
	if path := os.get_env("K4_NOTIFY_LIST", context.temp_allocator); path != "" { // tests
		data, _ := os.read_entire_file(path, context.temp_allocator)
		text = string(data)
	} else {
		reply, ok := nd_ctl("list")
		c.offline = !ok
		text = reply
	}
	clear(&c.notes)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
		switch f[0] {
		case "S": c.dnd = get(f, 1) == "1"
		case "N":
			x: Nc_Note
			id, _ := strconv.parse_uint(get(f, 1))
			x.id = u32(id)
			x.app, x.title, x.body = strings.clone(get(f, 2)), strings.clone(get(f, 5)), strings.clone(get(f, 6))
			x.urgency, _ = strconv.parse_int(get(f, 3))
			at, _ := strconv.parse_i64(get(f, 4))
			x.at = at
			ok: bool
			if x.progress, ok = strconv.parse_int(get(f, 7)); !ok do x.progress = -1
			acts := make([dynamic][2]string)
			if s := get(f, 8); s != "" do for p in strings.split(s, "\x1e", context.temp_allocator) {
				i := strings.index_byte(p, 0x1f)
				if i >= 0 && p[i + 1:] != "" do append(&acts, [2]string{strings.clone(p[:i]), strings.clone(p[i + 1:])})
			}
			x.actions = acts[:]
			x.image = strings.clone(get(f, 9))
			append(&c.notes, x)
		}
	}
	nc_rows(c)
}

nc_rows :: proc(c: ^Nc) {
	clear(&c.rows)
	order := make([dynamic]string, 0, 8, context.temp_allocator)
	for x in c.notes {
		have := false
		for o in order do if o == x.app { have = true; break }
		if !have do append(&order, x.app)
	}
	for app in order {
		idx := make([dynamic]int, 0, 4, context.temp_allocator)
		for x, i in c.notes do if x.app == app do append(&idx, i)
		open := len(idx) == 1 || !c.folded[app]
		if len(idx) > 1 do append(&c.rows, Nc_Row{group = app, count = len(idx), note = -1})
		for i, k in idx {
			if !open && k > 0 do break
			append(&c.rows, Nc_Row{note = i, count = open ? 0 : len(idx) - 1, head = len(idx) == 1})
		}
	}
	c.cur = clamp(c.cur, 0, max(len(c.rows) - 1, 0))
}

// The keys a note's buttons answer to: "↵" for the first, else a letter of its label not taken.
nc_keys :: proc(x: Nc_Note) -> []string {
	out := make([]string, len(x.actions), context.temp_allocator)
	used := make(map[rune]bool, 16, context.temp_allocator)
	for r in "jkxdcn" do used[r] = true // the centre's own keys
	for p, i in x.actions {
		if i == 0 { out[i] = "↵"; continue }
		for r in strings.to_lower(p[1], context.temp_allocator) {
			if r >= 'a' && r <= 'z' && !used[r] { used[r] = true; out[i] = fmt.tprint(r); break }
		}
	}
	return out
}

@(private = "file")
nc_cmd :: proc(a: ^App, cmd: string, toast: string) {
	if os.get_env("K4_NOTIFY_LIST", context.temp_allocator) != "" { a.nc.toast = fmt.aprintf("%s  (%s)", toast, cmd); return } // tests
	nd_ctl(cmd)
	a.nc.toast = strings.clone(toast)
	nc_load(a)
}

@(private = "file")
nc_activate :: proc(a: ^App, ri: int) {
	c := a.nc
	if ri < 0 || ri >= len(c.rows) do return
	r := c.rows[ri]
	if r.note < 0 { c.folded[r.group] = !c.folded[r.group]; nc_rows(c); return }
	if r.count > 0 { c.folded[c.notes[r.note].app] = false; nc_rows(c); return }
	x := c.notes[r.note]
	if len(x.actions) == 0 { c.toast = "Nothing to run · x dismisses"; return }
	nc_cmd(a, fmt.tprintf("act %d %s", x.id, x.actions[0][0]), fmt.tprintf("%s · %s", x.actions[0][1], x.title))
}

@(private = "file")
nc_dismiss :: proc(a: ^App, ri: int, whole: bool) {
	c := a.nc
	if ri < 0 || ri >= len(c.rows) do return
	r := c.rows[ri]
	if r.note < 0 || whole {
		app := r.note < 0 ? r.group : c.notes[r.note].app
		nc_cmd(a, fmt.tprintf("dismiss-app %s", app), fmt.tprintf("Cleared %s", app))
	} else do nc_cmd(a, fmt.tprintf("dismiss %d", c.notes[r.note].id), "Dismissed")
}

nc_key :: proc(a: ^App, k: Key, ch: rune, text: string) -> bool {
	c := a.nc
	n := len(c.rows)
	switch {
	case k == .Escape: a.exit = 1; a.done = true
	case k == .Down || text == "j": c.cur, c.toast = min(c.cur + 1, max(n - 1, 0)), ""
	case k == .Up || text == "k": c.cur, c.toast = max(c.cur - 1, 0), ""
	case k == .Home: c.cur = 0
	case k == .End: c.cur = max(n - 1, 0)
	case k == .Enter: nc_activate(a, c.cur)
	case text == " ":
		if c.cur < n {
			r := c.rows[c.cur]
			app := r.note < 0 ? r.group : c.notes[r.note].app
			c.folded[app] = !c.folded[app]
			nc_rows(c)
		}
	case k == .Delete || text == "x": nc_dismiss(a, c.cur, false)
	case text == "X": nc_dismiss(a, c.cur, true)
	case text == "d": nc_cmd(a, "dnd toggle", c.dnd ? "Do not disturb off" : "Do not disturb on")
	case text == "c": nc_cmd(a, "clear", len(c.notes) > 0 ? fmt.tprintf("Cleared %d notifications", len(c.notes)) : "Nothing to clear")
	case text != "" && c.cur < n && c.rows[c.cur].note >= 0:
		x := c.notes[c.rows[c.cur].note]
		for key, i in nc_keys(x) do if key == text {
			nc_cmd(a, fmt.tprintf("act %d %s", x.id, x.actions[i][0]), fmt.tprintf("%s · %s", x.actions[i][1], x.title))
			return true
		}
		return false
	case: return false
	}
	return true
}

nc_pointer_move :: proc(a: ^App, x, y: int) -> bool { return false }

nc_click :: proc(a: ^App, x, y, button: int) -> bool {
	c := a.nc
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Row:
		if c.cur == h.a do nc_activate(a, h.a)
		else do c.cur, c.toast = h.a, ""
	case .Chip:
		c.cur = h.a
		if h.b < 0 do nc_dismiss(a, h.a, false)
		else if r := c.rows[h.a]; r.note >= 0 && h.b < len(c.notes[r.note].actions) {
			xn := c.notes[r.note]
			nc_cmd(a, fmt.tprintf("act %d %s", xn.id, xn.actions[h.b][0]), fmt.tprintf("%s · %s", xn.actions[h.b][1], xn.title))
		}
	case .Tab: nc_cmd(a, "dnd toggle", c.dnd ? "Do not disturb off" : "Do not disturb on")
	case .Confirm: nc_cmd(a, "clear", len(c.notes) > 0 ? fmt.tprintf("Cleared %d notifications", len(c.notes)) : "Nothing to clear")
	}
	return true
}

nc_scroll :: proc(a: ^App, n: int) -> bool {
	c := a.nc
	c.scroll = clamp(c.scroll + n * 48, 0, max(c.content_h - c.list_h, 0))
	return true
}

// ---------- drawing ----------

nc_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	c := a.nc
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	hh := 60 * S
	dy, dh := hh + S, 52 * S
	fh := 30 * S
	fy := h - fh
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	// the list
	list_done := false
	top := dy + dh + S
	c.list_y, c.list_h = top, fy - top
	if len(c.rows) == 0 {
		cy := top + c.list_h / 2 - 40 * S
		g := "󰂚"
		text_in(cv, c.big, g, (w - tw(c.big, g)) / 2, cy - 10 * S, 40 * S, argb(H.faint, 0xff))
		l1 := c.offline ? "Notifications are off" : "All caught up"
		l2 := c.offline ? "Start them with k4-notify daemon" : "Nothing new"
		text_in(cv, c.f14b, l1, (w - tw(c.f14b, l1)) / 2, cy + 40 * S, int(c.f14b.line_h), argb(H.fg, 0xff))
		text_in(cv, c.f11, l2, (w - tw(c.f11, l2)) / 2, cy + 40 * S + int(c.f14b.line_h) + 8 * S, int(c.f11.line_h), argb(H.dim, 0xff))
		list_done = true
	}
	if !list_done {
		// heights first, so the picked row can be kept in view
		clear(&c.row_y)
		yy := 8 * S
		for r, i in c.rows {
			rh := nc_row(a, nil, S, i, 0, w, i == c.cur, H, soft)
			gap := r.note < 0 ? 6 * S : 2 * S
			yy += gap
			append(&c.row_y, [2]int{yy, rh})
			yy += rh + 2 * S
		}
		c.content_h = yy + 12 * S
		if c.cur < len(c.row_y) {
			ry := c.row_y[c.cur]
			if ry[0] - 8 * S < c.scroll do c.scroll = max(ry[0] - 8 * S, 0)
			if ry[0] + ry[1] + 8 * S > c.scroll + c.list_h do c.scroll = ry[0] + ry[1] + 8 * S - c.list_h
		}
		c.scroll = clamp(c.scroll, 0, max(c.content_h - c.list_h, 0))
		list := Canvas{cv.px[top * cv.w:], cv.w, c.list_h}
		nhits := len(a.hits)
		for _, i in c.rows {
			ry := c.row_y[i]
			y := ry[0] - c.scroll
			if y + ry[1] < 0 || y > c.list_h do continue
			nc_row(a, &list, S, i, y, w, i == c.cur, H, soft)
		}
		for &hh2 in a.hits[nhits:] do hh2.y += top // the list's hits in the window's coordinates
		if a.sel != {} do a.sel[1] += top
		// rows cut by the list's edges: their hits only where they show
		for &hh2 in a.hits[nhits:] {
			y0, y1 := max(hh2.y, top), min(hh2.y + hh2.h, fy)
			hh2.y, hh2.h = y0, max(y1 - y0, 0)
		}
	}
	// the head and the foot over what the list drew past its edges
	for i in 0 ..< (dy + dh + S) * w do cv.px[i] = 0
	for i in fy * w ..< h * w do cv.px[i] = 0
	fill_rect(cv, 0, 0, w, dy + dh + S, argb(H.bg, a.bg_alpha))
	fill_rect(cv, 0, fy, w, h - fy, argb(H.bg, a.bg_alpha))
	// the head: NOTIFICATIONS / count · Clear all
	ty := (hh - int(c.f13b.line_h) - 3 * S - int(c.f10.line_h)) / 2
	spaced(cv, c.f13b, "NOTIFICATIONS", 20 * S, ty, int(c.f13b.line_h), H.acc, 2 * S, true)
	sub := c.offline ? "the service is not running" : (len(c.notes) > 0 ? fmt.tprintf("%d unread", len(c.notes)) : "none")
	text_in(cv, c.f10, fmt.tprintf("%s · Super+N", sub), 20 * S, ty + int(c.f13b.line_h) + 3 * S, int(c.f10.line_h), argb(H.dim, 0xff))
	cl, ck := "Clear all", "c"
	bw := tw(c.f11b, cl) + 6 * S + tw(c.f11, ck) + 20 * S
	bx, by := w - 20 * S - bw, (hh - 26 * S) / 2
	rounded_rect(cv, bx, by, bw, 26 * S, 0, 0, f32(S), argb(H.line, 0xff))
	text_in(cv, c.f11b, cl, bx + 10 * S, by, 26 * S, argb(len(c.notes) > 0 ? H.fg : H.faint, 0xff))
	text_in(cv, c.f11, ck, bx + 10 * S + tw(c.f11b, cl) + 6 * S, by, 26 * S, argb(H.dim, 0xff))
	hit_add(a, bx, by, bw, 26 * S, .Confirm, 0, 0)
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// do not disturb
	if c.dnd do fill_rect(cv, S, dy, w - 2 * S, dh, argb(H.acc, 0x0f))
	text_in(cv, c.icon, "󰖔", 20 * S, dy, dh, argb(c.dnd ? H.acc : H.dim, 0xff))
	lx := 20 * S + 18 * S + 12 * S
	ly := dy + (dh - int(c.f12b.line_h) - 3 * S - int(c.f10.line_h)) / 2
	text_in(cv, c.f12b, "Do not disturb", lx, ly, int(c.f12b.line_h), argb(H.fg, 0xff))
	text_in(cv, c.f11, "d", lx + tw(c.f12b, "Do not disturb") + 6 * S, ly, int(c.f12b.line_h), argb(H.dim, 0xff))
	text_in(cv, c.f10, c.dnd ? "On · critical alerts still show" : "Off · popups show for 6 s", lx, ly + int(c.f12b.line_h) + 3 * S, int(c.f10.line_h), argb(H.dim, 0xff))
	sw, sh := 34 * S, 18 * S
	sx, sy := w - 20 * S - sw, dy + (dh - sh) / 2
	if c.dnd do fill_rect(cv, sx, sy, sw, sh, argb(H.acc, 0xff))
	rounded_rect(cv, sx, sy, sw, sh, 0, 0, f32(S), argb(c.dnd ? H.acc : H.faint, 0xff))
	fill_rect(cv, c.dnd ? sx + sw - 3 * S - 12 * S : sx + 3 * S, sy + 3 * S, 12 * S, 12 * S, argb(c.dnd ? H.bg : H.dim, 0xff))
	hit_add(a, 0, dy, w, dh, .Tab, 0, 0)
	fill_rect(cv, 0, dy + dh, w, S, argb(H.line, 0xff))
	// the footer: hints, or what just happened
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	if c.toast != "" do text_in(cv, c.f10, ellipsize(c.f10, c.toast, w - 40 * S), 20 * S, fy, fh, argb(H.acc, 0xff))
	else {
		hx := 20 * S
		for k in ([][2]string{{"↑↓", "Move"}, {"↵", "Act"}, {"␣", "Group"}, {"x", "Dismiss"}, {"Esc", "Close"}}) {
			kw := tw(c.f10, k[0]) + 8 * S
			rounded_rect(cv, hx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, c.f10, k[0], hx + 4 * S, fy, fh, argb(H.fg, 0xff))
			hx += kw + 5 * S
			text_in(cv, c.f10, k[1], hx, fy, fh, argb(H.dim, 0xff))
			hx += tw(c.f10, k[1]) + 12 * S
		}
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

// One row of the list at y (list coordinates), its height; cv nil measures.
@(private = "file")
nc_row :: proc(a: ^App, cv: ^Canvas, S, i, y, w: int, on: bool, H: HUD, soft: u32) -> int {
	c := a.nc
	t := a.theme
	r := c.rows[i]
	if r.note < 0 { // a group's head
		rh := 34 * S
		if cv == nil do return rh
		x0, x1 := 12 * S, w - 12 * S
		if on { fill_rect(cv, x0, y, x1 - x0, rh, argb(H.acc, 0x14)); rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, rh) }
		ac := note_app_color(t, r.group)
		mx := x0 + 8 * S
		fill_rect(cv, mx, y + 8 * S, 18 * S, 18 * S, argb(ac, 0x1f))
		rounded_rect(cv, mx, y + 8 * S, 18 * S, 18 * S, 0, 0, f32(S), argb(ac, 0x55))
		m := note_mono(r.group)
		text_in(cv, c.f10b, m, mx + (18 * S - tw(c.f10b, m)) / 2, y + 8 * S, 18 * S, argb(ac, 0xff))
		nx := mx + 18 * S + 9 * S
		name := strings.to_upper(r.group, context.temp_allocator)
		spaced(cv, c.f10b, name, nx, y, rh, on ? H.fg : H.dim, S)
		nx += spaced_w(c.f10b, name, S) + 9 * S
		text_in(cv, c.f10, fmt.tprint(r.count), nx, y, rh, argb(H.dim, 0xff))
		chev := c.folded[r.group] ? " expand" : " collapse"
		text_in(cv, c.f10, chev, x1 - 8 * S - tw(c.f10, chev), y, rh, argb(H.dim, 0xff))
		hit_add(a, x0, y, x1 - x0, rh, .Row, i, 0)
		return rh
	}
	x := c.notes[r.note]
	x0, x1 := 22 * S, w - 12 * S
	cw := x1 - x0
	pl, pr := 14 * S, 10 * S
	iw := cw - pl - pr
	title := x.title
	if r.head do title = fmt.tprintf("%s · %s", x.app, x.title)
	if r.count > 0 do title = fmt.tprintf("%s  +%d", title, r.count)
	body_l: []string
	if on do body_l = wrap_text(c.f11, x.body, iw)
	else if x.body != "" do body_l = []string{ellipsize(c.f11, x.body, iw)}
	if len(body_l) > 4 do body_l = body_l[:4]
	show_acts := on && r.count == 0 && len(x.actions) > 0
	rh := 9 * S + 18 * S + (len(body_l) > 0 ? 6 * S + len(body_l) * 16 * S : 0) + (show_acts ? 8 * S + 22 * S : 0) + 10 * S
	if cv == nil do return rh
	lvl := x.urgency == 2 ? H.hot : H.acc
	edge := on ? lvl : (x.urgency == 2 ? mix(H.bg, H.hot, 0.4) : H.line)
	fillc := x.urgency == 2 ? mix(H.bg, H.hot, 0.08) : (on ? mix(H.bg, H.acc, 0.06) : mix(H.bg, t.fg, 0.03))
	stripe := x.urgency == 2 ? H.hot : (on ? H.acc : note_app_color(t, x.app))
	cut := 8 * S
	if on {
		for k in 1 ..= 2 do cut_outline(cv, x0 - k * 2 * S, y - k * 2 * S, cw + k * 4 * S, rh + k * 4 * S, cut + k * S, 2 * S, argb(lvl, u8(0x0a / k + 1)))
		mark_sel(a, x0, y, cw, rh)
	}
	cut_rect(cv, x0 + S, y + S, cw - 2 * S, rh - 2 * S, cut - S, argb(fillc, 0xff))
	cut_outline(cv, x0, y, cw, rh, cut, S, argb(edge, 0xff))
	fill_rect(cv, x0 + S, y + S, 2 * S, rh - 2 * S, argb(stripe, 0xff))
	hit_add(a, x0, y, cw, rh, .Row, i, 0)
	yy := y + 9 * S
	ago := note_ago(x.at)
	right := x1 - pr
	text_in(cv, c.f13, "×", right - 16 * S + (16 * S - tw(c.f13, "×")) / 2, yy, 18 * S, argb(on ? H.fg : H.faint, 0xff))
	hit_add(a, right - 20 * S, yy - 3 * S, 24 * S, 24 * S, .Chip, i, -1)
	right -= 16 * S + 8 * S
	text_in(cv, c.f10, ago, right - tw(c.f10, ago), yy, 18 * S, argb(H.dim, 0xff))
	right -= tw(c.f10, ago) + 8 * S
	text_in(cv, c.f12b, ellipsize(c.f12b, title, right - (x0 + pl)), x0 + pl, yy, 18 * S, argb(c.dnd && x.urgency < 2 ? soft : H.fg, 0xff))
	yy += 18 * S
	if len(body_l) > 0 {
		yy += 6 * S
		for l in body_l { text_in(cv, c.f11, l, x0 + pl, yy, 16 * S, argb(soft, 0xff)); yy += 16 * S }
	}
	if show_acts {
		yy += 8 * S
		ax := x0 + pl
		keys := nc_keys(x)
		for p, j in x.actions {
			lw := tw(c.f10b, p[1]) + 6 * S + tw(c.f10, keys[j]) + 16 * S
			if ax + lw > x1 - pr do break
			prim := j == 0
			if prim do fill_rect(cv, ax, yy, lw, 22 * S, argb(lvl, 0xff))
			rounded_rect(cv, ax, yy, lw, 22 * S, 0, 0, f32(S), argb(prim ? lvl : H.line, 0xff))
			text_in(cv, c.f10b, p[1], ax + 8 * S, yy, 22 * S, argb(prim ? H.bg : soft, 0xff))
			text_in(cv, c.f10, keys[j], ax + 8 * S + tw(c.f10b, p[1]) + 6 * S, yy, 22 * S, argb(prim ? H.bg : H.dim, 0xff))
			hit_add(a, ax, yy, lw, 22 * S, .Chip, i, j)
			ax += lw + 6 * S
		}
	}
	return rh
}

nc_dump :: proc(a: ^App) -> string {
	c := a.nc
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "centre %d · dnd %s", len(c.notes), c.dnd ? "on" : "off")
	for r, i in c.rows {
		mark := i == c.cur ? "*" : " "
		if r.note < 0 do fmt.sbprintfln(&sb, "%s [%s %d%s]", mark, r.group, r.count, c.folded[r.group] ? " folded" : "")
		else {
			x := c.notes[r.note]
			fmt.sbprintf(&sb, "%s   %s · %s", mark, x.app, x.title)
			if r.count > 0 do fmt.sbprintf(&sb, " +%d", r.count)
			fmt.sbprintln(&sb)
		}
	}
	if c.toast != "" do fmt.sbprintfln(&sb, "toast %s", c.toast)
	return strings.to_string(sb)
}
