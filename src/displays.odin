package k4

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// --displays: the screens as rectangles to drag into place (Display › Arrange by dragging…).
// Each is drawn at its logical size (scale included); drag one and it snaps to another's edge
// when dropped (lined up with its top, bottom or middle when near), never overlapping. Tab
// picks a screen, the arrows move it (Alt: a finer step), r puts everything back, ↵ applies.
// From the script (sway-menu displays):
//   O <name> <w> <h> <x> <y> <builtin 1|0> <description>   a screen, logical pixels
//   R <command>   ↵ runs `<command> NAME X Y NAME X Y …`; its last line is the footer (k4:close closes)

DISPLAYS_W, DISPLAYS_H :: 820, 560

Dsp_Out :: struct { name, desc: string, w, h: f32, x, y: f32, x0, y0: f32, builtin: bool }

Displays :: struct {
	outs: [dynamic]Dsp_Out,
	runner: string,
	sel: int,
	dragging: bool,
	grab_x, grab_y: f32, // where in the rectangle it was taken, logical
	// the view: logical → window pixels, kept still while dragging so the screens don't jump
	view_f: f32,
	view_x, view_y: f32,
	view_ok: bool,
	area_x, area_y, area_w, area_h: int,
	toast: string,
	toast_hot: bool,
	f10, f11, f12b, f13b, f14b: ^Font,
}

displays_setup :: proc(a: ^App, data: string) {
	d := new(Displays)
	a.displays = d
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	d.f10, d.f11 = reg(a, 10), reg(a, 11)
	d.f12b, d.f13b, d.f14b = bld(a, 12), bld(a, 13), bld(a, 14)
	text := data
	pf :: proc(s: string) -> f32 { v, _ := strconv.parse_f32(s); return v }
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		g :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "R": d.runner = g(f, 1)
		case "O":
			o := Dsp_Out{name = g(f, 1), w = pf(g(f, 2)), h = pf(g(f, 3)), x = pf(g(f, 4)), y = pf(g(f, 5)), builtin = g(f, 6) == "1", desc = g(f, 7)}
			if o.w <= 0 || o.h <= 0 do continue
			o.x0, o.y0 = o.x, o.y
			append(&d.outs, o)
		}
	}
	if len(d.outs) > 1 do d.sel = 1 // the first other screen: the built-in one usually stays put
}

// ---------- geometry ----------

@(private = "file")
dsp_overlap :: proc(a, b: Dsp_Out) -> bool {
	return a.x < b.x + b.w - 0.5 && b.x < a.x + a.w - 0.5 && a.y < b.y + b.h - 0.5 && b.y < a.y + a.h - 0.5
}

// Where the dropped screen goes: touching another's edge, the nearest such place that overlaps
// nothing; lined up with the other's top, bottom or middle (left, right, middle) when close.
@(private = "file")
dsp_snap :: proc(d: ^Displays, i: int) {
	s := d.outs[i]
	best_d: f32 = math.F32_MAX
	best_x, best_y := s.x, s.y
	near :: proc(v, target, t: f32) -> f32 { return abs(v - target) <= t ? target : v }
	for o, j in d.outs {
		if j == i do continue
		for side in 0 ..< 4 {
			c := s
			switch side {
			case 0, 1: // right of, left of: the y slides along the edge
				c.x = side == 0 ? o.x + o.w : o.x - s.w
				c.y = clamp(s.y, o.y - s.h + 1, o.y + o.h - 1)
				t := max(s.h, o.h) * 0.12
				c.y = near(c.y, o.y, t)
				c.y = near(c.y, o.y + o.h - s.h, t)
				c.y = near(c.y, o.y + (o.h - s.h) / 2, t)
			case 2, 3: // below, above: the x slides
				c.y = side == 2 ? o.y + o.h : o.y - s.h
				c.x = clamp(s.x, o.x - s.w + 1, o.x + o.w - 1)
				t := max(s.w, o.w) * 0.12
				c.x = near(c.x, o.x, t)
				c.x = near(c.x, o.x + o.w - s.w, t)
				c.x = near(c.x, o.x + (o.w - s.w) / 2, t)
			}
			c.x, c.y = math.round(c.x), math.round(c.y)
			clash := false
			for p, k in d.outs do if k != i && dsp_overlap(c, p) { clash = true; break }
			if clash do continue
			dist := (c.x - s.x) * (c.x - s.x) + (c.y - s.y) * (c.y - s.y)
			if dist < best_d { best_d, best_x, best_y = dist, c.x, c.y }
		}
	}
	d.outs[i].x, d.outs[i].y = best_x, best_y
}

