package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// --tray: the system tray (the Kestrel design's Tray popup, the bar's chevron or Super+.).
// 424×524 under the bar: a filter, then NEEDS YOU (apps asking for attention, as rows with the
// thing to do), ON THE BAR (pinned: they also get an icon on the strip) and IN THE TRAY, as tiles
// four to a row; the picked app's tooltip and actions at the bottom. ↵ opens the app's own menu
// inside the popup (submenus with ›, switches, radio groups, k4's Show on the bar / Hide from the
// tray at the end); Space does what a left click does; ^P pins. The apps come on stdin
// (k4-tray list):
//   S <count>   R <command>: "ITEM VERB [ARG]" (open, event ID, pin, unpin, hide)
//   L <command>: the list again     X <command>: "ITEM [PARENT]" prints the menu as M lines:
//   M <id> <depth> <item|sep|sub> <label> <enabled 1|0> <toggle: checkmark|radio|""> <state>
//   A <item> <id> <title> <Active|Passive|NeedsAttention> <mono> <glyph> <pinned 1|0> <tooltip>

TRAY_W, TRAY_H :: 424, 524

Tray_App :: struct {
	item, id, title, status, mono, glyph, tip: string,
	pinned: bool,
}

Tray_Row :: struct {
	id: int, // dbusmenu id; -1 k4's own rows
	kind: int, // 0 item, 1 separator, 2 submenu, 3 heading
	label, toggle: string,
	enabled, on: bool,
	k4: string, // "pin", "hide"
}

Tray :: struct {
	apps: [dynamic]Tray_App,
	flat: [dynamic]int, // shown, in order: needs you, on the bar, in the tray
	lines: [dynamic][dynamic]int, // flat indices a line at a time (one row, or up to 4 tiles)
	runner, loader, menu_cmd: string,
	cur: int,
	view: int, // 0 grid, 1 menu
	menu_app: string, // the app whose menu shows
	menu: [dynamic]Tray_Row,
	mi: int,
	path: [dynamic][2]string, // the submenus entered: parent id, label
	toast: string,
	f9, f9b, f10, f10b, f11, f11b, f12, f12b, f13, f13b: ^Font,
	scroll: int,
}

tray_setup :: proc(a: ^App, data: string) {
	t := new(Tray)
	a.tray = t
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	t.f9, t.f10, t.f11, t.f12, t.f13 = reg(a, 9), reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 13)
	t.f9b, t.f10b, t.f11b, t.f12b, t.f13b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13)
	if !a.opts.popup.set { a.opts.anchor = .Top_Right; a.opts.margin = 10 }
	tray_parse(t, data)
	tray_filter(a)
	if a.opts.open != "" do for x, i in t.apps do if x.item == a.opts.open || x.id == a.opts.open { tray_open_menu(a, i); break }
}

@(private = "file")
tray_parse :: proc(t: ^Tray, data: string) {
	clear(&t.apps)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "R": t.runner = get(f, 1)
		case "L": t.loader = get(f, 1)
		case "X": t.menu_cmd = get(f, 1)
		case "A":
			append(&t.apps, Tray_App{item = get(f, 1), id = get(f, 2), title = get(f, 3), status = get(f, 4), mono = get(f, 5), glyph = get(f, 6), pinned = len(f) > 7 && f[7] == "1", tip = get(f, 8)})
		}
	}
}

@(private = "file")
tray_query :: proc(a: ^App) -> string { return strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator) }

@(private = "file")
tray_attn :: proc(x: Tray_App) -> bool { return x.status == "NeedsAttention" }

@(private = "file")
tray_status_line :: proc(x: Tray_App) -> string {
	if x.tip != "" do return x.tip
	switch x.status {
	case "NeedsAttention": return "Needs you"
	case "Passive": return "Idle"
	}
	return "Running"
}

// The groups and the lines ↑↓ move between.
tray_filter :: proc(a: ^App) {
	t := a.tray
	keep := t.cur < len(t.flat) ? t.apps[t.flat[t.cur]].item : ""
	clear(&t.flat)
	for &l in t.lines do delete(l)
	clear(&t.lines)
	q := tray_query(a)
	match :: proc(x: Tray_App, q: string) -> bool {
		return q == "" || strings.contains(strings.to_lower(x.title, context.temp_allocator), q) || strings.contains(strings.to_lower(tray_status_line(x), context.temp_allocator), q)
	}
	for g in 0 ..< 3 {
		line: [dynamic]int
		for x, i in t.apps {
			if !match(x, q) do continue
			in_g := g == 0 ? tray_attn(x) : (g == 1 ? !tray_attn(x) && x.pinned : !tray_attn(x) && !x.pinned)
			if !in_g do continue
			if g == 0 { l: [dynamic]int; append(&l, len(t.flat)); append(&t.lines, l) }
			else {
				append(&line, len(t.flat))
				if len(line) == 4 { append(&t.lines, line); line = {} }
			}
			append(&t.flat, i)
		}
		if len(line) > 0 do append(&t.lines, line)
	}
	t.cur = 0
	for v, k in t.flat do if t.apps[v].item == keep { t.cur = k; break }
}

