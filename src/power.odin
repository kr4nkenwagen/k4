package k4

import "core:fmt"
import "core:os"
import "core:strings"

// --power: the system menu (the Kestrel design's System menu, Super+Esc). Centred 920×420 on
// the focused output: a tile per action in a row, a band that says what the picked one does
// (or asks first), key hints. ←→ pick, ↵ or the tile's letter runs it; tiles marked ask=
// ask first (y / n, ←→ choose); an inhibitor (a package upgrade) turns Yes into Force.
// The script gives the tiles on stdin and runs what k4 prints (the tile's id, "id!" forced):
//   H <user@host> <info>                  the header's right column
//   T <id> <label> <key> <glyph> <command> <what it does> [flags…]
//       ask=<question>|<body>   ask first        off=<short>|<why>   can't run (dimmed)
//       warn=<title>|<body>     a caution in the band when picked     block   an inhibitor stops it
//   A <body>                              asking: what is open (apps), instead of the tile's body
//   I <who and why>                       an inhibitor: block tiles need Force

PW_W, PW_H :: 920, 420

Pw_Tile :: struct {
	id, label, key, glyph, cmd, what: string,
	ask_q, ask_body, off_short, off_why, warn_title, warn_body: string,
	block: bool,
}

Pw :: struct {
	tiles: [dynamic]Pw_Tile,
	who, info, apps, inhibit: string,
	cur: int,
	ask: int, // the tile asking (-1: none)
	cf: int, // asking: 0 Yes/Force, 1 No
	toast: string,
	f9, f10, f11, f13b, f14b, f10b, f12b, icon: ^Font,
	x, y, w, h: int,
}

pw_setup :: proc(a: ^App, data: string) {
	p := new(Pw)
	a.pw = p
	p.ask, p.cf = -1, 1
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	p.f9, p.f10, p.f11, p.icon = reg(a, 9), reg(a, 10), reg(a, 11), reg(a, 30)
	p.f10b, p.f12b, p.f13b, p.f14b = bld(a, 10), bld(a, 12), bld(a, 13), bld(a, 14)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "H": p.who, p.info = get(f, 1), get(f, 2)
		case "A": p.apps = get(f, 1)
		case "I": p.inhibit = get(f, 1)
		case "T":
			t := Pw_Tile{id = get(f, 1), label = get(f, 2), key = get(f, 3), glyph = get(f, 4), cmd = get(f, 5), what = get(f, 6)}
			two :: proc(v: string) -> (string, string) {
				i := strings.index_byte(v, '|')
				return i < 0 ? strings.clone(v) : strings.clone(v[:i]), i < 0 ? "" : strings.clone(v[i + 1:])
			}
			for fl in f[min(7, len(f)):] {
				switch {
				case strings.has_prefix(fl, "ask="): t.ask_q, t.ask_body = two(fl[4:])
				case strings.has_prefix(fl, "off="): t.off_short, t.off_why = two(fl[4:])
				case strings.has_prefix(fl, "warn="): t.warn_title, t.warn_body = two(fl[5:])
				case fl == "block": t.block = true
				}
			}
			if t.id != "" do append(&p.tiles, t)
		}
	}
	for t, i in p.tiles do if t.id == "lock" { p.cur = i; break } // Lock picked, as the design opens it
}

@(private = "file")
pw_run :: proc(a: ^App, i: int) {
	p := a.pw
	if i < 0 || i >= len(p.tiles) do return
	t := p.tiles[i]
	p.cur = i
	if t.off_short != "" { p.toast = t.off_why; return }
	if t.ask_q != "" { p.ask, p.cf, p.toast = i, 1, ""; return }
	pw_done(a, t.id)
}

@(private = "file")
pw_done :: proc(a: ^App, out: string) { a.result = out; a.exit = 0; a.done = true }

@(private = "file")
pw_blocked :: proc(p: ^Pw) -> bool { return p.ask >= 0 && p.tiles[p.ask].block && p.inhibit != "" }

@(private = "file")
pw_yes :: proc(a: ^App) {
	p := a.pw
	if p.ask < 0 do return
	t := p.tiles[p.ask]
	pw_done(a, pw_blocked(p) ? strings.concatenate({t.id, "!"}) : t.id)
}