// The view that fits every screen into the area, with room around them to drag into.
@(private = "file")
dsp_fit :: proc(d: ^Displays) {
	if len(d.outs) == 0 do return
	minx, miny: f32 = math.F32_MAX, math.F32_MAX
	maxx, maxy: f32 = -math.F32_MAX, -math.F32_MAX
	for o in d.outs {
		minx, miny = min(minx, o.x), min(miny, o.y)
		maxx, maxy = max(maxx, o.x + o.w), max(maxy, o.y + o.h)
	}
	bw, bh := maxx - minx, maxy - miny
	d.view_f = min(f32(d.area_w) / bw, f32(d.area_h) / bh) * 0.6
	d.view_x = f32(d.area_x) + (f32(d.area_w) - bw * d.view_f) / 2 - minx * d.view_f
	d.view_y = f32(d.area_y) + (f32(d.area_h) - bh * d.view_f) / 2 - miny * d.view_f
	d.view_ok = true
}

@(private = "file")
dsp_screen :: proc(d: ^Displays, o: Dsp_Out) -> (x, y, w, h: int) {
	return int(d.view_x + o.x * d.view_f), int(d.view_y + o.y * d.view_f), int(o.w * d.view_f), int(o.h * d.view_f)
}

@(private = "file")
dsp_at :: proc(d: ^Displays, px, py: int) -> int {
	for i := len(d.outs) - 1; i >= 0; i -= 1 {
		x, y, w, h := dsp_screen(d, d.outs[i])
		if px >= x && px < x + w && py >= y && py < y + h do return i
	}
	return -1
}

// ---------- input ----------

@(private = "file")
dsp_apply :: proc(a: ^App) {
	d := a.displays
	minx, miny: f32 = math.F32_MAX, math.F32_MAX
	for o in d.outs { minx, miny = min(minx, o.x), min(miny, o.y) }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, d.runner)
	args := make([dynamic]string, 0, len(d.outs) * 3, context.temp_allocator)
	for o in d.outs {
		x, y := int(o.x - minx), int(o.y - miny)
		append(&args, o.name, fmt.tprint(x), fmt.tprint(y))
		fmt.sbprintf(&sb, " %s %d %d", sh_quote(o.name), x, y)
	}
	if d.runner == "" { d.toast = fmt.aprintf("(apply %s)", strings.join(args[:], " ", context.temp_allocator)); return } // tests
	_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}}, context.temp_allocator)
	lines := strings.split_lines(strings.trim_space(string(out)), context.temp_allocator)
	last := len(lines) > 0 ? lines[len(lines) - 1] : ""
	if last == "k4:close" { a.exit = 0; a.done = true; return }
	d.toast = strings.clone(last)
	for &o in d.outs { o.x0, o.y0 = o.x, o.y }
}

displays_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	d := a.displays
	n := len(d.outs)
	if n == 0 { if k == .Escape { a.exit = 1; a.done = true }; return true }
	step: f32 = alt ? 10 : 100
	switch {
	case ctrl && (ch == 'c' || ch == 'g'), k == .Escape: a.exit = 1; a.done = true
	case k == .Tab: d.sel = (d.sel + 1) % n
	case k == .Back_Tab: d.sel = (d.sel + n - 1) % n
	case k == .Left: d.outs[d.sel].x -= step
	case k == .Right: d.outs[d.sel].x += step
	case k == .Up: d.outs[d.sel].y -= step
	case k == .Down: d.outs[d.sel].y += step
	case text == "s": dsp_snap(d, d.sel); d.toast = ""
	case text == "r":
		for &o in d.outs { o.x, o.y = o.x0, o.y0 }
		d.view_ok = false
		d.toast = "Back to how they are now"
	case k == .Enter:
		for i in 0 ..< n do for j in 0 ..< n do if i != j && dsp_overlap(d.outs[i], d.outs[j]) { dsp_snap(d, i) }
		dsp_apply(a)
	case: return false
	}
	return true
}

