package k4

import "core:fmt"
import "core:strings"

// --keyring: the passwords k4 keeps in the keyring (the Kestrel design's Keyring, Network ›
// Keyring): 420×560, under the bar or centred. Wi-Fi and VPN passwords typed into k4, and the
// sign-in tokens its integrations keep, in groups; the picked one shows Use (↵: joins the
// network, brings the VPN up, syncs) and Forget (Del, then y / n). A locked keyring shows a
// notice and an Unlock row: k4 closes first (its prompt can't take keys under k4) and prints
// "unlock". The data comes from k4-secret (panel lines R and L, panel.odin):
//   S <locked 1|0>
//   E <id> <WIFI|VPN|TOKEN> <group> <label> <sub> <use label> <in use 1|0>
// The runner's verbs: use ID, forget ID.

KEYRING_W, KEYRING_H :: 420, 560

Kr_Entry :: struct { id, kind, group, label, sub, use: string, in_use: bool }

Keyring :: struct {
	using pn: Panel,
	locked: bool,
	entries: [dynamic]Kr_Entry,
	cur: int, // 0 is the Unlock row when locked
	sel: string,
	ask: string, // the entry asked about (Forget? y / n)
}

keyring_setup :: proc(a: ^App, data: string) {
	k := new(Keyring)
	k.mode = {draw = kr_draw, key = kr_key, click = kr_click, loaded = kr_loaded, ran = kr_ran, dump = kr_dump}
	panel_init(a, &k.pn, "keyring", data)
	a.width, a.height = KEYRING_W, KEYRING_H
}

@(private = "file")
K :: proc(a: ^App) -> ^Keyring { return (^Keyring)(a.pn) }

@(private = "file")
kr_loaded :: proc(a: ^App, data: string) {
	k := K(a)
	for &e in k.entries { delete(e.id); delete(e.kind); delete(e.group); delete(e.label); delete(e.sub); delete(e.use) }
	clear(&k.entries)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S": k.locked = fget(f, 1) == "1"
		case "E":
			append(&k.entries, Kr_Entry{strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5)), strings.clone(fget(f, 6)), fget(f, 7) == "1"})
		}
	}
	kr_keep(k)
}

@(private = "file")
kr_ran :: proc(a: ^App, verb, line: string) -> bool { return false }

// The picked row again after the list changed.
@(private = "file")
kr_keep :: proc(k: ^Keyring) {
	if k.sel == "" do return
	for e, i in k.entries do if e.id == k.sel { k.cur = i + (k.locked ? 1 : 0); return }
	k.cur = clamp(k.cur, 0, max(kr_n(k) - 1, 0))
}

@(private = "file")
kr_n :: proc(k: ^Keyring) -> int { return len(k.entries) + (k.locked ? 1 : 0) }

// The entry at a row, or nil for the Unlock row.
@(private = "file")
kr_at :: proc(k: ^Keyring, i: int) -> ^Kr_Entry {
	j := i - (k.locked ? 1 : 0)
	return j >= 0 && j < len(k.entries) ? &k.entries[j] : nil
}

@(private = "file")
kr_pick :: proc(k: ^Keyring, i: int) {
	k.cur = clamp(i, 0, max(kr_n(k) - 1, 0))
	delete(k.sel)
	e := kr_at(k, k.cur)
	k.sel = e != nil ? strings.clone(e.id) : ""
	delete(k.ask); k.ask = ""
	panel_say(&k.pn, "")
}

@(private = "file")
kr_use :: proc(a: ^App) {
	k := K(a)
	if k.locked && k.cur == 0 { panel_close(a, "unlock"); return }
	e := kr_at(k, k.cur)
	if e == nil do return
	if k.locked { panel_say(&k.pn, "Unlock the keyring first", a.theme.yellow); return }
	panel_run(a, "use", e.id)
}

@(private = "file")
kr_forget :: proc(a: ^App) {
	k := K(a)
	e := kr_at(k, k.cur)
	if e == nil do return
	if k.ask == e.id {
		delete(k.ask); k.ask = ""
		panel_run(a, "forget", e.id)
	} else {
		delete(k.ask)
		k.ask = strings.clone(e.id)
		panel_say(&k.pn, "")
	}
}

