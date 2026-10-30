package k4

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strconv"
import "core:strings"

// --bardrawer: a bar group's drawer (the Kestrel design's KGroups board), 380×520 under its chip:
// the group's name, what its chip shows and why, the five groups as dots (← → walks them); each
// member with its usual chip and one line, attention first in its colour, ON CHIP on the member
// whose value the quiet chip shows (⌃P puts the picked one there); members not showing now listed
// dim at the end. ↵ opens the member's own popup in the drawer's place (a switch: flips it).
// Data: k4-bar drawer-data:
//   D group label summary tone(red|yellow|dim)
//   G id label glyph current(1|0)
//   M id name icon shape text text2 icon_tone text_tone class badge pill line sev shown pinned act(open|toggle)
// The runner's verbs (k4-bar drawer-act): open ID, toggle ID, nav ±1, pin ID.

BD_W, BD_H :: 380, 520

Bd_Member :: struct { id, name, icon, text, text2, itone, ttone, class, pill, line, act: string, shape: Shape, badge, sev: int, shown, pinned: bool }
Bd_Group :: struct { id, label, glyph: string, cur: bool }

Bardrawer :: struct {
	using pn: Panel,
	arena: vmem.Arena,
	group, label, summary, sum_tone: string,
	groups: [dynamic]Bd_Group,
	mems: [dynamic]Bd_Member,
	cur: int,
}

bardrawer_setup :: proc(a: ^App, data: string) {
	m := new(Bardrawer)
	_ = vmem.arena_init_growing(&m.arena)
	m.mode = {draw = bd_draw, key = bd_key, click = bd_click, loaded = bd_loaded, dump = bd_dump}
	panel_init(a, &m.pn, "bardrawer", data)
	m.refresh_ms = 3000
	a.width, a.height = BD_W, BD_H
}

@(private = "file")
BD :: proc(a: ^App) -> ^Bardrawer { return (^Bardrawer)(a.pn) }

@(private = "file")
bd_loaded :: proc(a: ^App, data: string) {
	m := BD(a)
	if !strings.has_prefix(data, "D\t") && !strings.contains(data, "\nD\t") do return
	old := m.group
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al := context.allocator) -> string { return strings.clone(s, al) }
	num :: proc(s: string) -> int { n, _ := strconv.parse_int(s); return n }
	m.groups = make([dynamic]Bd_Group, al)
	m.mems = make([dynamic]Bd_Member, al)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "D": m.group, m.label, m.summary, m.sum_tone = c(fget(f, 1), al), c(fget(f, 2), al), c(fget(f, 3), al), c(fget(f, 4), al)
		case "G": append(&m.groups, Bd_Group{id = c(fget(f, 1), al), label = c(fget(f, 2), al), glyph = c(fget(f, 3), al), cur = fget(f, 4) == "1"})
		case "M":
			append(&m.mems, Bd_Member{id = c(fget(f, 1), al), name = c(fget(f, 2), al), icon = c(fget(f, 3), al), shape = shape_of(fget(f, 4)), text = c(fget(f, 5), al),
				text2 = c(fget(f, 6), al), itone = c(fget(f, 7), al), ttone = c(fget(f, 8), al), class = c(fget(f, 9), al), badge = num(fget(f, 10)), pill = c(fget(f, 11), al),
				line = c(fget(f, 12), al), sev = num(fget(f, 13)), shown = fget(f, 14) == "1", pinned = fget(f, 15) == "1", act = c(fget(f, 16), al)})
		}
	}
	if m.group != old do m.cur = 0 // (another group: from its top)
	m.cur = clamp(m.cur, 0, max(len(m.mems) - 1, 0))
}

@(private = "file")
bd_act :: proc(a: ^App, m: ^Bardrawer) {
	if m.cur >= len(m.mems) do return
	x := m.mems[m.cur]
	panel_run(a, x.act == "toggle" ? "toggle" : "open", x.id)
}

@(private = "file")
bd_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := BD(a)
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	switch {
	case k == .Down: m.cur = min(m.cur + 1, max(len(m.mems) - 1, 0))
	case k == .Up: m.cur = max(m.cur - 1, 0)
	case k == .Left || k == .Back_Tab: panel_run(a, "nav", "-1")
	case k == .Right || k == .Tab: panel_run(a, "nav", "1")
	case k == .Enter: bd_act(a, m)
	case ctrl && low == 'p':
		if m.cur >= len(m.mems) do return true
		x := m.mems[m.cur]
		if x.text == "" do panel_say(&m.pn, fmt.tprintf("%s has no value to show", x.name))
		else do panel_run(a, "pin", x.id)
	case k == .Escape || k == .Backspace || (ctrl && (low == 'c' || low == 'g')): panel_close(a)
	case: return false
	}
	return true
}

@(private = "file")
bd_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := BD(a)
	h := hit_at(a, x, y) or_return
	#partial switch h.kind {
	case .Row: if h.a >= 0 && h.a < len(m.mems) { m.cur = h.a; bd_act(a, m) }
	case .Chip:
		for g, i in m.groups do if i == h.a && !g.cur {
			cur := 0
			for gg, k in m.groups do if gg.cur do cur = k
			panel_run(a, "nav", fmt.tprint(i - cur))
		}
	}
	return true
}

