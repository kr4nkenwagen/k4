package k4

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Immersive notifications (the Kestrel design's KImmersive, KImmersiveStates, ImmersiveScreens;
// Toggle › Immersive notifications): instead of the small cards at the top right, the newest
// notification as a 760-wide box in the middle of the output (its middle at 58 % of the height)
// over the desktop dimmed to 45 % (62 % while the box has the keys; Hyprland's layer rule blurs
// it). It never takes the keyboard by itself and never times out: it stays until acted on or
// dismissed (then it is kept in the centre) and the next one shows. Several: the newest on top,
// the rest as edges under it, "1 of 3" in its head.
// Keys from anywhere (Hyprland binds them; k4-notify key … asks here first, and the key does its
// usual job when no box is up): Super+↵ the primary action (a message: its reply line takes the
// keys), Super+Esc dismisses, Super+N gives the box the keys (↵ the primary action or send the
// reply, the buttons' letters, Del dismiss, ← → the queue, Esc gives them back), Super+← → the
// queue. A click outside the box dismisses it; its buttons and reply line work with the mouse.
// Do not disturb: nothing shows (the bell counts). A fullscreen window when a note comes: the
// small card instead, so games and video are not covered.

ND_IMM_W :: 760

nd_imm_path :: proc() -> string {
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/state/k4/notify-immersive"}, context.temp_allocator)
}

nd_imm_load :: proc(n: ^Nd) {
	if os.get_env("K4_NOTIFY_FIXTURE", context.temp_allocator) != "" do return
	data, err := os.read_entire_file(nd_imm_path(), context.temp_allocator)
	n.immersive = err == nil && strings.trim_space(string(data)) == "on"
}

nd_imm_save :: proc(n: ^Nd) {
	if os.get_env("K4_NOTIFY_FIXTURE", context.temp_allocator) != "" do return
	p := nd_imm_path()
	_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
	_ = os.write_entire_file(p, transmute([]u8)string(n.immersive ? "on\n" : "off\n"))
}

// A fullscreen window has the output: the note shows as the small card instead.
nd_imm_fullscreen :: proc() -> bool {
	if v := os.get_env("K4_NOTIFY_FULLSCREEN", context.temp_allocator); v != "" do return v == "1"
	if os.get_env("K4_NOTIFY_FIXTURE", context.temp_allocator) != "" do return false
	_, out, _, err := os.process_exec({command = {"hyprctl", "-j", "activewindow"}}, context.temp_allocator)
	if err != nil do return false
	s := string(out)
	i := strings.index(s, "\"fullscreen\":")
	if i < 0 do return false
	v := strings.trim_left(s[i + 13:], " ")
	return len(v) > 0 && v[0] != '0' && !strings.has_prefix(v, "false")
}

// The boxes waiting: critical first, then the newest (the small ones, a fullscreen window's, are cards).
nd_imm_queue :: proc(n: ^Nd) -> []u32 {
	out := make([dynamic]u32, 0, 8, context.temp_allocator)
	if !n.immersive do return out[:]
	for crit in ([]bool{true, false}) do #reverse for x in n.notes do if x.popup && !x.small && (x.urgency == 2) == crit do append(&out, x.id)
	return out[:]
}

nd_imm_active :: proc(n: ^Nd) -> bool { return len(nd_imm_queue(n)) > 0 }

// The box shown: the queue's picked one.
nd_imm_note :: proc(n: ^Nd) -> (^Note, int, int) {
	q := nd_imm_queue(n)
	if len(q) == 0 do return nil, 0, 0
	n.qi = clamp(n.qi, 0, len(q) - 1)
	i := nd_find(n, q[n.qi])
	if i < 0 do return nil, 0, 0
	return &n.notes[i], n.qi, len(q)
}

// The box's buttons: the reply (when it offers one), its own buttons, else Open; each with a letter.
Nd_Imm_Act :: struct { key, label: string, letter: u8 }

nd_imm_acts :: proc(x: ^Note) -> []Nd_Imm_Act {
	out := make([dynamic]Nd_Imm_Act, 0, 6, context.temp_allocator)
	used: [256]bool
	used['n'] = true // (Super+N's)
	add :: proc(out: ^[dynamic]Nd_Imm_Act, used: ^[256]bool, key, label: string) {
		l: u8 = 0
		for r in strings.to_lower(label, context.temp_allocator) do if r < 128 && r >= 'a' && r <= 'z' && !used[u8(r)] { l = u8(r); break }
		if l != 0 do used[l] = true
		append(out, Nd_Imm_Act{key = key, label = label, letter = l})
	}
	for p in x.actions do if p[0] == "inline-reply" { add(&out, &used, p[0], "Reply"); break }
	for p in x.actions do if p[0] != "default" && p[0] != "inline-reply" && p[1] != "" do add(&out, &used, p[0], p[1])
	if len(out) == 0 do for p in x.actions do if p[0] == "default" { add(&out, &used, "default", "Open"); break }
	return out[:]
}

nd_imm_has_reply :: proc(x: ^Note) -> bool {
	for p in x.actions do if p[0] == "inline-reply" do return true
	return false
}

// Gone from the middle, kept in the centre.
nd_imm_dismiss :: proc(a: ^App, x: ^Note) {
	n := a.nd
	x.popup = false
	nd_signal_closed(n, x.id, 2)
	if n.focus do nd_unfocus(a)
}

// Super+↵, or ↵ with the keys: a reply line takes the keys (or sends what it holds); else the first button.
nd_imm_primary :: proc(a: ^App) {
	n := a.nd
	x, _, _ := nd_imm_note(n)
	if x == nil do return
	if nd_imm_has_reply(x) {
		if n.reply && strings.trim_space(string(a.query[:])) != "" {
			nd_send_reply(a, x.id, string(a.query[:]))
			nd_unfocus(a)
			return
		}
		n.focus, n.reply = true, true
		return
	}
	acts := nd_imm_acts(x)
	if len(acts) > 0 { nd_act(a, x.id, acts[0].key); if n.focus do nd_unfocus(a) }
	else do nd_imm_dismiss(a, x)
}

// The keys bound in Hyprland: "imm enter|esc|keys|next|prev"; "none" when no box is up (the key
// then does its usual job).
nd_imm_command :: proc(a: ^App, what: string) -> (string, bool) {
	n := a.nd
	x, qi, qn := nd_imm_note(n)
	if x == nil do return "none\n", false
	switch what {
	case "enter": nd_imm_primary(a)
	case "esc": nd_imm_dismiss(a, x)
	case "keys":
		n.focus = true
		n.reply = nd_imm_has_reply(x)
	case "next": n.qi = (qi + 1) % qn
	case "prev": n.qi = (qi + qn - 1) % qn
	case: return "unknown\n", false
	}
	return "ok\n", true
}

// The keys while the box has them (Super+N).
nd_imm_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	n := a.nd
	x, qi, qn := nd_imm_note(n)
	if x == nil { nd_unfocus(a); return true }
	if n.reply {
		switch {
		case k == .Escape: nd_unfocus(a)
		case k == .Enter: nd_imm_primary(a)
		case: return app_edit_key(a, k, ctrl, ch, text)
		}
		return true
	}
	switch {
	case k == .Escape || (ctrl && (ch == 'c' || ch == 'g')): nd_unfocus(a)
	case k == .Enter: nd_imm_primary(a)
	case k == .Delete || k == .Backspace: nd_imm_dismiss(a, x)
	case k == .Right || k == .Tab: n.qi = (qi + 1) % qn
	case k == .Left || k == .Back_Tab: n.qi = (qi + qn - 1) % qn
	case len(text) == 1:
		for b in nd_imm_acts(x) do if b.letter == text[0] {
			if b.key == "inline-reply" { n.reply = true; return true }
			nd_act(a, x.id, b.key)
			nd_unfocus(a)
			return true
		}
		return false
	case: return false
	}
	return true
}