kr_key :: proc(a: ^App, key: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	k := K(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	if k.ask != "" {
		switch {
		case text == "y" || key == .Enter: kr_forget(a)
		case text == "n" || key == .Escape: delete(k.ask); k.ask = ""
		case: return false
		}
		return true
	}
	switch {
	case key == .Down || text == "j": kr_pick(k, k.cur + 1)
	case key == .Up || text == "k": kr_pick(k, k.cur - 1)
	case key == .Enter: kr_use(a)
	case key == .Delete || text == "d": kr_forget(a)
	case key == .Escape: panel_close(a)
	case: return false
	}
	return true
}

kr_click :: proc(a: ^App, x, y, button: int) -> bool {
	k := K(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: if h.a == k.cur do kr_use(a); else do kr_pick(k, h.a)
	case .Chip:
		switch h.a {
		case 0: if k.ask != "" do kr_forget(a); else do kr_use(a)
		case 1: if k.ask != "" { delete(k.ask); k.ask = "" } else do kr_forget(a)
		}
	}
	return true
}

kr_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	k := K(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	st_l, st_c := k.locked ? "LOCKED" : "UNLOCKED", k.locked ? th.yellow : th.green
	stw := tw(k.f10b, st_l) + 11 * S
	title := len(k.entries) > 0 ? fmt.tprintf("%d saved by k4", len(k.entries)) : "Saved secrets"
	hh, px, _ := panel_head(a, cv, S, H, "NETWORK › KEYRING", title, false, stw)
	panel_state(a, cv, S, w - px, hh, st_l, st_c, !k.locked, false)
	y := hh + S
	if k.locked do y += 10 * S + panel_notice(a, cv, S, px, y + 10 * S, w - 2 * px, H, "The keyring is locked", "k4 can’t reuse saved Wi-Fi and VPN passwords until it’s unlocked. Joining a network asks for its password as before.", th.yellow)
	y += 6 * S
	fy := h - 30 * S
	if len(k.entries) == 0 && !k.locked {
		cy := y + (fy - y) / 2 - 30 * S
		l1 := "Nothing saved yet"
		text_in(cv, k.f13b, l1, (w - tw(k.f13b, l1)) / 2, cy, 20 * S, argb(H.fg, 0xff))
		cy += 26 * S
		for l in wrap_text(k.f11, "Wi-Fi and VPN passwords you type into k4 are kept here and used again without asking.", w - 60 * S) {
			text_in(cv, k.f11, l, (w - tw(k.f11, l)) / 2, cy, 16 * S, argb(H.dim, 0xff))
			cy += 16 * S
		}
	}
	group := "\x00"
	for i in 0 ..< kr_n(k) {
		e := kr_at(k, i)
		if e != nil && e.group != group { // the heading of a group: its name and how many
			group = e.group
			n := 0
			for x in k.entries do if x.group == group do n += 1
			if y + 24 * S > fy do break
			panel_group(a, cv, S, 16 * S, y + 9 * S, int(k.f10b.line_h), H, strings.to_upper(group, context.temp_allocator), fmt.tprint(n))
			y += 9 * S + int(k.f10b.line_h) + 4 * S
		}
		on := i == k.cur
		asking := e != nil && k.ask == e.id
		dimmed := k.locked && e != nil
		rh := 7 * S + max(int(k.f12b.line_h) + 2 * S + int(k.f10.line_h), 16 * S) + 7 * S
		open := on && e != nil
		if open do rh += 6 * S + 22 * S
		if y + 1 * S + rh > fy - 4 * S do break
		ry := y + S
		x0, x1 := 8 * S, w - 8 * S
		edge := asking ? H.hot : H.acc
		if on {
			fill_rect(cv, x0, ry, x1 - x0, rh, asking ? argb(H.hot, 0x12) : argb(H.acc, 0x14))
			rounded_rect(cv, x0, ry, x1 - x0, rh, 0, 0, f32(S), argb(edge, 0xff))
			fill_rect(cv, x0, ry, 3 * S, rh, argb(edge, 0xff))
			mark_sel(a, x0, ry, x1 - x0, rh)
		}
		kind, label, sub, meta := "KEY", "Unlock the keyring", "Closes this popup first: the keyring asks in its own window", "↵"
		kc, mc := th.yellow, H.dim
		if e != nil {
			kind, label, sub, meta = e.kind, e.label, e.sub, e.in_use ? "in use" : ""
			switch e.kind {
			case "WIFI": kc = H.acc
			case "VPN": kc = th.green
			case: kc = soft
			}
			if e.in_use do mc = th.green
			if asking do sub = fmt.tprintf("Forget it? y / n · %s", e.kind == "WIFI" ? "you will be asked for it next time" : "you will have to sign in again")
		}
		fade :: proc(c: u32, bg: u32, d: bool) -> u32 { return d ? mix(c, bg, 0.5) : c }
		lh1 := max(int(k.f12b.line_h) + 2 * S + int(k.f10.line_h), 16 * S)
		ly := ry + 7 * S
		panel_tag(cv, k.f9b, x0 + 10 * S, ly + (lh1 - 14 * S) / 2, 40 * S, 14 * S, S, kind, fade(kc, H.bg, dimmed))
		tx := x0 + 10 * S + 40 * S + 9 * S
		mw := meta != "" ? tw(k.f10, meta) : 0
		text_in(cv, k.f12b, ellipsize(k.f12b, label, x1 - 10 * S - mw - 8 * S - tx), tx, ly, int(k.f12b.line_h), argb(fade(H.fg, H.bg, dimmed), 0xff))
		text_in(cv, k.f10, ellipsize(k.f10, sub, x1 - 10 * S - mw - 8 * S - tx), tx, ly + int(k.f12b.line_h) + 2 * S, int(k.f10.line_h), argb(asking ? H.hot : fade(H.dim, H.bg, dimmed), 0xff))
		if meta != "" do text_in(cv, k.f10, meta, x1 - 10 * S - mw, ly, lh1, argb(fade(mc, H.bg, dimmed), 0xff))
		if open { // Use and Forget, or Forget and Keep
			bx := tx
			by := ly + lh1 + 6 * S
			if asking {
				bx += panel_btn(a, cv, S, bx, by, 22 * S, H, "Forget", "y", .Hot, 0) + 6 * S
				panel_btn(a, cv, S, bx, by, 22 * S, H, "Keep", "n", .Plain, 1)
			} else {
				use := e.use != "" ? e.use : "Use"
				bx += panel_btn(a, cv, S, bx, by, 22 * S, H, use, "↵", .Prime, 0) + 6 * S
				panel_btn(a, cv, S, bx, by, 22 * S, H, "Forget", "Del", .Plain, 1)
			}
		}
		hit_add(a, x0, ry, x1 - x0, open ? ly + lh1 - ry : rh, .Row, i, 0)
		y = ry + rh + S
	}
	hints: [][2]string = k.ask != "" ? {{"y", "Forget"}, {"n", "Keep"}} : {{"↑↓", "Move"}, {"↵", "Use"}, {"Del", "Forget"}, {"Esc", "Close"}}
	panel_foot(a, cv, S, H, hints, false)
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

kr_dump :: proc(a: ^App) -> string {
	k := K(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "keyring %s · %d saved", k.locked ? "locked" : "unlocked", len(k.entries))
	for i in 0 ..< kr_n(k) {
		e := kr_at(k, i)
		on := i == k.cur
		if e == nil { fmt.sbprintfln(&sb, "%s Unlock the keyring", on ? "*" : " "); continue }
		fmt.sbprintfln(&sb, "%s %s %s · %s%s%s", on ? "*" : " ", e.kind, e.label, e.sub, e.in_use ? " · in use" : "", k.ask == e.id ? " · forget? y / n" : "")
	}
	panel_dump_toast(&k.pn, &sb)
	return strings.to_string(sb)
}
