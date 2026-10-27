package k4

import "core:fmt"
import "core:strconv"
import "core:strings"

// --drives: removable drives (the Kestrel design's Drives popup, under the bar's drives module):
// 420×500, a card per USB stick, SD card or external disk: its kind, label, model and mount
// point, a state (mounted, not mounted, locked, busy, writing, safe to remove), an eject button
// and how full it is. The picked card opens its actions: ↵ opens it (mounting it first), m mounts
// or unmounts, e ejects (unmounts and powers it off), y copies its path. A drive something still
// uses turns yellow and says what holds it (↵ closes them and ejects, Esc leaves it); an
// encrypted one asks for its passphrase in the card (Tab shows it). The data comes from
// k4-drives (panel lines R and L, panel.odin), again every 2 s while open:
//   D <id> <USB|SSD|SD|HDD|PHONE> <label> <model · size · filesystem> <mount point>
//     <used 0–1, -1 unknown> <use, e.g. "24 of 64 GB"> <mounted|unmounted|locked|busy|writing|safe> <note>
// The runner's verbs: open ID, mount ID, unmount ID, eject ID, force ID, copy ID, unlock ID
// ($K4_INPUT: the passphrase).

DRIVES_W, DRIVES_H :: 420, 500

Drive :: struct { id, kind, label, model, path, use, state, note: string, used: f32 }

Drives :: struct {
	using pn: Panel,
	list: [dynamic]Drive,
	cur: int,
	sel: string,
}

drives_setup :: proc(a: ^App, data: string) {
	d := new(Drives)
	d.mode = {draw = drv_draw, key = drv_key, click = drv_click, loaded = drv_loaded, ran = drv_ran, dump = drv_dump}
	panel_init(a, &d.pn, "drives", data)
	d.refresh_ms = 2000
	a.width, a.height = DRIVES_W, DRIVES_H
}

@(private = "file")
D :: proc(a: ^App) -> ^Drives { return (^Drives)(a.pn) }

@(private = "file")
drv_loaded :: proc(a: ^App, data: string) {
	d := D(a)
	for &x in d.list { delete(x.id); delete(x.kind); delete(x.label); delete(x.model); delete(x.path); delete(x.use); delete(x.state); delete(x.note) }
	clear(&d.list)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		if f[0] != "D" do continue
		u, ok := strconv.parse_f32(fget(f, 6))
		append(&d.list, Drive{strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5)), strings.clone(fget(f, 7)), strings.clone(fget(f, 8)), strings.clone(fget(f, 9)), ok ? u : -1})
	}
	for x, i in d.list do if x.id == d.sel { d.cur = i; return }
	d.cur = clamp(d.cur, 0, max(len(d.list) - 1, 0))
}

@(private = "file")
drv_ran :: proc(a: ^App, verb, line: string) -> bool { return false }

@(private = "file")
drv_pick :: proc(d: ^Drives, i: int) {
	if len(d.list) == 0 do return
	d.cur = clamp(i, 0, len(d.list) - 1)
	delete(d.sel)
	d.sel = strings.clone(d.list[d.cur].id)
	panel_clear(&d.pn)
	panel_say(&d.pn, "")
}

@(private = "file")
drv_sel :: proc(d: ^Drives) -> ^Drive { return d.cur < len(d.list) ? &d.list[d.cur] : nil }

@(private = "file")
drv_open :: proc(a: ^App) {
	d := D(a)
	x := drv_sel(d)
	if x == nil do return
	switch x.state {
	case "locked":
		if len(d.input) == 0 { panel_say(&d.pn, "Type the passphrase, then ↵", a.theme.yellow); return }
		panel_run(a, "unlock", x.id, secret = strings.clone(panel_text(&d.pn), context.temp_allocator))
		panel_clear(&d.pn)
	case "busy": panel_run(a, "force", x.id)
	case "safe":
	case: panel_run(a, "open", x.id)
	}
}