// A member's chip, as the bar draws it (the icon or shape, the value, the count tag), in a 24 px box.
@(private = "file")
bd_chip :: proc(a: ^App, cv: ^Canvas, m: ^Bardrawer, S, x, y: int, H: HUD, mm: Bd_Member) {
	t := a.theme
	crit := mm.sev >= 4
	fg := crit ? t.bg : t.fg
	ic := crit ? fg : token(t, mm.itone, t.fg)
	tc := crit ? fg : token(t, mm.ttone, t.fg)
	w := 6 * S
	if mm.shape != .None || mm.icon != "" do w += (mm.shape != .None ? 14 * S : tw(m.f12, mm.icon))
	if mm.text != "" do w += 6 * S + tw(crit ? m.f12b : m.f12, mm.text)
	if mm.text2 != "" do w += 6 * S + tw(m.f12, mm.text2)
	w = min(w + 6 * S, 104 * S)
	rounded_rect(cv, x, y, w, 24 * S, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, x + S, y + S, w - 2 * S, 22 * S, argb(crit ? t.red : H.bg, 0xff))
	xx := x + 6 * S
	if mm.shape != .None { shape_draw(cv, mm.shape, xx, y + 5 * S, 14 * S, ic); xx += 14 * S + 6 * S }
	else if mm.icon != "" { text_in(cv, m.f12, mm.icon, xx, y, 24 * S, argb(ic, 0xff)); xx += tw(m.f12, mm.icon) + 6 * S }
	if mm.text != "" { s := ellipsize(m.f12, mm.text, x + w - xx - 4 * S); text_in(cv, crit ? m.f12b : m.f12, s, xx, y, 24 * S, argb(tc, 0xff)); xx += tw(m.f12, s) + 6 * S }
	if mm.text2 != "" && xx < x + w - 10 * S do text_in(cv, m.f12, ellipsize(m.f12, mm.text2, x + w - xx - 4 * S), xx, y, 24 * S, argb(H.dim, 0xff))
	tag := mm.badge > 0 ? count_label(mm.badge) : mm.pill
	if tag != "" {
		tw_ := max(11 * S, tw(m.f9b, tag) + 6 * S)
		fill_rect(cv, x + 15 * S, y + S, tw_, 11 * S, argb(t.red == token(t, mm.ttone, 0) || mm.sev >= 3 ? t.red : H.acc, 0xff))
		text_in(cv, m.f9b, tag, x + 15 * S + (tw_ - tw(m.f9b, tag)) / 2, y + S, 11 * S, argb(t.bg, 0xff))
	}
}