@(private = "file")
pw_no :: proc(a: ^App) { a.pw.ask, a.pw.toast = -1, "Cancelled" }

pw_key :: proc(a: ^App, k: Key, ch: rune, text: string) -> bool {
	p := a.pw
	n := len(p.tiles)
	if p.ask >= 0 {
		switch {
		case text == "y" || text == "Y" || (k == .Enter && p.cf == 0): pw_yes(a)
		case text == "n" || text == "N" || k == .Escape || (k == .Enter && p.cf == 1): pw_no(a)
		case k == .Left || k == .Right || k == .Tab || k == .Back_Tab: p.cf = 1 - p.cf
		case: return false
		}
		return true
	}
	switch {
	case k == .Escape: a.exit = 1; a.done = true
	case n == 0: return false
	case k == .Right || k == .Tab || k == .Down: p.cur, p.toast = (p.cur + 1) % n, ""
	case k == .Left || k == .Back_Tab || k == .Up: p.cur, p.toast = (p.cur + n - 1) % n, ""
	case k == .Home: p.cur = 0
	case k == .End: p.cur = n - 1
	case k == .Enter || text == " ": pw_run(a, p.cur)
	case text != "":
		for t, i in p.tiles do if strings.equal_fold(t.key, text) { pw_run(a, i); return true }
		return false
	case: return false
	}
	return true
}

pw_pointer_move :: proc(a: ^App, x, y: int) -> bool {
	p := a.pw
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Item: if p.ask < 0 && p.cur != h.a { p.cur, p.toast = h.a, ""; return true }
	case .Confirm: if p.ask >= 0 && p.cf != h.a { p.cf = h.a; return true }
	}
	return false
}

pw_click :: proc(a: ^App, x, y, button: int) -> bool {
	p := a.pw
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true } // off the window: close
	if button != 1 do return false
	#partial switch h.kind {
	case .Item: if p.ask < 0 do pw_run(a, h.a)
	case .Confirm: if h.a == 0 do pw_yes(a); else do pw_no(a)
	}
	return true
}

// ---------- drawing ----------