// Hits: .Web the backdrop (dismisses), .Chip a button (b: its place), .Item the box (b 1 the reply line).
nd_imm_click :: proc(a: ^App, x, y, button: int) -> bool {
	n := a.nd
	h, ok := hit_at(a, x, y)
	note, _, _ := nd_imm_note(n)
	if !ok || note == nil do return false
	#partial switch h.kind {
	case .Web: nd_imm_dismiss(a, note)
	case .Chip:
		acts := nd_imm_acts(note)
		if h.b < len(acts) {
			if acts[h.b].key == "inline-reply" { n.focus, n.reply = true, true; return true }
			nd_act(a, note.id, acts[h.b].key)
			if n.focus do nd_unfocus(a)
		}
	case .Item: if h.b == 1 { n.focus, n.reply = true, true }
	}
	return true
}

// ---------- drawing ----------

// A note from someone (a message, a mail, a question): it gets their initials.
nd_imm_person :: proc(x: ^Note) -> bool {
	if nd_imm_has_reply(x) do return true
	l := strings.to_lower(x.app, context.temp_allocator)
	for app in ([]string{"messenger", "mail", "gmail", "signal", "whatsapp", "telegram", "discord", "slack", "element", "claude", "localsend", "calendar"}) do if strings.contains(l, app) do return true
	return false
}