@(private = "file")
drv_act :: proc(a: ^App, verb: string) {
	d := D(a)
	x := drv_sel(d)
	if x == nil || x.state == "safe" do return
	if x.state == "locked" { panel_say(&d.pn, "Unlock it first: its passphrase, then ↵", a.theme.yellow); return }
	switch verb {
	case "mount": panel_run(a, x.state == "unmounted" ? "mount" : "unmount", x.id)
	case "eject":
		if x.state == "writing" { panel_say(&d.pn, "Still writing · eject waits until it is done", a.theme.yellow); return }
		panel_run(a, "eject", x.id)
	case "copy": panel_run(a, "copy", x.id)
	}
}

drv_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	d := D(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	x := drv_sel(d)
	if x != nil && x.state == "busy" {
		switch {
		case k == .Enter: drv_open(a)
		case k == .Escape: panel_run(a, "cancel", x.id)
		case k == .Down: drv_pick(d, d.cur + 1)
		case k == .Up: drv_pick(d, d.cur - 1)
		case: return false
		}
		return true
	}
	if x != nil && x.state == "locked" { // the passphrase field
		switch {
		case k == .Enter: drv_open(a); return true
		case k == .Tab: d.pn.reveal = !d.pn.reveal; return true
		case k == .Backspace: panel_bs(&d.pn); return true
		case k == .Escape: if len(d.input) > 0 do panel_clear(&d.pn); else do panel_close(a); return true
		case text != "" && k == .None && !ctrl: panel_type(&d.pn, text); return true
		}
	}
	switch {
	case k == .Down: drv_pick(d, d.cur + 1)
	case k == .Up: drv_pick(d, d.cur - 1)
	case k == .Enter: drv_open(a)
	case text == "m": drv_act(a, "mount")
	case text == "e": drv_act(a, "eject")
	case text == "y": drv_act(a, "copy")
	case k == .Escape: panel_close(a)
	case: return false
	}
	return true
}

drv_click :: proc(a: ^App, x, y, button: int) -> bool {
	d := D(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: if h.a == d.cur do drv_open(a); else do drv_pick(d, h.a)
	case .Confirm: // a card's eject button
		if h.a != d.cur do drv_pick(d, h.a)
		drv_act(a, "eject")
	case .Chip:
		s := drv_sel(d)
		if s == nil do return true
		switch {
		case s.state == "busy": if h.a == 0 do drv_open(a); else do panel_run(a, "cancel", s.id)
		case s.state == "locked": if h.a == 0 do drv_open(a); else do panel_say(&d.pn, "Left locked")
		case:
			switch h.a {
			case 0: drv_open(a)
			case 1: drv_act(a, "mount")
			case 2: drv_act(a, "eject")
			case 3: drv_act(a, "copy")
			}
		}
	}
	return true
}