pw_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	p := a.pw
	t := a.theme
	H := hud(t)
	canvas_clear(cv)
	w := min(PW_W * S, cv.w - 40 * S)
	h := min(PW_H * S, cv.h - 40 * S)
	x, y := (cv.w - w) / 2, (cv.h - h) / 2
	p.x, p.y, p.w, p.h = x, y, w, h
	fill_rect(cv, x, y, w, h, argb(H.bg, a.bg_alpha))
	frame(cv, x, y, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 26)
	hit_add(a, x, y, w, h, .Web, -1, -1)
	// the header: SYSTEM / what it is · who and the uptime
	hh := 64 * S
	px := x + 30 * S
	ty := y + (hh - int(p.f13b.line_h) - 3 * S - int(p.f10.line_h)) / 2
	spaced(cv, p.f13b, "SYSTEM", px, ty, int(p.f13b.line_h), H.acc, 2 * S, true)
	text_in(cv, p.f10, "Session and power · Super+Esc", px, ty + int(p.f13b.line_h) + 3 * S, int(p.f10.line_h), argb(H.dim, 0xff))
	rx := x + w - 30 * S
	ry := y + (hh - 2 * int(p.f10.line_h) - 3 * S) / 2
	text_in(cv, p.f10, p.who, rx - tw(p.f10, p.who), ry, int(p.f10.line_h), argb(H.fg, 0xff))
	text_in(cv, p.f10, p.info, rx - tw(p.f10, p.info), ry + int(p.f10.line_h) + 3 * S, int(p.f10.line_h), argb(H.dim, 0xff))
	fill_rect(cv, x, y + hh, w, S, argb(H.line, 0xff))
	// the footer: hints · the toast
	fh := 30 * S
	fy := y + h - fh
	fill_rect(cv, x, fy, w, S, argb(H.line, 0xff))
	keys := strings.builder_make(context.temp_allocator)
	for tl, i in p.tiles do if tl.key != "" { if i > 0 do strings.write_byte(&keys, ' '); strings.write_string(&keys, tl.key) }
	HK: [][2]string
	if p.ask >= 0 do HK = {{"y", pw_blocked(p) ? "Force" : "Yes"}, {"n Esc", "No"}, {"← →", "Choose"}}
	else do HK = {{"← →", "Move"}, {"↵", "Run"}, {strings.to_string(keys), "Run directly"}, {"Esc", "Close"}}
	hx := x + 30 * S
	for k in HK {
		kw := tw(p.f10, k[0]) + 10 * S
		kh := 15 * S
		rounded_rect(cv, hx, fy + (fh - kh) / 2, kw, kh, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, p.f10, k[0], hx + 5 * S, fy, fh, argb(H.fg, 0xff))
		hx += kw + 5 * S
		text_in(cv, p.f10, k[1], hx, fy, fh, argb(H.dim, 0xff))
		hx += tw(p.f10, k[1]) + 16 * S
	}
	if p.toast != "" {
		tt := ellipsize(p.f10, p.toast, x + w - 30 * S - hx)
		text_in(cv, p.f10, tt, x + w - 30 * S - tw(p.f10, tt), fy, fh, argb(H.acc, 0xff))
	}
	// the band: what the picked tile does, a caution, or the question with Yes / No
	bh := 64 * S
	bx, bw := x + 30 * S, w - 60 * S
	by := fy - 14 * S - bh
	n := len(p.tiles)
	if n > 0 {
		cur := p.tiles[clamp(p.cur, 0, n - 1)]
		title, body, bc, bl := cur.label, cur.what, H.acc, H.line
		if cur.off_short != "" do title, body, bc = fmt.tprintf("%s unavailable", cur.label), cur.off_why, H.dim
		if cur.warn_title != "" do title, body, bc, bl = cur.warn_title, cur.warn_body, t.yellow, mix(H.bg, t.yellow, 0.33)
		asking := p.ask >= 0
		if asking {
			at := p.tiles[p.ask]
			bc, bl, title = H.hot, mix(H.bg, H.hot, 0.33), at.ask_q
			switch {
			case pw_blocked(p): body = fmt.tprintf("Blocked by %s. Forcing may break it.", p.inhibit)
			case p.apps != "": body = p.apps
			case: body = at.ask_body
			}
		}
		fill_rect(cv, bx, by, bw, bh, argb(a.theme.fg, 0x0a))
		rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(bl, 0xff))
		fill_rect(cv, bx, by, 3 * S, bh, argb(bc, 0xff))
		right := bx + bw - 16 * S
		if asking {
			labels := [2]string{pw_blocked(p) ? "Force  y" : "Yes  y", "No  n"}
			btn_h := 36 * S
			for i := 1; i >= 0; i -= 1 {
				lb := labels[i]
				btn_w := max(104 * S, tw(p.f12b, lb) + 28 * S)
				btn_x := right - btn_w
				btn_y := by + (bh - btn_h) / 2
				on := p.cf == i
				col := i == 0 ? H.hot : H.fg
				if on do fill_rect(cv, btn_x, btn_y, btn_w, btn_h, argb(i == 0 ? H.hot : H.acc, 0xff))
				rounded_rect(cv, btn_x, btn_y, btn_w, btn_h, 0, 0, f32(S), argb(i == 0 ? H.hot : H.line, 0xff))
				text_in(cv, p.f12b, lb, btn_x + (btn_w - tw(p.f12b, lb)) / 2, btn_y, btn_h, argb(on ? H.bg : col, 0xff))
				hit_add(a, btn_x, btn_y, btn_w, btn_h, .Confirm, i, 0)
				right = btn_x - 14 * S
			}
		}
		lx := bx + 16 * S
		ly := by + (bh - int(p.f14b.line_h) - 4 * S - int(p.f11.line_h)) / 2
		text_in(cv, p.f14b, ellipsize(p.f14b, title, right - lx), lx, ly, int(p.f14b.line_h), argb(bc, 0xff))
		text_in(cv, p.f11, ellipsize(p.f11, body, right - lx), lx, ly + int(p.f14b.line_h) + 4 * S, int(p.f11.line_h), argb(H.dim, 0xff))
	}
	// the tiles: a row, the top-right corner cut
	gx, gy := x + 30 * S, y + hh + S + 22 * S
	gw, gh := w - 60 * S, by - 16 * S - gy
	gap := 14 * S
	tw_ := n > 0 ? (gw - (n - 1) * gap) / n : gw
	cut := 10 * S
	for tl, i in p.tiles {
		tx := gx + i * (tw_ + gap)
		on := i == p.cur
		off := tl.off_short != ""
		danger := on && tl.ask_q != ""
		c := danger ? H.hot : H.acc
		if on {
			for k in 1 ..= 3 do cut_outline(cv, tx - k * 2 * S, gy - k * 2 * S, tw_ + k * 4 * S, gh + k * 4 * S, cut + k * S, 2 * S, argb(c, u8(0x0c / k + 1)))
			mark_sel(a, tx, gy, tw_, gh)
		}
		cut_rect(cv, tx + S, gy + S, tw_ - 2 * S, gh - 2 * S, cut - S, on ? argb(c, 0x14) : argb(t.fg, 0x0a))
		cut_outline(cv, tx, gy, tw_, gh, cut, S, argb(on ? c : H.line, 0xff))
		ih := int(p.icon.line_h)
		total := ih + 12 * S + int(p.f13b.line_h) + 12 * S + 15 * S + 12 * S + int(p.f9.line_h)
		cy := gy + (gh - total) / 2
		text_in(cv, p.icon, tl.glyph, tx + (tw_ - tw(p.icon, tl.glyph)) / 2, cy, ih, argb(on ? c : H.dim, 0xff))
		cy += ih + 12 * S
		text_in(cv, p.f13b, tl.label, tx + (tw_ - tw(p.f13b, tl.label)) / 2, cy, int(p.f13b.line_h), argb(off && !on ? H.dim : H.fg, 0xff))
		cy += int(p.f13b.line_h) + 12 * S
		if tl.key != "" {
			kw := tw(p.f10b, tl.key) + 14 * S
			kc := on ? c : H.faint
			rounded_rect(cv, tx + (tw_ - kw) / 2, cy, kw, 15 * S, 0, 0, f32(S), argb(kc, 0xff))
			text_in(cv, p.f10b, tl.key, tx + (tw_ - kw) / 2 + 7 * S, cy, 15 * S, argb(kc, 0xff))
		}
		cy += 15 * S + 12 * S
		cmd := off ? tl.off_short : tl.cmd
		cmd = ellipsize(p.f9, cmd, tw_ - 12 * S)
		text_in(cv, p.f9, cmd, tx + (tw_ - tw(p.f9, cmd)) / 2, cy, int(p.f9.line_h), argb(H.dim, 0xff))
		hit_add(a, tx, gy, tw_, gh, .Item, i, 0)
		fade: u8 = 0
		if off do fade = 0x99
		else if p.ask >= 0 && !on do fade = 0x8c
		if fade > 0 do cut_rect(cv, tx - 7 * S, gy - 7 * S, tw_ + 14 * S, gh + 14 * S, cut + 7 * S, argb(H.bg, fade))
	}
}

pw_dump :: proc(a: ^App) -> string {
	p := a.pw
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "power %s · %s", p.who, p.info)
	for tl, i in p.tiles {
		fmt.sbprintf(&sb, "%s %s %s", i == p.cur ? "*" : " ", tl.key, tl.label)
		if tl.off_short != "" do fmt.sbprintf(&sb, " (off: %s)", tl.off_short)
		fmt.sbprintln(&sb)
	}
	if p.ask >= 0 do fmt.sbprintfln(&sb, "ask %s · %s · %s", p.tiles[p.ask].ask_q, pw_blocked(p) ? "Force" : "Yes", p.cf == 0 ? "on yes" : "on no")
	if p.toast != "" do fmt.sbprintfln(&sb, "toast %s", p.toast)
	return strings.to_string(sb)
}