// What the box shows of the note: a picture (a screenshot's wide, a cover square), the body's lines.
@(private = "file")
nd_imm_shot :: proc(x: ^Note) -> bool {
	l := strings.to_lower(strings.concatenate({x.app, " ", x.tag, " ", x.title}, context.temp_allocator), context.temp_allocator)
	return x.image != "" && (strings.contains(l, "screenshot") || strings.contains(l, "capture"))
}

nd_imm_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	n := a.nd
	canvas_clear(cv)
	H := hud(a.theme)
	x, qi, qn := nd_imm_note(n)
	if x == nil do return
	// the backdrop: the desktop dimmed; a click there dismisses
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(0x020407, n.focus ? 0x9e : 0x73))
	hit_add(a, 0, 0, cv.w, cv.h, .Web, int(x.id), 0)
	bw := min(ND_IMM_W * S, cv.w - 32 * S)
	bh := nd_imm_box(a, nil, S, 0, 0, bw, x, qi, qn)
	bx := (cv.w - bw) / 2
	by := clamp(cv.h * 58 / 100 - bh / 2, 8 * S, max(cv.h - bh - 8 * S, 8 * S))
	for g := min(qn - 1, 2); g >= 1; g -= 1 { // the others, as edges under it
		gx := 18 * S * g
		fill_rect(cv, bx + gx, by + bh - 40 * S + 10 * S * g, bw - 2 * gx, 40 * S, argb(H.panel, g == 1 ? 0xe6 : 0x80))
		rounded_rect(cv, bx + gx, by + bh - 40 * S + 10 * S * g, bw - 2 * gx, 40 * S, 0, 0, f32(S), argb(H.line, 0xff))
	}
	nd_imm_box(a, cv, S, bx, by, bw, x, qi, qn, bh)
}