@(private = "file")
tray_sel :: proc(t: ^Tray) -> (^Tray_App, bool) {
	if t.view == 1 {
		for &x in t.apps do if x.item == t.menu_app do return &x, true
		return nil, false
	}
	if t.cur < 0 || t.cur >= len(t.flat) do return nil, false
	return &t.apps[t.flat[t.cur]], true
}

// A command of the script, its output.
@(private = "file")
tray_run :: proc(cmd: string, args: ..string) -> string {
	if cmd == "" do return ""
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, cmd)
	for x in args { strings.write_byte(&sb, ' '); strings.write_string(&sb, sh_quote(x)) }
	_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}}, context.temp_allocator)
	return strings.trim_space(string(out))
}

@(private = "file")
tray_reload :: proc(a: ^App) {
	t := a.tray
	if t.loader == "" do return
	if out := tray_run(t.loader); out != "" { tray_parse(t, out); tray_filter(a) }
}

@(private = "file")
tray_load_menu :: proc(a: ^App) {
	t := a.tray
	clear(&t.menu)
	parent := len(t.path) > 0 ? t.path[len(t.path) - 1][0] : "0"
	text := t.menu_cmd != "" ? tray_run(t.menu_cmd, t.menu_app, parent) : os.get_env("K4_TRAY_MENU", context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 4 || f[0] != "M" || f[2] != "0" do continue // this level only; a submenu is loaded when entered
		r := Tray_Row{label = strings.clone(len(f) > 4 ? f[4] : ""), enabled = len(f) <= 5 || f[5] != "0", toggle = strings.clone(len(f) > 6 ? f[6] : ""), on = len(f) > 7 && f[7] == "1"}
		r.id, _ = strconv.parse_int(f[1])
		switch f[3] { case "sep": r.kind = 1; case "sub": r.kind = 2 }
		append(&t.menu, r)
	}
	if len(t.path) == 0 { // k4's own rows at the end
		x, _ := tray_sel(t)
		append(&t.menu, Tray_Row{id = -1, kind = 3, label = "IN K4"})
		append(&t.menu, Tray_Row{id = -1, label = "Show on the bar", toggle = "switch", on = x != nil && x.pinned, enabled = true, k4 = "pin"})
		append(&t.menu, Tray_Row{id = -1, label = "Hide from the tray", enabled = true, k4 = "hide"})
	}
	t.mi = tray_first_row(t)
}

@(private = "file")
tray_ok_row :: proc(r: Tray_Row) -> bool { return (r.kind == 0 || r.kind == 2) && r.enabled }

@(private = "file")
tray_first_row :: proc(t: ^Tray) -> int {
	for r, i in t.menu do if tray_ok_row(r) do return i
	return 0
}

tray_open_menu :: proc(a: ^App, ai: int) {
	t := a.tray
	t.menu_app = t.apps[ai].item
	t.view = 1
	clear(&t.path)
	t.toast = ""
	tray_load_menu(a)
}

@(private = "file")
tray_menu_back :: proc(a: ^App) {
	t := a.tray
	if len(t.path) > 0 { pop(&t.path); tray_load_menu(a) } else { t.view = 0; t.toast = "" }
}

// Space / a click on the picked app: what its left click does; apps without one show their menu.
@(private = "file")
tray_activate :: proc(a: ^App) {
	t := a.tray
	x, ok := tray_sel(t)
	if !ok do return
	if t.runner == "" { t.toast = fmt.aprintf("(open %s)", x.id); return } // tests
	out := tray_run(t.runner, x.item, "open")
	if out == "k4:menu" { for y, i in t.apps do if y.item == x.item { tray_open_menu(a, i); break }; return }
	a.exit = 0; a.done = true
}

@(private = "file")
tray_pin :: proc(a: ^App) {
	t := a.tray
	x, ok := tray_sel(t)
	if !ok do return
	verb := x.pinned ? "unpin" : "pin"
	if t.runner == "" { x.pinned = !x.pinned; t.toast = fmt.aprintf("(%s %s)", verb, x.id); tray_filter(a); return }
	t.toast = fmt.aprintf("%s %s", x.title, tray_run(t.runner, x.item, verb))
	tray_reload(a)
}