displays_press :: proc(a: ^App, x, y, button: int) -> bool {
	d := a.displays
	i := dsp_at(d, x, y)
	if i < 0 do return false
	d.sel, d.dragging = i, true
	sx, sy, _, _ := dsp_screen(d, d.outs[i])
	d.grab_x, d.grab_y = f32(x - sx) / d.view_f, f32(y - sy) / d.view_f
	return true
}

displays_drag :: proc(a: ^App, x, y: int) -> bool {
	d := a.displays
	if !d.dragging do return false
	d.outs[d.sel].x = (f32(x) - d.view_x) / d.view_f - d.grab_x
	d.outs[d.sel].y = (f32(y) - d.view_y) / d.view_f - d.grab_y
	return true
}

displays_release :: proc(a: ^App, x, y: int) -> bool {
	d := a.displays
	if !d.dragging do return false
	d.dragging = false
	dsp_snap(d, d.sel)
	return true
}

displays_click :: proc(a: ^App, x, y, button: int) -> bool {
	d := a.displays
	h, ok := hit_at(a, x, y)
	if ok && h.kind == .Chip {
		switch h.a {
		case 0: displays_key(a, .Enter, false, false, 0, "")
		case 1: displays_key(a, .None, false, false, 'r', "r")
		case 2: a.exit = 1; a.done = true
		}
		return true
	}
	return displays_press(a, x, y, button)
}

// ---------- drawing ----------