// The box at x, y (w wide, total high: measured first); cv nil measures. Returns its height.
nd_imm_box :: proc(a: ^App, cv: ^Canvas, S, x0, y0, w: int, x: ^Note, qi, qn: int, total_h := 0) -> int {
	n := a.nd
	H := hud(a.theme)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	crit := x.urgency == 2
	c := crit ? th.red : (x.warn ? th.yellow : H.acc)
	ac := note_app_color(th, x.app)
	draw := cv != nil
	y := y0
	head := 46 * S
	if draw {
		fill_rect(cv, x0, y0, w, total_h, argb(crit ? 0x12060c : H.panel, 0xf5))
		hit_add(a, x0, y0, w, total_h, .Item, int(x.id), 0) // (the box itself: a click there does not dismiss; what is on it comes after)
		// the head: the app's mark and name, when, its tag, where it is in the queue, "stays"
		mx := x0 + 22 * S
		fill_rect(cv, mx, y + (head - 22 * S) / 2, 22 * S, 22 * S, argb(ac, 0x1f))
		rounded_rect(cv, mx, y + (head - 22 * S) / 2, 22 * S, 22 * S, 0, 0, f32(S), argb(ac, 0x80))
		mono := x.icon != "" ? x.icon : strings.to_upper(x.app[:min(len(x.app), 1)], context.temp_allocator)
		text_in(cv, n.f11b, mono, mx + (22 * S - tw(n.f11b, mono)) / 2, y + (head - 22 * S) / 2, 22 * S, argb(ac, 0xff))
		ax := mx + 32 * S
		app := strings.to_upper(x.app, context.temp_allocator)
		spaced(cv, n.f12b, app, ax, y, head, soft, S)
		ax += spaced_w(n.f12b, app, S) + 10 * S
		when_ := fmt.tprintf("· %s", nd_imm_ago(x.at))
		text_in(cv, n.f12, when_, ax, y, head, argb(H.dim, 0xff))
		ax += tw(n.f12, when_) + 10 * S
		tag := x.tag != "" ? strings.to_upper(x.tag, context.temp_allocator) : (crit ? "CRITICAL" : "")
		if tag != "" {
			tw_ := tw(n.f10b, tag) + 14 * S
			rounded_rect(cv, ax, y + (head - 18 * S) / 2, tw_, 18 * S, 0, 0, f32(S), argb(crit ? th.red : c, 0xff))
			text_in(cv, n.f10b, tag, ax + 7 * S, y + (head - 18 * S) / 2, 18 * S, argb(crit ? th.red : c, 0xff))
		}
		rx := x0 + w - 22 * S
		stay := "stays until you dismiss it"
		rx -= tw(n.f11, stay)
		text_in(cv, n.f11, stay, rx, y, head, argb(H.dim, 0xff))
		if qn > 1 {
			q := fmt.tprintf("‹ %d of %d ›", qi + 1, qn)
			rx -= tw(n.f12, q) + 16 * S
			text_in(cv, n.f12, q, rx, y, head, argb(soft, 0xff))
		}
		fill_rect(cv, x0, y + head - S, w, S, argb(H.line, 0xff))
	}
	y += head
	// the content: a mark at the left (initials, or a cover), then the title, the body, the extras
	pad_x, pad_t := 26 * S, 22 * S
	cy := y + pad_t
	shot := nd_imm_shot(x)
	cover := x.image != "" && !shot
	lx := x0 + pad_x
	person := !shot && !cover && nd_imm_person(x) // someone wrote: their initials (a system note: none)
	mark := cover ? 168 * S : (person ? 64 * S : 0)
	if cover {
		if draw {
			img := image_scaled(a, x.image, mark, mark, true, f32(S))
			if img.ok do blit_image(cv, img.px[:], img.w, img.h, lx, cy)
			rounded_rect(cv, lx, cy, mark, mark, 0, 0, f32(S), argb(H.acc, 0xff))
		}
	} else if person {
		if draw {
			col := crit ? th.red : ac
			fill_rect(cv, lx, cy, mark, mark, argb(col, 0xff))
			ini := msg_initials(x.title)
			if ini == "" do ini = "!"
			text_in(cv, n.f22b, ini, lx + (mark - tw(n.f22b, ini)) / 2, cy, mark, argb(H.bg, 0xff))
			fill_rect(cv, lx + mark - 12 * S, cy, 12 * S, 12 * S, argb(crit ? 0x12060c : H.panel, 0xff)) // the cut corner
		}
	}
	tx := mark == 0 ? lx : lx + mark + 22 * S
	tw_ := x0 + w - pad_x - tx
	ty := cy
	for l, i in wrap_text(n.f22b, x.title, tw_) {
		if i == 2 do break
		if draw do text_in(cv, n.f22b, l, tx, ty, 28 * S, argb(crit ? th.red : H.fg, 0xff))
		ty += 28 * S
	}
	ty += 12 * S
	if x.body != "" { // the body, in its own box
		lines := make([dynamic]string, 0, 8, context.temp_allocator)
		for para in strings.split(nd_plain(x.body), "\n", context.temp_allocator) {
			ws := wrap_text(n.f13, para, tw_ - 28 * S)
			if len(ws) == 0 do append(&lines, "")
			for s in ws do append(&lines, s)
		}
		if len(lines) > 8 { resize(&lines, 8); lines[7] = strings.concatenate({lines[7], " …"}, context.temp_allocator) }
		bh := len(lines) * 21 * S + 24 * S
		if draw {
			fill_rect(cv, tx, ty, tw_, bh, argb(H.bg, 0xff))
			rounded_rect(cv, tx, ty, tw_, bh, 0, 0, f32(S), argb(H.line, 0xff))
			ly := ty + 12 * S
			for l in lines { text_in(cv, n.f13, l, tx + 14 * S, ly, 21 * S, argb(H.fg, 0xff)); ly += 21 * S }
		}
		ty += bh + 12 * S
	}
	if x.quote != "" { // a quoted question (Claude's), with an edge in the box's colour
		ls := wrap_text(n.f14, x.quote, tw_ - 28 * S)
		bh := len(ls) * 22 * S + 24 * S
		if draw {
			fill_rect(cv, tx, ty, tw_, bh, argb(H.bg, 0xff))
			rounded_rect(cv, tx, ty, tw_, bh, 0, 0, f32(S), argb(H.line, 0xff))
			fill_rect(cv, tx, ty, 3 * S, bh, argb(c, 0xff))
			ly := ty + 12 * S
			for l in ls { text_in(cv, n.f14, l, tx + 14 * S, ly, 22 * S, argb(H.fg, 0xff)); ly += 22 * S }
		}
		ty += bh + 12 * S
	}
	if x.progress >= 0 { // a level: the number big, twenty cells
		pc := fmt.tprintf("%d%%", x.progress)
		if draw {
			col := crit ? th.red : c
			text_in(cv, n.f22b, pc, tx, ty, 44 * S, argb(col, 0xff))
			mx := tx + tw(n.f22b, pc) + 16 * S
			cw := (tx + tw_ - mx - 19 * 3 * S) / 20
			for k in 0 ..< 20 do fill_rect(cv, mx + k * (cw + 3 * S), ty + 15 * S, cw, 14 * S, argb(k * 5 < x.progress ? col : H.line, 0xff))
		}
		ty += 44 * S + 12 * S
	}
	if shot { // a screenshot: the picture itself, wide
		ph := 230 * S
		if draw {
			fill_rect(cv, tx, ty, tw_, ph, argb(0x030a11, 0xff))
			img := image_scaled(a, x.image, tw_ - 2 * S, ph - 2 * S, false, f32(S))
			if img.ok do blit_image(cv, img.px[:], img.w, img.h, tx + (tw_ - img.w) / 2, ty + (ph - img.h) / 2)
			rounded_rect(cv, tx, ty, tw_, ph, 0, 0, f32(S), argb(H.acc, 0x66))
		}
		ty += ph + 12 * S
	}
	if nd_imm_has_reply(x) { // the reply line: Super+↵ (or a click) gives it the keys
		on := n.focus && n.reply
		rh := 42 * S
		if draw {
			fill_rect(cv, tx, ty, tw_, rh, argb(H.bg, 0xff))
			rounded_rect(cv, tx, ty, tw_, rh, 0, 0, f32(S), on ? argb(H.acc, 0xb3) : argb(H.line, 0xff))
			fill_rect(cv, tx, ty, 3 * S, rh, argb(on ? H.acc : H.faint, 0xff))
			text_in(cv, n.f13b, "›", tx + 12 * S, ty, rh, argb(H.acc, 0xff))
			q := string(a.query[:])
			who := strings.fields(x.title, context.temp_allocator)
			ph := fmt.tprintf("Reply to %s…%s", len(who) > 0 ? strings.trim_right(who[0], ",·") : "them", on ? "" : "   Super+↵ to write")
			fx := tx + 30 * S
			hint := on ? "↵ send · Esc back" : ""
			fw := tx + tw_ - 12 * S - tw(n.f11, hint) - 10 * S - fx
			if q == "" do text_in(cv, n.f14, ellipsize(n.f14, ph, fw), fx, ty, rh, argb(H.faint, 0xff))
			shown := q
			for tw(n.f14, shown) > fw && len(shown) > 0 do shown = shown[1:]
			text_in(cv, n.f14, shown, fx, ty, rh, argb(H.fg, 0xff))
			if on do fill_rect(cv, fx + (q != "" ? tw(n.f14, shown) + S : 0), ty + 11 * S, 2 * S, 20 * S, argb(H.acc, 0xff))
			if hint != "" do text_in(cv, n.f11, hint, tx + tw_ - 12 * S - tw(n.f11, hint), ty, rh, argb(H.dim, 0xff))
			hit_add(a, tx, ty, tw_, rh, .Item, int(x.id), 1)
		}
		ty += rh + 12 * S
	}
	ty -= 12 * S
	y = max(ty, cy + mark) + 18 * S
	// the buttons: the first in the box's colour with Super+↵; the rest with their letters while the box has the keys
	bh := 38 * S
	bx := x0 + pad_x
	acts := nd_imm_acts(x)
	if draw {
		for b, i in acts {
			key := i == 0 ? (n.focus ? "↵" : "Super+↵") : (n.focus && b.letter != 0 ? string([]u8{b.letter}) : "")
			bw := tw(n.f13b, b.label) + (key != "" ? 9 * S + tw(n.f10, key) : 0) + 32 * S
			if bx + bw > x0 + w - pad_x do break
			if i == 0 do fill_rect(cv, bx, y, bw, bh, argb(c, 0xff))
			rounded_rect(cv, bx, y, bw, bh, 0, 0, f32(S), argb(i == 0 ? c : H.line, 0xff))
			text_in(cv, n.f13b, b.label, bx + 16 * S, y, bh, argb(i == 0 ? H.bg : soft, 0xff))
			if key != "" do text_in(cv, n.f10, key, bx + 16 * S + tw(n.f13b, b.label) + 9 * S, y, bh, argb(i == 0 ? H.bg : H.dim, 0xff))
			hit_add(a, bx, y, bw, bh, .Chip, int(x.id), i)
			bx += bw + 8 * S
		}
		note := n.focus ? "keys go to this box" : "your window keeps the keyboard"
		text_in(cv, n.f11, note, x0 + w - pad_x - tw(n.f11, note), y, bh, argb(H.dim, 0xff))
	}
	y += bh + 20 * S
	// the foot: what the keys do
	fh := 30 * S
	if draw {
		fill_rect(cv, x0, y, w, S, argb(H.line, 0xff))
		hints := make([dynamic][2]string, 0, 6, context.temp_allocator)
		first := len(acts) > 0 ? acts[0].label : "Dismiss"
		if n.focus {
			append(&hints, [2]string{"↵", n.reply ? "Send" : first})
			if !n.reply do for b, i in acts do if i > 0 && b.letter != 0 do append(&hints, [2]string{string([]u8{b.letter}), b.label})
			append(&hints, [2]string{"Esc", "Back"})
		} else {
			append(&hints, [2]string{"Super+↵", first}, [2]string{"Super+Esc", "Dismiss"}, [2]string{"Super+N", "Take keys"})
			if qn > 1 do append(&hints, [2]string{"Super+← →", "Next"})
		}
		hx := x0 + 22 * S
		for h in hints {
			kw := tw(n.f11, h[0]) + 10 * S
			if hx + kw + 6 * S + tw(n.f11, h[1]) > x0 + w - 22 * S do break
			fill_rect(cv, hx, y + (fh - 16 * S) / 2, kw, 16 * S, argb(H.panel, 0xff))
			rounded_rect(cv, hx, y + (fh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, n.f11, h[0], hx + 5 * S, y, fh, argb(soft, 0xff))
			hx += kw + 6 * S
			text_in(cv, n.f11, h[1], hx, y, fh, argb(H.dim, 0xff))
			hx += tw(n.f11, h[1]) + 14 * S
		}
	}
	y += fh
	total := y - y0
	if draw { // the frame: the body's fill under the head, the edge, the corner brackets
		edge := crit ? th.red : mix(H.bg, c, n.focus ? 0.9 : 0.45)
		rounded_rect(cv, x0, y0, w, total, 0, 0, f32(S), argb(edge, 0xff))
		k := 30 * S
		t := 3 * S
		for p in ([][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
			cx := p[0] == 0 ? x0 : x0 + w - k
			cy2 := p[1] == 0 ? y0 : y0 + total - k
			fill_rect(cv, cx, p[1] == 0 ? y0 : y0 + total - t, k, t, argb(c, 0xff))
			fill_rect(cv, p[0] == 0 ? x0 : x0 + w - t, cy2, t, k, argb(c, 0xff))
		}
	}
	return total
}

// When it came: now, 2 min, 3 h, else the time.
@(private = "file")
nd_imm_ago :: proc(at: i64) -> string {
	d := time.to_unix_seconds(time.now()) - at
	if os.get_env("K4_NOTIFY_FIXTURE", context.temp_allocator) != "" do d = 0
	switch {
	case d < 60: return "now"
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 86400: return fmt.tprintf("%d h", d / 3600)
	}
	return msg_clock(at)
}