@(private = "file")
bd_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := BD(a)
	H := panel_ground(a, cv)
	t := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	sel := mix(H.bg, H.acc, 0.07)
	w, h := cv.w, cv.h
	px := 14 * S
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff))
	// the head: GROUP, what the chip shows, the five groups
	hh := 44 * S
	crumb := strings.to_upper(m.label, context.temp_allocator)
	cw := tw(m.f12b, crumb) + 16 * S
	fill_rect(cv, px, (hh - 22 * S) / 2, cw, 22 * S, argb(H.acc, 0xff))
	text_in(cv, m.f12b, crumb, px + 8 * S, (hh - 22 * S) / 2, 22 * S, argb(H.bg, 0xff))
	dx := w - px - len(m.groups) * 21 * S + 3 * S
	for g, i in m.groups {
		gx := dx + i * 21 * S
		gy := (hh - 18 * S) / 2
		if g.cur do fill_rect(cv, gx, gy, 18 * S, 18 * S, argb(H.acc, 0xff))
		rounded_rect(cv, gx, gy, 18 * S, 18 * S, 0, 0, f32(S), argb(g.cur ? H.acc : H.line, 0xff))
		text_in(cv, m.f10, g.glyph, gx + (18 * S - tw(m.f10, g.glyph)) / 2, gy, 18 * S, argb(g.cur ? H.bg : H.dim, 0xff))
		hit_add(a, gx, gy, 18 * S, 18 * S, .Chip, i, 0)
	}
	sc := m.sum_tone == "red" ? t.red : (m.sum_tone == "yellow" ? t.yellow : H.dim)
	sx := px + cw + 10 * S
	text_in(cv, m.f12, ellipsize(m.f12, m.summary, dx - sx - 8 * S), sx, 0, hh, argb(sc, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the foot
	fh := 36 * S
	fy := h - fh
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	if m.toast != "" do text_in(cv, m.f11, ellipsize(m.f11, m.toast, w - 2 * px), px, fy, fh, argb(m.tone != 0 ? m.tone : H.acc, 0xff))
	else {
		cur := m.cur < len(m.mems) ? m.mems[m.cur] : Bd_Member{}
		kx := px
		for k in ([4][2]string{{"↑↓", "Move"}, {"↵", cur.act == "toggle" ? "Toggle" : "Open"}, {"← →", "Group"}, {"⌃P", "On chip"}}) {
			kw := tw(m.f10, k[0]) + 12 * S
			fill_rect(cv, kx, fy + (fh - 17 * S) / 2, kw, 17 * S, argb(H.panel, 0xff))
			rounded_rect(cv, kx, fy + (fh - 17 * S) / 2, kw, 17 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, m.f10, k[0], kx + 6 * S, fy + (fh - 17 * S) / 2, 17 * S, argb(soft, 0xff))
			kx += kw + 5 * S
			text_in(cv, m.f11, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(m.f11, k[1]) + 12 * S
		}
	}
	// the members: those showing (attention first), then the ones not showing now
	y := hh + S + 6 * S
	col :: proc(t: Theme_Tones, s: int, dim: u32) -> u32 { return s >= 3 ? t.red : (s == 2 ? t.yellow : (s == 1 ? t.acc : dim)) }
	tt := Theme_Tones{red = t.red, yellow = t.yellow, acc = H.acc}
	header := false
	rows_h := 0
	for x in m.mems do rows_h += 44 * S
	top := max(0, (m.cur + 1) * 44 * S + 30 * S - (fy - y))
	yy := y - top
	for x, i in m.mems {
		if !x.shown && !header {
			header = true
			if yy >= y - 30 * S && yy < fy do spaced(cv, m.f10b, "NOT SHOWING · APPEAR WHEN ACTIVE", px, yy + 8 * S, 16 * S, H.dim, S)
			yy += 30 * S
		}
		if yy + 44 * S <= y || yy >= fy { yy += 44 * S; continue }
		on := i == m.cur
		if on do fill_rect(cv, 0, yy, w, 44 * S, argb(sel, 0xff))
		else if x.sev >= 2 do fill_rect(cv, 0, yy, w, 44 * S, argb(col(tt, x.sev, H.dim), 0x0f))
		if on || x.sev >= 2 do fill_rect(cv, 0, yy, 3 * S, 44 * S, argb(on ? H.acc : col(tt, x.sev, H.dim), 0xff))
		hit_add(a, 0, yy, w, 44 * S, .Row, i, 0)
		if x.shown do bd_chip(a, cv, m, S, px, yy + 10 * S, H, x)
		else if x.act == "toggle" {
			rounded_rect(cv, px + 4 * S, yy + 15 * S, 28 * S, 14 * S, 0, 0, f32(S), argb(H.faint, 0xff))
			fill_rect(cv, px + 6 * S, yy + 17 * S, 10 * S, 10 * S, argb(H.faint, 0xff))
		}
		nx := px + 114 * S
		meta := on ? (x.act == "toggle" ? (x.shown ? "↵ off" : "↵ on") : "↵ open") : ""
		mw := meta != "" ? tw(m.f11b, meta) + 8 * S : 0
		nc := x.shown ? H.fg : H.dim
		name := ellipsize(m.f13, x.name, w - nx - px - mw - (x.pinned ? 60 * S : 0))
		text_in(cv, m.f13, name, nx, yy + 6 * S, 17 * S, argb(nc, 0xff))
		if x.pinned && x.sev < 2 {
			tgx := nx + tw(m.f13, name) + 7 * S
			tgw := tw(m.f9b, "ON CHIP") + 8 * S
			rounded_rect(cv, tgx, yy + 9 * S, tgw, 12 * S, 0, 0, f32(S), argb(H.acc, 0xff))
			text_in(cv, m.f9b, "ON CHIP", tgx + 4 * S, yy + 9 * S, 12 * S, argb(H.acc, 0xff))
		}
		lc := x.sev >= 2 ? col(tt, x.sev, H.dim) : H.dim
		text_in(cv, m.f10, ellipsize(m.f10, x.line, w - nx - px - mw), nx, yy + 24 * S, 13 * S, argb(lc, 0xff))
		if meta != "" do text_in(cv, m.f11b, meta, w - px - tw(m.f11b, meta), yy, 44 * S, argb(H.acc, 0xff))
		yy += 44 * S
	}
	_ = rows_h
}

@(private = "file")
Theme_Tones :: struct { red, yellow, acc: u32 }

bd_dump :: proc(a: ^App) -> string {
	m := BD(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "drawer %s · %s", m.label, m.summary)
	gs := make([dynamic]string, 0, 8, context.temp_allocator)
	for g in m.groups do append(&gs, g.cur ? fmt.tprintf("[%s]", g.label) : g.label)
	fmt.sbprintfln(&sb, "groups %s", strings.join(gs[:], " ", context.temp_allocator))
	header := false
	for x, i in m.mems {
		if !x.shown && !header { header = true; fmt.sbprintln(&sb, "-- not showing") }
		fmt.sbprintfln(&sb, "%s %s%s%s%s%s", i == m.cur ? "*" : " ", x.name, x.text != "" ? fmt.tprintf(" [%s]", x.text) : "", x.pinned && x.sev < 2 ? " ON CHIP" : "",
			x.sev >= 2 ? fmt.tprintf(" sev%d", x.sev) : "", x.act == "toggle" ? " (switch)" : "")
	}
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