drv_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	d := D(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	nm := 0
	for x in d.list do if x.path != "" do nm += 1
	title := len(d.list) > 0 ? fmt.tprintf("%d drive%s · %d mounted", len(d.list), len(d.list) == 1 ? "" : "s", nm) : "Removable drives"
	hh, _, _ := panel_head(a, cv, S, H, "DRIVES", title, false, tw(d.f10, "udisks2"))
	text_in(cv, d.f10, "udisks2", w - 12 * S - tw(d.f10, "udisks2"), 0, hh, argb(H.dim, 0xff))
	fy := h - 30 * S
	y := hh + S + 10 * S
	if len(d.list) == 0 {
		cy := y + (fy - y) / 2 - 40 * S
		l1 := "No removable drives"
		text_in(cv, d.f13b, l1, (w - tw(d.f13b, l1)) / 2, cy, 20 * S, argb(H.fg, 0xff))
		cy += 26 * S
		for l in wrap_text(d.f11, "Plug in a USB stick, SD card or external disk. It mounts by itself and shows up here; the bar module hides until then.", w - 60 * S) {
			text_in(cv, d.f11, l, (w - tw(d.f11, l)) / 2, cy, 16 * S, argb(H.dim, 0xff))
			cy += 16 * S
		}
	}
	x0, x1 := 10 * S, w - 10 * S
	for x, i in d.list {
		on := i == d.cur
		st, stc := "MOUNTED", th.green
		note, notec := x.note, H.dim
		switch x.state {
		case "unmounted": st, stc = "NOT MOUNTED", H.dim
		case "locked": st, stc = "LOCKED", th.yellow; if note == "" do note = "Encrypted with LUKS. Type its passphrase to unlock and mount it."
		case "busy": st, stc, notec = "BUSY", th.yellow, th.yellow
		case "writing": st, stc, notec = "WRITING", H.acc, H.acc
		case "safe": st, stc, notec = "SAFE TO REMOVE", th.green, th.green; if note == "" do note = "Unplug it now. It leaves this list when you do."
		}
		busy := x.state == "busy"
		kc := H.acc
		switch x.kind { case "SSD", "HDD": kc = th.green; case "SD": kc = th.yellow; case "PHONE": kc = th.magenta }
		inner := x1 - x0 - 24 * S
		notes := note != "" ? wrap_text(d.f10, note, inner) : nil
		has_bar := x.state != "locked" && x.state != "safe" && x.used >= 0
		acts := make([dynamic][3]string, 0, 4, context.temp_allocator) // label, key, kind
		switch x.state {
		case "busy": append(&acts, [3]string{"Close them and eject", "↵", "hot"}, [3]string{"Cancel", "Esc", ""})
		case "locked": append(&acts, [3]string{"Unlock", "↵", "prime"}, [3]string{"Ignore", "Esc", ""})
		case "safe":
		case: append(&acts, [3]string{x.path != "" ? "Open" : "Mount and open", "↵", "prime"}, [3]string{x.path != "" ? "Unmount" : "Mount", "m", ""}, [3]string{"Eject", "e", ""}, [3]string{"Copy path", "y", ""})
		}
		open := on && len(acts) > 0
		head_h := max(int(d.f12b.line_h) + 2 * S + int(d.f10.line_h), 22 * S)
		ch := 10 * S + head_h
		if has_bar do ch += 8 * S + int(d.f10.line_h)
		if len(notes) > 0 do ch += 8 * S + len(notes) * 15 * S
		if on && x.state == "locked" do ch += 8 * S + 28 * S
		if open do ch += 8 * S + 22 * S
		ch += 10 * S
		if y + ch > fy - 6 * S do break
		bg := on ? argb(H.acc, 0x12) : argb(a.theme.fg, 0x0d)
		bd := on ? H.acc : H.line
		if busy do bg, bd = argb(th.yellow, 0x0d), th.yellow
		fill_rect(cv, x0, y, x1 - x0, ch, bg)
		rounded_rect(cv, x0, y, x1 - x0, ch, 0, 0, f32(S), argb(bd, 0xff))
		if on { fill_rect(cv, x0, y, 3 * S, ch, argb(busy ? th.yellow : H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, ch) }
		hit_add(a, x0, y, x1 - x0, ch, .Row, i, 0)
		yy := y + 10 * S
		cx := x0 + 12 * S
		panel_tag(cv, d.f9b, cx, yy + (head_h - 15 * S) / 2, 34 * S, 15 * S, S, x.kind, kc)
		// the eject button and the state, from the right
		ex := x1 - 12 * S - 26 * S
		eoff := x.state == "locked" || x.state == "safe"
		ec := eoff ? mix(soft, H.bg, 0.6) : soft
		rounded_rect(cv, ex, yy + (head_h - 22 * S) / 2, 26 * S, 22 * S, 0, 0, f32(S), argb(eoff ? mix(H.line, H.bg, 0.4) : H.line, 0xff))
		text_in(cv, d.f11b, "⏏", ex + (26 * S - tw(d.f11b, "⏏")) / 2, yy + (head_h - 22 * S) / 2, 22 * S, argb(ec, 0xff))
		if !eoff do hit_add(a, ex, yy + (head_h - 22 * S) / 2, 26 * S, 22 * S, .Confirm, i, 0)
		sw := tw(d.f9b, st) + 10 * S
		sx := ex - 10 * S - sw
		panel_tag(cv, d.f9b, sx, yy + (head_h - 15 * S) / 2, sw, 15 * S, S, st, stc)
		lx := cx + 34 * S + 10 * S
		text_in(cv, d.f12b, ellipsize(d.f12b, x.label, sx - 10 * S - lx), lx, yy, int(d.f12b.line_h), argb(H.fg, 0xff))
		sub := x.path != "" ? fmt.tprintf("%s · %s", x.model, x.path) : x.model
		text_in(cv, d.f10, ellipsize(d.f10, sub, sx - 10 * S - lx), lx, yy + int(d.f12b.line_h) + 2 * S, int(d.f10.line_h), argb(H.dim, 0xff))
		yy += head_h
		if has_bar {
			yy += 8 * S
			uc := soft
			switch { case x.state == "writing": uc = H.acc; case x.used > 0.85: uc = H.hot; case x.used > 0.7: uc = th.yellow }
			ut := x.use
			if x.path == "" && x.state == "unmounted" do ut = strings.concatenate({x.use, x.use != "" ? " · " : "", "not mounted"}, context.temp_allocator)
			uw := tw(d.f10, ut)
			panel_meter(cv, cx, yy + (int(d.f10.line_h) - 4 * S) / 2, x1 - 12 * S - uw - 8 * S - cx, 4 * S, x.used, uc, H.line)
			text_in(cv, d.f10, ut, x1 - 12 * S - uw, yy, int(d.f10.line_h), argb(soft, 0xff))
			yy += int(d.f10.line_h)
		}
		if len(notes) > 0 {
			yy += 8 * S
			for l in notes { text_in(cv, d.f10, l, cx, yy, 15 * S, argb(notec, 0xff)); yy += 15 * S }
		}
		if on && x.state == "locked" { // the passphrase, in the card
			yy += 8 * S
			fill_rect(cv, cx, yy, inner, 28 * S, argb(H.bg, 0xff))
			rounded_rect(cv, cx, yy, inner, 28 * S, 0, 0, f32(S), argb(H.acc, 0xff))
			pw := panel_masked(&d.pn)
			text_in(cv, d.f12, ellipsize(d.f12, pw, inner - 140 * S), cx + 10 * S, yy, 28 * S, argb(H.fg, 0xff))
			fill_rect(cv, cx + 10 * S + tw(d.f12, ellipsize(d.f12, pw, inner - 140 * S)) + 2 * S, yy + 7 * S, 7 * S, 14 * S, argb(H.acc, 0xff))
			hint := "↵ unlocks · Tab shows"
			text_in(cv, d.f10, hint, cx + inner - 10 * S - tw(d.f10, hint), yy, 28 * S, argb(H.dim, 0xff))
			yy += 28 * S
		}
		if open {
			yy += 8 * S
			bx := cx
			for ac, j in acts {
				kind := Btn_Kind.Plain
				if ac[2] == "prime" do kind = .Prime
				if ac[2] == "hot" do kind = .Hot
				bw := panel_btn_w(a, S, ac[0], ac[1])
				if bx + bw > x1 - 12 * S do break
				bx += panel_btn(a, cv, S, bx, yy, 22 * S, H, ac[0], ac[1], kind, j) + 6 * S
			}
		}
		y += ch + 6 * S
	}
	keep, tone := d.pn.toast, d.pn.tone
	if keep != "" && strings.has_prefix(keep, "Closed") do d.pn.tone = th.yellow
	panel_foot(a, cv, S, H, {{"↑↓", "Drive"}, {"↵", "Open"}, {"m", "Mount"}, {"e", "Eject"}, {"Esc", "Close"}}, false)
	d.pn.tone = tone
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

drv_dump :: proc(a: ^App) -> string {
	d := D(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "drives %d", len(d.list))
	for x, i in d.list do fmt.sbprintfln(&sb, "%s %s %s · %s · %s%s%s", i == d.cur ? "*" : " ", x.kind, x.label, x.state, x.path != "" ? x.path : "-", x.use != "" ? fmt.tprintf(" · %s", x.use) : "", len(d.input) > 0 && i == d.cur ? fmt.tprintf(" · passphrase %s", panel_masked(&d.pn)) : "")
	panel_dump_toast(&d.pn, &sb)
	return strings.to_string(sb)
}