@(private = "file")
tray_run_row :: proc(a: ^App, i: int) {
	t := a.tray
	if i < 0 || i >= len(t.menu) do return
	r := t.menu[i]
	if !tray_ok_row(r) do return
	x, ok := tray_sel(t)
	if !ok do return
	switch {
	case r.kind == 2:
		append(&t.path, [2]string{fmt.aprint(r.id), strings.clone(r.label)})
		tray_load_menu(a)
	case r.k4 == "pin": tray_pin(a); tray_load_menu(a)
	case r.k4 == "hide":
		if t.runner == "" { t.toast = fmt.aprintf("(hide %s)", x.id); return }
		t.toast = fmt.aprintf("%s %s", x.title, tray_run(t.runner, x.item, "hide"))
		t.view = 0
		tray_reload(a)
	case:
		if t.runner == "" { t.toast = fmt.aprintf("(event %s %d)", x.id, r.id); return }
		tray_run(t.runner, x.item, "event", fmt.tprint(r.id))
		if r.toggle != "" { // a switch or a radio: stays open, the menu again
			t.toast = fmt.aprintf("%s %s", r.label, r.toggle == "radio" ? "selected" : (r.on ? "off" : "on"))
			tray_load_menu(a)
			t.mi = i
		} else { a.exit = 0; a.done = true }
	}
}

tray_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	t := a.tray
	if t.view == 1 {
		n := len(t.menu)
		step :: proc(t: ^Tray, d, n: int) {
			i := t.mi
			for _ in 0 ..< n {
				i = (i + d + n) % n
				if tray_ok_row(t.menu[i]) do break
			}
			t.mi, t.toast = i, ""
		}
		switch {
		case n > 0 && (k == .Down || text == "j"): step(t, 1, n)
		case n > 0 && (k == .Up || text == "k"): step(t, -1, n)
		case k == .Enter || text == " " || k == .Right || text == "l": tray_run_row(a, t.mi)
		case k == .Escape || k == .Left || text == "h" || k == .Backspace: tray_menu_back(a)
		case ctrl && (ch == 'c' || ch == 'g'): a.exit = 1; a.done = true
		case: return false
		}
		return true
	}
	n := len(t.flat)
	line_of :: proc(t: ^Tray, i: int) -> int {
		for l, li in t.lines do for v in l do if v == i do return li
		return -1
	}
	vmove :: proc(t: ^Tray, d: int) {
		li := line_of(t, t.cur)
		if li < 0 || li + d < 0 || li + d >= len(t.lines) do return
		col := 0
		for v, c in t.lines[li] do if v == t.cur do col = c
		nl := t.lines[li + d]
		t.cur, t.toast = nl[min(col, len(nl) - 1)], ""
	}
	switch {
	case k == .Escape:
		if len(a.query) > 0 { clear(&a.query); a.cursor = 0; tray_filter(a) } else { a.exit = 1; a.done = true }
	case k == .Right: t.cur, t.toast = min(t.cur + 1, max(n - 1, 0)), ""
	case k == .Left: t.cur, t.toast = max(t.cur - 1, 0), ""
	case k == .Down: vmove(t, 1)
	case k == .Up: vmove(t, -1)
	case k == .Enter: if n > 0 do tray_open_menu(a, t.flat[t.cur])
	case text == " " && len(a.query) == 0: tray_activate(a)
	case ctrl && ch == 'p': tray_pin(a)
	case ctrl && (ch == 'c' || ch == 'g'): a.exit = 1; a.done = true
	case:
		before := strings.clone(string(a.query[:]), context.temp_allocator)
		r := app_edit_key(a, k, ctrl, ch, text)
		if string(a.query[:]) != before do tray_filter(a)
		return r
	}
	return true
}

tray_pointer_move :: proc(a: ^App, x, y: int) -> bool {
	t := a.tray
	h, ok := hit_at(a, x, y)
	if !ok || t.view != 1 || h.kind != .Item || h.a == t.mi do return false
	t.mi = h.a
	return true
}