displays_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	d := a.displays
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	px := 20 * S
	hh := 56 * S
	ty := (hh - int(d.f13b.line_h) - 3 * S - int(d.f10.line_h)) / 2
	spaced(cv, d.f13b, "DISPLAYS", px, ty, int(d.f13b.line_h), H.acc, 2 * S, true)
	text_in(cv, d.f10, "Drag a screen to where it sits on your desk · it snaps to the others' edges", px, ty + int(d.f13b.line_h) + 3 * S, int(d.f10.line_h), argb(H.dim, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	fh := 30 * S
	fy := h - fh
	// the area, a faint grid behind it
	d.area_x, d.area_y, d.area_w, d.area_h = px, hh + 14 * S, w - 2 * px, fy - hh - 14 * S - 56 * S
	fill_rect(cv, d.area_x, d.area_y, d.area_w, d.area_h, argb(H.panel, 0xff))
	rounded_rect(cv, d.area_x, d.area_y, d.area_w, d.area_h, 0, 0, f32(S), argb(H.line, 0xff))
	for gx := d.area_x + 40 * S; gx < d.area_x + d.area_w; gx += 40 * S do fill_rect(cv, gx, d.area_y + S, S, d.area_h - 2 * S, argb(H.line, 0x60))
	for gy := d.area_y + 40 * S; gy < d.area_y + d.area_h; gy += 40 * S do fill_rect(cv, d.area_x + S, gy, d.area_w - 2 * S, S, argb(H.line, 0x60))
	if !d.view_ok || (!d.dragging && dsp_offview(d)) do dsp_fit(d)
	if len(d.outs) == 0 do text_in(cv, d.f11, "No screens found.", d.area_x + 16 * S, d.area_y + 16 * S, 20 * S, argb(H.dim, 0xff))
	// the screens: the picked one last, on top
	order := make([dynamic]int, 0, len(d.outs), context.temp_allocator)
	for _, i in d.outs do if i != d.sel do append(&order, i)
	if d.sel < len(d.outs) do append(&order, d.sel)
	for i in order {
		o := d.outs[i]
		x, y, rw, rh := dsp_screen(d, o)
		on := i == d.sel
		clash := false
		for p, k in d.outs do if k != i && dsp_overlap(o, p) { clash = true; break }
		edge := clash ? H.hot : (on ? H.acc : soft)
		fill_rect(cv, x, y, rw, rh, on ? argb(H.acc, 0x26) : argb(H.bg, 0xff))
		rounded_rect(cv, x, y, rw, rh, 0, 0, f32(on ? 2 * S : S), argb(edge, 0xff))
		if on do mark_sel(a, x, y, rw, rh)
		// name, size, built-in: centred
		l1 := ellipsize(d.f14b, o.name, rw - 12 * S)
		l2 := ellipsize(d.f10, fmt.tprintf("%.0f × %.0f%s", o.w, o.h, o.builtin ? " · built-in" : ""), rw - 12 * S)
		l3 := ellipsize(d.f10, o.desc, rw - 12 * S)
		lh := int(d.f14b.line_h) + 3 * S + int(d.f10.line_h) + (l3 != "" ? 2 * S + int(d.f10.line_h) : 0)
		yy := y + (rh - lh) / 2
		text_in(cv, d.f14b, l1, x + (rw - tw(d.f14b, l1)) / 2, yy, int(d.f14b.line_h), argb(on ? H.fg : soft, 0xff))
		yy += int(d.f14b.line_h) + 3 * S
		text_in(cv, d.f10, l2, x + (rw - tw(d.f10, l2)) / 2, yy, int(d.f10.line_h), argb(H.dim, 0xff))
		if l3 != "" { yy += int(d.f10.line_h) + 2 * S; text_in(cv, d.f10, l3, x + (rw - tw(d.f10, l3)) / 2, yy, int(d.f10.line_h), argb(on ? soft : H.dim, 0xff)) }
	}
	// the buttons
	by := fy - 42 * S
	bx := px
	btn :: proc(a: ^App, cv: ^Canvas, d: ^Displays, S, x, y: int, l, k: string, prim: bool, id: int, H: HUD, soft: u32) -> int {
		bw := tw(d.f12b, l) + 7 * S + tw(d.f11, k) + 20 * S
		if prim do fill_rect(cv, x, y, bw, 28 * S, argb(H.acc, 0xff))
		rounded_rect(cv, x, y, bw, 28 * S, 0, 0, f32(S), argb(prim ? H.acc : H.line, 0xff))
		text_in(cv, d.f12b, l, x + 10 * S, y, 28 * S, argb(prim ? H.bg : soft, 0xff))
		text_in(cv, d.f11, k, x + 10 * S + tw(d.f12b, l) + 7 * S, y, 28 * S, argb(prim ? H.bg : H.dim, 0xff))
		hit_add(a, x, y, bw, 28 * S, .Chip, id, 0)
		return bw
	}
	bx += btn(a, cv, d, S, bx, by, "Apply", "↵", true, 0, H, soft) + 6 * S
	bx += btn(a, cv, d, S, bx, by, "As they are now", "r", false, 1, H, soft) + 6 * S
	btn(a, cv, d, S, bx, by, "Cancel", "Esc", false, 2, H, soft)
	// the foot
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	HK := [?][2]string{{"drag", "Move"}, {"Tab", "Screen"}, {"←↑↓→", "Nudge (Alt: finer)"}, {"s", "Snap"}, {"↵", "Apply"}}
	kx := px
	for k in HK {
		kw := tw(d.f10, k[0]) + 8 * S
		rounded_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, d.f10, k[0], kx + 4 * S, fy, fh, argb(H.fg, 0xff))
		kx += kw + 5 * S
		text_in(cv, d.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(d.f10, k[1]) + 12 * S
	}
	if d.toast != "" {
		tt := ellipsize(d.f10, d.toast, w - px - kx)
		text_in(cv, d.f10, tt, w - px - tw(d.f10, tt), fy, fh, argb(H.acc, 0xff))
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 24)
}

// True when a screen has left the area (after a drop or a nudge): the view fits them again.
@(private = "file")
dsp_offview :: proc(d: ^Displays) -> bool {
	for o in d.outs {
		x, y, rw, rh := dsp_screen(d, o)
		if x < d.area_x || y < d.area_y || x + rw > d.area_x + d.area_w || y + rh > d.area_y + d.area_h do return true
	}
	return false
}

displays_dump :: proc(a: ^App) -> string {
	d := a.displays
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "displays · %d screens", len(d.outs))
	for o, i in d.outs do fmt.sbprintfln(&sb, "%s %s %.0f,%.0f %.0fx%.0f", i == d.sel ? "*" : " ", o.name, o.x, o.y, o.w, o.h)
	if d.toast != "" do fmt.sbprintfln(&sb, "toast %s", d.toast)
	return strings.to_string(sb)
}