tray_click :: proc(a: ^App, x, y, button: int) -> bool {
	t := a.tray
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Row: // an app
		if button == 3 { t.cur = h.a; tray_open_menu(a, t.flat[h.a]); break }
		if t.cur == h.a do tray_activate(a)
		else do t.cur, t.toast = h.a, ""
	case .Item: t.mi = h.a; tray_run_row(a, h.a) // a menu row
	case .Chip:
		switch h.a {
		case 0: tray_activate(a)
		case 1: if len(t.flat) > 0 do tray_open_menu(a, t.flat[t.cur])
		case 2: tray_pin(a)
		}
	case .Confirm: tray_menu_back(a) // ‹
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
tray_box :: proc(a: ^App, cv: ^Canvas, S, x, y: int, app: Tray_App, f: ^Font) {
	c := note_app_color(a.theme, app.id)
	s := 28 * S
	fill_rect(cv, x, y, s, s, argb(c, 0x1a))
	rounded_rect(cv, x, y, s, s, 0, 0, f32(S), argb(c, 0x55))
	text_in(cv, f, app.mono, x + (s - tw(f, app.mono)) / 2, y, s, argb(c, 0xff))
}

tray_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	t := a.tray
	th := a.theme
	H := hud(th)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	sel, has := tray_sel(t)
	attn_n := 0
	for x in t.apps do if tray_attn(x) do attn_n += 1
	hh := 40 * S
	fh := 30 * S
	fy := h - fh
	if t.view == 1 do tray_draw_menu(a, cv, S, hh + S, fy, H, soft)
	else do tray_draw_grid(a, cv, S, hh + S, fy, H, soft)
	// the head and the foot over what the content drew past its edges
	for i in 0 ..< (hh + S) * w do cv.px[i] = 0
	for i in fy * w ..< h * w do cv.px[i] = 0
	fill_rect(cv, 0, 0, w, hh + S, argb(H.bg, a.bg_alpha))
	fill_rect(cv, 0, fy, w, h - fy, argb(H.bg, a.bg_alpha))
	// the head: ‹ · crumb · title · what is up
	hx := 12 * S
	if t.view == 1 {
		rounded_rect(cv, hx, (hh - 22 * S) / 2, 22 * S, 22 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, t.f12b, "‹", hx + (22 * S - tw(t.f12b, "‹")) / 2, (hh - 22 * S) / 2, 22 * S, argb(H.fg, 0xff))
		hit_add(a, hx, (hh - 22 * S) / 2, 22 * S, 22 * S, .Confirm, 0, 0)
		hx += 22 * S + 10 * S
	}
	crumb := "TRAY"
	if t.view == 1 do crumb = len(t.path) > 0 && has ? fmt.tprintf("TRAY › %s ›", strings.to_upper(sel.title, context.temp_allocator)) : "TRAY ›"
	cw := tw(t.f11b, crumb) + 12 * S
	fill_rect(cv, hx, (hh - 20 * S) / 2, cw, 20 * S, argb(H.acc, 0xff))
	text_in(cv, t.f11b, crumb, hx + 6 * S, (hh - 20 * S) / 2, 20 * S, argb(H.bg, 0xff))
	hx += cw + 10 * S
	right, rc := "", H.dim
	title := fmt.tprintf("%d app%s", len(t.apps), len(t.apps) == 1 ? "" : "s")
	if t.view == 1 {
		right = "right-click menu"
		title = has ? sel.title : ""
		if len(t.path) > 0 do title = t.path[len(t.path) - 1][1]
	} else if attn_n > 0 do right, rc = fmt.tprintf("%d need you", attn_n), H.hot
	else do right = "all quiet"
	rw := tw(t.f10, right)
	text_in(cv, t.f10, right, w - 12 * S - rw, 0, hh, argb(rc, 0xff))
	text_in(cv, t.f13b, ellipsize(t.f13b, title, w - 24 * S - rw - hx), hx, 0, hh, argb(H.fg, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the foot
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	if t.toast != "" do text_in(cv, t.f10, ellipsize(t.f10, t.toast, w - 24 * S), 12 * S, fy, fh, argb(H.acc, 0xff))
	else {
		HK := t.view == 0 ? [][2]string{{"←→↑↓", "Move"}, {"␣", "Open"}, {"↵", "Menu"}, {"^P", "Pin"}, {"Esc", "Close"}} : [][2]string{{"↑↓", "Move"}, {"↵ →", "Choose"}, {"← Esc", "Back"}}
		kx := 12 * S
		for k in HK {
			kw := tw(t.f10, k[0]) + 8 * S
			fill_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, argb(th.selection, 0xff))
			text_in(cv, t.f10, k[0], kx + 4 * S, fy, fh, argb(H.fg, 0xff))
			kx += kw + 5 * S
			text_in(cv, t.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(t.f10, k[1]) + 12 * S
		}
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

@(private = "file")
tray_draw_grid :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	t := a.tray
	th := a.theme
	w := cv.w
	// the filter
	bx, by := 12 * S, top + 10 * S
	bw, bh := w - 24 * S, 38 * S
	fill_rect(cv, bx, by, bw, bh, argb(th.fg, 0x0a))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, bx, by, 3 * S, bh, argb(H.acc, 0xff))
	text_in(cv, t.f13b, "›", bx + 10 * S, by, bh, argb(H.acc, 0xff))
	q := tray_query(a)
	qx := bx + 10 * S + tw(t.f13b, "›") + 8 * S
	qt := string(a.query[:])
	count := q != "" ? fmt.tprintf("%d of %d", len(t.flat), len(t.apps)) : ""
	if qt == "" do text_in(cv, t.f13, "Type to filter…", qx, by, bh, argb(H.hint, 0xff))
	else do text_in(cv, t.f13, qt, qx, by, bh, argb(H.fg, 0xff))
	qs := shape(t.f13, qt)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	fill_rect(cv, qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)]), by + (bh - int(t.f13.line_h)) / 2, max(S, 2), int(t.f13.line_h), argb(H.acc, 0xff))
	if count != "" do text_in(cv, t.f10, count, bx + bw - 10 * S - tw(t.f10, count), by, bh, argb(H.dim, 0xff))
	// the picked app's strip at the bottom (its height now, drawn after the list)
	_, has := tray_sel(t)
	strip_h := has && len(t.flat) > 0 ? 10 * S + int(t.f12b.line_h) + 8 * S + 24 * S + 10 * S + 10 * S : 0
	// the groups: laid out first, then drawn scrolled so the picked app stays in view
	ly := by + bh + 4 * S
	lb := fy - strip_h
	if len(t.apps) == 0 {
		l1 := "No tray apps running"
		text_in(cv, t.f13b, l1, (w - tw(t.f13b, l1)) / 2, ly + 70 * S, 20 * S, argb(H.fg, 0xff))
		yy := ly + 100 * S
		for l in wrap_text(t.f11, "Apps that put an icon in the tray (Nextcloud, Discord, Steam…) show up here. The tray module hides itself until one does.", w - 64 * S) {
			text_in(cv, t.f11, l, (w - tw(t.f11, l)) / 2, yy, 17 * S, argb(H.dim, 0xff)); yy += 17 * S
		}
		return
	}
	if len(t.flat) == 0 {
		l := fmt.tprintf("No tray app matches “%s”", string(a.query[:]))
		text_in(cv, t.f12, l, (w - tw(t.f12, l)) / 2, ly + 60 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	Place :: struct { kind, g, i, x, y, w, h, n: int } // kind 0 a head, 1 a row, 2 a tile
	places := make([dynamic]Place, 0, len(t.flat) + 3, context.temp_allocator)
	gx, gw := 12 * S, w - 24 * S
	tw4 := (gw - 3 * 6 * S) / 4
	y := 0
	k := 0
	cur_y, cur_h := 0, 0
	for g in 0 ..< 3 {
		start := k
		for k < len(t.flat) {
			x := t.apps[t.flat[k]]
			in_g := g == 0 ? tray_attn(x) : (g == 1 ? !tray_attn(x) && x.pinned : !tray_attn(x) && !x.pinned)
			if !in_g do break
			k += 1
		}
		if k == start do continue
		y += 12 * S
		append(&places, Place{kind = 0, g = g, y = y, n = k - start})
		y += int(t.f10b.line_h) + 6 * S
		for i in start ..< k {
			if g == 0 {
				append(&places, Place{kind = 1, g = g, i = i, x = gx, y = y, w = gw, h = 46 * S})
				if i == t.cur do cur_y, cur_h = y, 46 * S
				y += 46 * S + 4 * S
				continue
			}
			col := (i - start) % 4
			if col == 0 && i > start do y += 66 * S + 6 * S
			append(&places, Place{kind = 2, g = g, i = i, x = gx + col * (tw4 + 6 * S), y = y, w = tw4, h = 66 * S})
			if i == t.cur do cur_y, cur_h = y, 66 * S
		}
		if g > 0 do y += 66 * S + 4 * S
	}
	total := y + 6 * S
	lh := lb - ly
	if cur_y - 30 * S < t.scroll do t.scroll = max(cur_y - 30 * S, 0)
	if cur_y + cur_h + 6 * S > t.scroll + lh do t.scroll = cur_y + cur_h + 6 * S - lh
	t.scroll = clamp(t.scroll, 0, max(total - lh, 0))
	list := Canvas{cv.px[ly * w:], w, lh}
	nh := len(a.hits)
	heads := [3]string{"NEEDS YOU", "ON THE BAR", "IN THE TRAY"}
	hints := [3]string{"", "^P unpin", "^P pin"}
	for p in places {
		py := p.y - t.scroll
		if py + 66 * S < 0 || py > lh do continue
		switch p.kind {
		case 0: // NAME n ──── hint
			hc := p.g == 0 ? H.hot : H.dim
			spaced(&list, t.f10b, heads[p.g], gx + 2 * S, py, int(t.f10b.line_h), hc, S)
			nx := gx + 2 * S + spaced_w(t.f10b, heads[p.g], S) + 8 * S
			ns := fmt.tprint(p.n)
			text_in(&list, t.f10, ns, nx, py, int(t.f10b.line_h), argb(H.faint, 0xff))
			nx += tw(t.f10, ns) + 8 * S
			hw := tw(t.f9, hints[p.g])
			fill_rect(&list, nx, py + int(t.f10b.line_h) / 2, gx + gw - hw - 8 * S - nx, S, argb(H.line, 0xff))
			text_in(&list, t.f9, hints[p.g], gx + gw - hw, py, int(t.f10b.line_h), argb(H.faint, 0xff))
		case 1: // a row: the app, its status, the thing to do
			x := t.apps[t.flat[p.i]]
			on := p.i == t.cur
			fill_rect(&list, p.x, py, p.w, p.h, on ? argb(H.acc, 0x14) : argb(H.hot, 0x0d))
			rounded_rect(&list, p.x, py, p.w, p.h, 0, 0, f32(S), on ? argb(H.acc, 0xff) : argb(H.hot, 0x55))
			if !on do fill_rect(&list, p.x, py, 3 * S, p.h, argb(H.hot, 0xff))
			else do mark_sel(a, p.x, py + ly, p.w, p.h)
			tray_box(a, &list, S, p.x + 12 * S, py + 9 * S, x, t.f11b)
			tx := p.x + 12 * S + 28 * S + 10 * S
			cta := "Open ␣"
			cw2 := tw(t.f10b, cta) + 12 * S
			text_in(&list, t.f12b, ellipsize(t.f12b, x.title, p.x + p.w - 20 * S - cw2 - tx), tx, py + 7 * S, int(t.f12b.line_h), argb(H.fg, 0xff))
			text_in(&list, t.f10, ellipsize(t.f10, tray_status_line(x), p.x + p.w - 20 * S - cw2 - tx), tx, py + 7 * S + int(t.f12b.line_h) + 3 * S, int(t.f10.line_h), argb(H.hot, 0xff))
			rounded_rect(&list, p.x + p.w - 10 * S - cw2, py + (p.h - 18 * S) / 2, cw2, 18 * S, 0, 0, f32(S), argb(H.hot, 0xff))
			text_in(&list, t.f10b, cta, p.x + p.w - 10 * S - cw2 + 6 * S, py + (p.h - 18 * S) / 2, 18 * S, argb(H.hot, 0xff))
			hit_add(a, p.x, py, p.w, p.h, .Row, p.i, 0)
		case 2: // a tile
			x := t.apps[t.flat[p.i]]
			on := p.i == t.cur
			if on { fill_rect(&list, p.x, py, p.w, p.h, argb(H.acc, 0x14)); mark_sel(a, p.x, py + ly, p.w, p.h) }
			rounded_rect(&list, p.x, py, p.w, p.h, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
			bxx := p.x + (p.w - 28 * S) / 2
			tray_box(a, &list, S, bxx, py + 10 * S, x, t.f11b)
			dot := x.status == "Passive" ? H.faint : th.green
			fill_rect(&list, bxx + 28 * S - 3 * S, py + 10 * S + 28 * S - 3 * S, 6 * S, 6 * S, argb(dot, 0xff))
			f := on ? t.f10b : t.f10
			nm := ellipsize(f, x.title, p.w - 8 * S)
			text_in(&list, f, nm, p.x + (p.w - tw(f, nm)) / 2, py + 10 * S + 28 * S + 6 * S, int(t.f10.line_h), argb(on ? H.fg : soft, 0xff))
			if x.pinned && p.g == 1 do text_in(&list, t.f9, "◆", p.x + p.w - 5 * S - tw(t.f9, "◆"), py + 4 * S, int(t.f9.line_h), argb(H.acc, 0xff))
			hit_add(a, p.x, py, p.w, p.h, .Row, p.i, 0)
		}
	}
	for &hh2 in a.hits[nh:] {
		hh2.y += ly
		y0, y1 := max(hh2.y, ly), min(hh2.y + hh2.h, lb)
		hh2.y, hh2.h = y0, max(y1 - y0, 0)
	}
	// what ran past the list's bottom goes under the strip; the strip over it
	for i in lb * w ..< fy * w do cv.px[i] = 0
	fill_rect(cv, 0, lb, w, fy - lb, argb(H.bg, a.bg_alpha))
	if strip_h > 0 do tray_strip(a, cv, S, fy, strip_h, H, soft)
}

@(private = "file")
tray_strip :: proc(a: ^App, cv: ^Canvas, S, fy, strip_h: int, H: HUD, soft: u32) {
	t := a.tray
	th := a.theme
	w := cv.w
	sel, _ := tray_sel(t)
	sh := strip_h - 10 * S
	sy := fy - 10 * S - sh
	sx, sw := 12 * S, w - 24 * S
	fill_rect(cv, sx, sy, sw, sh, argb(th.fg, 0x0a))
	rounded_rect(cv, sx, sy, sw, sh, 0, 0, f32(S), argb(H.line, 0xff))
	c := note_app_color(th, sel.id)
	nx := sx + 12 * S
	text_in(cv, t.f12b, sel.title, nx, sy + 10 * S, int(t.f12b.line_h), argb(c, 0xff))
	tip := tray_status_line(sel^)
	tx := nx + tw(t.f12b, sel.title) + 8 * S
	text_in(cv, t.f10, ellipsize(t.f10, tip, sx + sw - 12 * S - tx), tx, sy + 10 * S, int(t.f12b.line_h), argb(soft, 0xff))
	ax, ay := nx, sy + 10 * S + int(t.f12b.line_h) + 8 * S
	acts := [3][2]string{{"Open", "␣"}, {"Menu", "↵"}, {sel.pinned ? "Unpin" : "Pin to bar", "^P"}}
	for p, i in acts {
		bw2 := tw(t.f10b, p[0]) + 6 * S + tw(t.f10, p[1]) + 16 * S
		prim := i == 0
		if prim do fill_rect(cv, ax, ay, bw2, 24 * S, argb(H.acc, 0xff))
		rounded_rect(cv, ax, ay, bw2, 24 * S, 0, 0, f32(S), argb(prim ? H.acc : H.line, 0xff))
		text_in(cv, t.f10b, p[0], ax + 8 * S, ay, 24 * S, argb(prim ? H.bg : soft, 0xff))
		text_in(cv, t.f10, p[1], ax + 8 * S + tw(t.f10b, p[0]) + 6 * S, ay, 24 * S, argb(prim ? H.bg : H.dim, 0xff))
		hit_add(a, ax, ay, bw2, 24 * S, .Chip, i, 0)
		ax += bw2 + 6 * S
	}
}

@(private = "file")
tray_draw_menu :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32) {
	t := a.tray
	th := a.theme
	w := cv.w
	sel, has := tray_sel(t)
	if !has do return
	// the app (drawn after the rows, over any scrolled past it)
	app_y := top + 12 * S
	y := app_y + 28 * S + 10 * S
	defer {
		for i in top * w ..< y * w do cv.px[i] = 0
		fill_rect(cv, 0, top, w, y - top, argb(H.bg, a.bg_alpha))
		tray_box(a, cv, S, 16 * S, app_y, sel^, t.f11b)
		nx := 16 * S + 28 * S + 10 * S
		text_in(cv, t.f12b, sel.title, nx, app_y, int(t.f12b.line_h), argb(H.fg, 0xff))
		text_in(cv, t.f10, ellipsize(t.f10, tray_status_line(sel^), w - 16 * S - nx), nx, app_y + int(t.f12b.line_h) + 3 * S, int(t.f10.line_h), argb(soft, 0xff))
	}
	if len(t.menu) == 0 {
		text_in(cv, t.f11, "This app has no menu", 16 * S, y + 10 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	// the rows, scrolled to keep the picked one in view
	rh := 30 * S
	heights := make([]int, len(t.menu), context.temp_allocator)
	total, mi_y := 0, 0
	for r, i in t.menu {
		heights[i] = r.kind == 1 ? 11 * S : (r.kind == 3 ? 10 * S + int(t.f10b.line_h) + 4 * S : rh)
		if i == t.mi do mi_y = total
		total += heights[i]
	}
	avail := fy - 8 * S - y
	if mi_y < t.scroll do t.scroll = mi_y
	if mi_y + rh > t.scroll + avail do t.scroll = mi_y + rh - avail
	t.scroll = clamp(t.scroll, 0, max(total - avail, 0))
	list := Canvas{cv.px[y * w:], w, avail}
	nh := len(a.hits)
	defer for &hh2 in a.hits[nh:] {
		hh2.y += y
		y0, y1 := max(hh2.y, y), min(hh2.y + hh2.h, y + avail)
		hh2.y, hh2.h = y0, max(y1 - y0, 0)
	}
	yy := -t.scroll
	for r, i in t.menu {
		hgt := heights[i]
		defer yy += hgt
		if yy + hgt <= 0 || yy >= avail do continue
		switch r.kind {
		case 1: fill_rect(&list, 16 * S, yy + 5 * S, w - 32 * S, S, argb(H.line, 0xff))
		case 3: spaced(&list, t.f10b, r.label, 16 * S, yy + 10 * S, int(t.f10b.line_h), H.dim, S)
		case:
			on := i == t.mi
			danger := strings.has_prefix(strings.to_lower(r.label, context.temp_allocator), "quit") || strings.has_prefix(strings.to_lower(r.label, context.temp_allocator), "exit")
			if on { fill_rect(&list, 0, yy, w, rh, argb(danger ? H.hot : H.acc, 0xff)); mark_sel(a, 0, yy + y, w, rh) }
			fg := on ? H.bg : (!r.enabled ? H.faint : (danger ? H.hot : H.fg))
			mc := on ? H.bg : H.dim
			mark := r.toggle == "radio" ? (r.on ? "●" : "○") : (r.toggle == "checkmark" ? (r.on ? "✓" : "") : "")
			if r.toggle == "radio" && r.on && !on do mc = H.acc
			text_in(&list, t.f10, mark, 16 * S, yy, rh, argb(mc, 0xff))
			lx := 16 * S + 12 * S + 10 * S
			right := w - 16 * S
			if r.toggle == "switch" { // k4's own switch
				sw, sh := 28 * S, 14 * S
				sx, sy := right - sw, yy + (rh - sh) / 2
				track := r.on ? (on ? H.bg : H.acc) : 0
				if track != 0 do fill_rect(&list, sx, sy, sw, sh, argb(track, 0xff))
				rounded_rect(&list, sx, sy, sw, sh, 0, 0, f32(S), argb(r.on ? (on ? H.bg : H.acc) : (on ? H.bg : H.faint), 0xff))
				fill_rect(&list, r.on ? sx + sw - 2 * S - 10 * S : sx + 2 * S, sy + 2 * S, 10 * S, 10 * S, argb(r.on ? (on ? H.acc : H.bg) : (on ? H.bg : H.dim), 0xff))
				right = sx - 8 * S
			} else if r.kind == 2 {
				text_in(&list, t.f10, "›", right - tw(t.f10, "›"), yy, rh, argb(mc, 0xff))
				right -= tw(t.f10, "›") + 8 * S
			} else if r.k4 == "hide" {
				m := "keeps running"
				text_in(&list, t.f10, m, right - tw(t.f10, m), yy, rh, argb(mc, 0xff))
				right -= tw(t.f10, m) + 8 * S
			}
			text_in(&list, t.f12, ellipsize(t.f12, r.label, right - lx), lx, yy, rh, argb(fg, 0xff))
			hit_add(a, 0, yy, w, rh, .Item, i, 0)
		}
	}
	_ = th
}

tray_dump :: proc(a: ^App) -> string {
	t := a.tray
	sb := strings.builder_make(context.temp_allocator)
	if t.view == 1 {
		x, _ := tray_sel(t)
		fmt.sbprintfln(&sb, "tray menu %s%s", x != nil ? x.title : "?", len(t.path) > 0 ? fmt.tprintf(" › %s", t.path[len(t.path) - 1][1]) : "")
		for r, i in t.menu {
			switch r.kind {
			case 1: fmt.sbprintln(&sb, "  ---")
			case 3: fmt.sbprintfln(&sb, "  [%s]", r.label)
			case: fmt.sbprintfln(&sb, "%s %s%s%s", i == t.mi ? "*" : " ", r.label, r.kind == 2 ? " ›" : "", r.toggle != "" ? fmt.tprintf(" (%s %s)", r.toggle, r.on ? "on" : "off") : "")
			}
		}
	} else {
		fmt.sbprintfln(&sb, "tray %d apps", len(t.apps))
		heads := [3]string{"needs you", "on the bar", "in the tray"}
		for v, i in t.flat {
			x := t.apps[v]
			g := tray_attn(x) ? 0 : (x.pinned ? 1 : 2)
			fmt.sbprintfln(&sb, "%s %s · %s", i == t.cur ? "*" : " ", x.title, heads[g])
		}
	}
	if t.toast != "" do fmt.sbprintfln(&sb, "toast %s", t.toast)
	return strings.to_string(sb)
}
