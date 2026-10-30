package k4

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// --keymap: your keyboard's QMK layout (k4-keymap, from the keymap.c in a git repo), the Kestrel
// design's KKeymap board: full screen over everything, both halves at their real positions (QMK's
// key positions: the column stagger, the tall thumb keys), a layer at a time. It follows the layer
// the keyboard is on when the firmware reports it (QMK raw HID: k4-keymap act watch, streamed,
// "layer N"); ←→ or 0–9 stay on another layer, f follows the keyboard again. r pulls the repo, o
// opens it in the browser, Esc closes. $K4_KEYMAP_LAYER: the layer it opens on.
// A key: its tap legend; what holding does at its foot, in capitals (a mod in the accent); a layer
// key blue, filled while its layer is the keyboard's ("HOLD · 1"; one that holds a layer keymap.c
// lacks in red: "LAYER 3 ?"); transparent (_______) the key it falls through to, dimmed, with ▽;
// none (XXXXXXX) an empty, darker cap; media and mouse smaller, their kind at the foot. Under the
// keyboard a strip says how to read a key (on a screen 3000 px wide and more, a column beside it).
// --peek (k4-keymap peekd starts it on a layer key): the board's peek, small, bottom middle, over
// everything, taking no input: the keyboard's layer ("HOLDING · 1 · Num", blue; the key let go, the
// base again), gone 5 s after the last layer key.
// The data comes from k4-keymap (panel lines R and L, panel.odin):
//   S <ok|cloning|error> <note>
//   B <board> <layout> <repo> <commit> <file>
//   G <index> <x> <y> <w> <h>          the key positions, in key units, in the LAYOUT's order
//   Y <n> <name> [missing] <keys>      a layer (missing: a key holds it, keymap.c has none)
//   K <layer> <index> <tap> <hold> <key|mod|layer|trans|none|media|mouse> <target layer> <code>
//   U <url>
// The runner's verbs: pull, github, watch (streamed: "layer N", or "nolive REASON").

KM_W, KM_H :: 1920, 1080 // (dry runs and dumps; on screen it is the output's size)

Km_Key :: struct { tap, hold, kind, code: string, target: int }
Km_Layer :: struct { n: int, name: string, missing: bool, keys: [dynamic]Km_Key }
Km_Pos :: struct { x, y, w, h: f32 }

Keymap :: struct {
	using pn: Panel,
	state, note, board, layout, repo, commit, file, url: string,
	pos: [dynamic]Km_Pos,
	layers: [dynamic]Km_Layer,
	pick: int,      // the layer picked by hand (its number; -1: follow the keyboard)
	live: int,      // the keyboard's layer (-1: not known)
	nolive: string, // why it is not live ("" while it is, or not known yet)
	peek: bool,         // --peek: small, no input, for a few seconds
	peek_until: time.Tick,
}

KM_PEEK_MS :: 5000
KM_PEEK_U :: 50 // a key, in px, in the peek

keymap_setup :: proc(a: ^App, data: string) {
	k := new(Keymap)
	k.mode = {draw = km_draw, key = km_key, click = km_click, loaded = km_loaded, stream = km_stream, tick = km_tick, dump = km_dump}
	k.live, k.pick = -1, -1
	if n, ok := strconv.parse_int(os.get_env("K4_KEYMAP_LAYER", context.temp_allocator)); ok do k.pick = n
	panel_init(a, &k.pn, "keymap", data)
	a.width, a.height = KM_W, KM_H
	if sz := strings.split(os.get_env("K4_KEYMAP_SCREEN", context.temp_allocator), "x", context.temp_allocator); len(sz) == 2 { // (dry runs: another screen, e.g. 3440x1440)
		a.width, _ = strconv.parse_int(sz[0]); a.height, _ = strconv.parse_int(sz[1])
	}
	a.fullscreen = true
	if a.opts.peek { // the peek: as big as its keys, no input, a timer
		k.peek, a.fullscreen, a.passive = true, false, true
		maxx, maxy: f32
		for p in k.pos { maxx = max(maxx, p.x + p.w); maxy = max(maxy, p.y + p.h) }
		a.width, a.height = int(maxx * KM_PEEK_U) + 2 * 22, 18 + 22 + 12 + int(maxy * KM_PEEK_U) + 18
		k.peek_until = time.tick_add(time.tick_now(), KM_PEEK_MS * time.Millisecond)
	}
	if k.runner != "" do panel_stream(a, "watch")
}

// The peek goes 5 s after the last layer key.
@(private = "file")
km_tick :: proc(a: ^App) -> int {
	k := KM(a)
	if !k.peek do return -1
	left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), k.peek_until)))
	if left <= 0 && !a.opts.dump && a.opts.dry_run == "" { panel_close(a); return -1 }
	return max(left, 1)
}

@(private = "file")
KM :: proc(a: ^App) -> ^Keymap { return (^Keymap)(a.pn) }

@(private = "file")
km_loaded :: proc(a: ^App, data: string) {
	k := KM(a)
	for &l in k.layers { delete(l.name); for &x in l.keys { delete(x.tap); delete(x.hold); delete(x.kind); delete(x.code) }; delete(l.keys) }
	clear(&k.layers); clear(&k.pos)
	text := data
	num :: proc(s: string) -> int { n, _ := strconv.parse_int(s); return n }
	fl :: proc(s: string) -> f32 { n, _ := strconv.parse_f32(s); return n }
	set :: proc(dst: ^string, v: string) { delete(dst^); dst^ = strings.clone(v) }
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S": set(&k.state, fget(f, 1)); set(&k.note, fget(f, 2))
		case "B": set(&k.board, fget(f, 1)); set(&k.layout, fget(f, 2)); set(&k.repo, fget(f, 3)); set(&k.commit, fget(f, 4)); set(&k.file, fget(f, 5))
		case "U": set(&k.url, fget(f, 1))
		case "G": append(&k.pos, Km_Pos{fl(fget(f, 2)), fl(fget(f, 3)), fl(fget(f, 4)), fl(fget(f, 5))})
		case "Y": append(&k.layers, Km_Layer{n = num(fget(f, 1)), name = strings.clone(fget(f, 2)), missing = fget(f, 3) == "missing"})
		case "K":
			n := num(fget(f, 1))
			for &l in k.layers do if l.n == n {
				idx := num(fget(f, 2))
				for len(l.keys) <= idx do append(&l.keys, Km_Key{target = -1})
				l.keys[idx] = Km_Key{tap = strings.clone(fget(f, 3)), hold = strings.clone(fget(f, 4)), kind = strings.clone(fget(f, 5)), target = num(fget(f, 6)), code = strings.clone(fget(f, 7))}
			}
		}
	}
	slice.sort_by(k.layers[:], proc(x, y: Km_Layer) -> bool { return x.n < y.n })
}

// The layer shown: the one picked, else the keyboard's, else the base.
@(private = "file")
km_shown :: proc(k: ^Keymap) -> int {
	n := k.pick >= 0 ? k.pick : (k.live >= 0 ? k.live : 0)
	for l, i in k.layers do if l.n == n && !l.missing do return i
	return 0
}

// The keyboard's layer: "layer N" shows it; "nolive REASON" says why there is none.
@(private = "file")
km_stream :: proc(a: ^App, line: string) {
	k := KM(a)
	f := fields(line)
	switch f[0] {
	case "layer":
		k.live, _ = strconv.parse_int(fget(f, 1))
		delete(k.nolive); k.nolive = ""
		if k.peek { // the peek shows the keyboard's layer (let go: the base again); a layer key, its 5 s again
			k.pick = k.live
			if k.live != 0 do k.peek_until = time.tick_add(time.tick_now(), KM_PEEK_MS * time.Millisecond)
			return
		}
		if k.pick == k.live do k.pick = -1 // (it caught up with the one picked: following again)
	case "nolive":
		delete(k.nolive); k.nolive = strings.clone(fget(f, 1))
		k.live = -1
	}
}

// Shows layer n (its number); the keyboard's own layer means following it again.
@(private = "file")
km_goto :: proc(a: ^App, n: int) {
	k := KM(a)
	for l in k.layers do if l.n == n && !l.missing {
		k.pick = n == k.live ? -1 : n
		return
	}
	panel_say(&k.pn, fmt.tprintf("No layer %d in %s", n, k.file != "" ? k.file : "keymap.c"), a.theme.yellow)
}

@(private = "file")
km_key :: proc(a: ^App, key: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	k := KM(a)
	real := make([dynamic]int, 0, len(k.layers), context.temp_allocator) // the layers keymap.c has
	for l in k.layers do if !l.missing do append(&real, l.n)
	cur := 0
	for n, i in real do if n == k.layers[km_shown(k)].n do cur = i
	switch {
	case key == .Escape || ctrl && (ch == 'c' || ch == 'g'): panel_close(a)
	case k.state != "ok": // (cloning, or it could not be read: only pulling again, or the browser)
		switch text {
		case "r": panel_run(a, "pull")
		case "o": panel_run(a, "github")
		case: return false
		}
	case (key == .Right || key == .Tab) && len(real) > 0: km_goto(a, real[(cur + 1) % len(real)])
	case (key == .Left || key == .Back_Tab) && len(real) > 0: km_goto(a, real[(cur + len(real) - 1) % len(real)])
	case len(text) == 1 && text[0] >= '0' && text[0] <= '9': km_goto(a, int(text[0] - '0'))
	case text == "f":
		if k.live < 0 do panel_say(&k.pn, "Not live · nothing to follow", a.theme.yellow)
		else { k.pick = -1; panel_say(&k.pn, "Following the keyboard") }
	case text == "r": panel_run(a, "pull")
	case text == "o": panel_run(a, "github")
	case text == "p": panel_run(a, "peek", "toggle")
	case: return false
	}
	return true
}

@(private = "file")
km_click :: proc(a: ^App, x, y, button: int) -> bool {
	k := KM(a)
	h, ok := hit_at(a, x, y)
	if !ok || h.kind != .Chip do return false
	switch {
	case h.a >= 10 && h.a - 10 < len(k.layers):
		l := k.layers[h.a - 10]
		if l.missing do panel_say(&k.pn, fmt.tprintf("Layer %d is held by a key, but %s defines no layer %d", l.n, k.file, l.n), a.theme.red)
		else do km_goto(a, l.n)
	case h.a == 1: panel_run(a, "pull")
	case h.a == 2: panel_run(a, "github")
	}
	return true
}

// What a transparent key does on this layer: the layer it is reached from says (the lowest one
// with a key that turns this one on: held from Base, Base; held from Layer 1, Layer 1), else Base.
@(private = "file")
km_fallthrough :: proc(k: ^Keymap, li, idx: int) -> (Km_Key, bool) {
	from := li
	for depth := 0; depth < 8 && from > 0; depth += 1 {
		n := k.layers[from].n
		src := 0
		search: for l, j in k.layers[:from] do for key in l.keys do if key.kind == "layer" && key.target == n { src = j; break search }
		from = src
		l := k.layers[from]
		if idx < len(l.keys) && l.keys[idx].kind != "trans" do return l.keys[idx], true
	}
	return {}, false
}

@(private = "file")
km_layer_name :: proc(k: ^Keymap, n: int) -> string {
	for l in k.layers do if l.n == n && !l.missing do return l.name
	return fmt.tprintf("Layer %d", n)
}

@(private = "file")
km_has_layer :: proc(k: ^Keymap, n: int) -> bool {
	for l in k.layers do if l.n == n && !l.missing do return true
	return false
}

@(private = "file")
km_why :: proc(r: string) -> string {
	switch r {
	case "no raw hid": return "not live · no layer report in this firmware"
	case "no permission": return "not live · no read access to the keyboard"
	case "not connected": return "not live · the keyboard is not plugged in"
	}
	return r != "" ? fmt.tprintf("not live · %s", r) : ""
}

// A keycap's shape: its top-left and bottom-right corners cut (the board's clip), filled; then its
// outline in `bd`.
@(private = "file")
km_shape :: proc(cv: ^Canvas, x, y, w, h, cut, S: int, fill, bd: u32) {
	for yy in 0 ..< h {
		l := yy < cut ? cut - yy : 0
		r := yy >= h - cut ? yy - (h - cut) + 1 : 0
		fill_rect(cv, x + l, y + yy, w - l - r, 1, bd)
		if yy >= S && yy < h - S do fill_rect(cv, x + l + S + (yy < cut + S ? S : 0), y + yy, max(w - l - r - 2 * S - (yy < cut + S ? S : 0) - (yy >= h - cut - S ? S : 0), 0), 1, fill)
	}
}

@(private = "file")
km_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	k := KM(a)
	if k.peek { km_draw_peek(a, cv, S); return }
	H := hud(a.theme)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	wide := w >= 3000 * S
	fill_rect(cv, 0, 0, w, h, argb(H.bg, 0xe6))
	// the four corner brackets
	bl := 36 * S
	for c in ([4][2]int{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		bx := c[0] == 0 ? 16 * S : w - 16 * S - bl
		by := c[1] == 0 ? 16 * S : h - 16 * S - bl
		fill_rect(cv, bx, c[1] == 0 ? by : by + bl - 2 * S, bl, 2 * S, argb(H.acc, 0xff))
		fill_rect(cv, c[0] == 0 ? bx : bx + bl - 2 * S, by, 2 * S, bl, argb(H.acc, 0xff))
	}
	px := (wide ? 64 : 44) * S
	top := 28 * S
	bottom := h - 22 * S

	// the head: KEYMAP, the board, the repo · file · keys; live or not at the right
	hh := 52 * S
	cw := tw(k.f13b, "KEYMAP") + 16 * S
	fill_rect(cv, px, top + (hh - 24 * S) / 2, cw, 24 * S, argb(H.acc, 0xff))
	text_in(cv, k.f13b, "KEYMAP", px + 8 * S, top + (hh - 24 * S) / 2, 24 * S, argb(H.bg, 0xff))
	tx := px + cw + 14 * S
	bname := k.board != "" ? k.board : "Keyboard"
	text_in(cv, k.f15b, bname, tx, top, hh, argb(H.fg, 0xff))
	tx += tw(k.f15b, bname) + 14 * S
	sub := fmt.tprintf("%s @ %s · %s%s", k.repo, k.commit, k.file != "" ? k.file : "keymap.c", len(k.pos) > 0 ? fmt.tprintf(" · %d keys", len(k.pos)) : "")
	if k.state == "cloning" do sub = fmt.tprintf("cloning %s", k.note)
	st, stc, dot := "", H.dim, u32(0)
	switch {
	case k.state == "cloning": st, stc, dot = fmt.tprintf("cloning %s", k.note), H.acc, H.acc
	case k.state == "error": st = "not live · nothing to show yet"
	case k.live >= 0: st, stc, dot = fmt.tprintf("live · on %d · %s", k.live, km_layer_name(k, k.live)), th.green, th.green
	case k.nolive != "": st = km_why(k.nolive)
	}
	sw := tw(k.f12, st)
	if st != "" {
		text_in(cv, k.f12, st, w - px - sw, top, hh, argb(stc, 0xff))
		d := 8 * S
		dx, dy := w - px - sw - 8 * S - d, top + (hh - d) / 2
		rounded_rect(cv, dx, dy, d, d, f32(d) / 2, argb(dot, dot != 0 ? 0xff : 0), f32(S), argb(stc, 0xff))
	}
	text_in(cv, k.f12, ellipsize(k.f12, sub, w - px - sw - 30 * S - tx), tx, top, hh, argb(H.dim, 0xff))
	yy := top + hh
	fill_rect(cv, px, yy, w - 2 * px, S, argb(H.line, 0xff))

	// the foot: the keys, the last message
	fh := 40 * S
	fy := bottom - fh
	fill_rect(cv, px, fy, w - 2 * px, S, argb(H.line, 0xff))
	hints := [][2]string{{"← →", "Layer"}, {"0–9", "Layer"}, {"f", "Follow live"}, {"r", "Pull"}, {"o", "GitHub"}, {"p", "Peek"}, {"Esc", "Close"}}
	kx := px
	for hk in hints {
		kw := tw(k.f12, hk[0]) + 10 * S
		fill_rect(cv, kx, fy + (fh - 18 * S) / 2, kw, 18 * S, argb(H.panel, 0xff))
		rounded_rect(cv, kx, fy + (fh - 18 * S) / 2, kw, 18 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, k.f12, hk[0], kx + 5 * S, fy, fh, argb(soft, 0xff))
		kx += kw + 6 * S
		text_in(cv, k.f12, hk[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(k.f12, hk[1]) + 16 * S
	}
	if k.toast != "" do text_in(cv, k.f12, k.toast, w - px - tw(k.f12, k.toast), fy, fh, argb(k.tone != 0 ? k.tone : H.acc, 0xff))

	if k.state == "error" {
		km_card(a, cv, S, H, w, yy, fy)
		return
	}

	// the layer tabs, and what the note at their right says
	tabh := 50 * S
	shown := km_shown(k)
	tx = px
	for l, i in k.layers {
		if k.state == "cloning" do break
		sel := i == shown && !l.missing
		is_live := l.n == k.live && !l.missing
		label := l.missing ? "missing" : l.name
		bw := 18 * S + tw(k.f11, fmt.tprint(l.n)) + 9 * S + tw(k.f13b, label) + 18 * S + (is_live ? 9 * S + tw(k.f10, "LIVE") + 22 * S : 0)
		if sel do fill_rect(cv, tx, yy, bw, tabh, argb(H.acc, 0x14))
		if l.missing { fill_rect(cv, tx, yy, bw, tabh, argb(th.red, 0x14)); rounded_rect(cv, tx, yy + S, bw, tabh - S, 0, 0, f32(S), argb(th.red, 0x99)) }
		if sel do fill_rect(cv, tx, yy + tabh - 3 * S, bw, 3 * S, argb(H.acc, 0xff))
		lx := tx + 18 * S
		nc := l.missing ? th.red : (sel ? H.acc : H.faint)
		text_in(cv, k.f11, fmt.tprint(l.n), lx, yy, tabh, argb(nc, 0xff))
		lx += tw(k.f11, fmt.tprint(l.n)) + 9 * S
		text_in(cv, k.f13b, label, lx, yy, tabh, argb(l.missing ? th.red : (sel ? H.fg : H.dim), 0xff))
		lx += tw(k.f13b, label) + 9 * S
		if is_live { // a LIVE chip: the keyboard is on this one
			cw2 := tw(k.f10, "LIVE") + 20 * S
			cy := yy + (tabh - 18 * S) / 2
			rounded_rect(cv, lx, cy, cw2, 18 * S, 0, 0, f32(S), argb(th.green, 0x88))
			rounded_rect(cv, lx + 6 * S, cy + 6 * S, 6 * S, 6 * S, 3, argb(th.green, 0xff))
			text_in(cv, k.f10, "LIVE", lx + 15 * S, cy, 18 * S, argb(th.green, 0xff))
		}
		hit_add(a, tx, yy, bw, tabh, .Chip, 10 + i, 0)
		tx += bw + 4 * S
	}
	note, nc := "", H.dim
	missing := -1
	for l in k.layers do if l.missing do missing = l.n
	following := k.pick < 0 || k.pick == k.live
	sl := k.layers[shown] if len(k.layers) > 0 else Km_Layer{}
	switch {
	case k.state == "cloning": note = "first time: cloning the repo, then reading keymap.c"
	case missing >= 0: note, nc = fmt.tprintf("a key holds layer %d, which %s doesn’t define", missing, k.file), th.red
	case k.live >= 0 && !following: note, nc = fmt.tprintf("Showing %d · %s · the keyboard is on %d · %s · f follows it again", sl.n, sl.name, k.live, km_layer_name(k, k.live)), th.yellow
	case k.live >= 0: note = "follows the keyboard · pick a tab to stay on one"
	case k.nolive == "no raw hid": note = "not live: this firmware sends no layer report · add about 15 lines to keymap.c"
	case k.nolive == "no permission": note = "not live: no read access to the keyboard · a udev rule for it"
	}
	text_in(cv, k.f12, ellipsize(k.f12, note, w - px - tx - 20 * S), w - px - min(tw(k.f12, note), w - px - tx - 20 * S), yy, tabh, argb(nc, 0xff))
	yy += tabh
	fill_rect(cv, px, yy, w - 2 * px, S, argb(H.line, 0xff))

	// how to read a key: a strip under the keyboard, a column beside it on a wide screen
	strip_h := wide ? 0 : 96 * S
	body_top, body_bot := yy, fy - strip_h
	if strip_h > 0 {
		fill_rect(cv, px, body_bot, w - 2 * px, S, argb(H.line, 0xff))
		km_legend(a, cv, S, H, px, body_bot, w - 2 * px, strip_h, false)
	}
	if len(k.pos) == 0 do return

	// the keyboard: as big as fits, at most 94 px a key (104 on a wide screen)
	maxx, maxy: f32
	for p in k.pos { maxx = max(maxx, p.x + p.w); maxy = max(maxy, p.y + p.h) }
	side := wide ? 340 * S + 56 * S : 0
	avail_w := w - 2 * px - 2 * side
	cap := wide ? 104 : 94
	unit := min(f32(avail_w) / maxx, f32(body_bot - body_top - 40 * S) / maxy, f32(cap * S))
	kw_ := int(maxx * unit)
	ox := (w - kw_) / 2
	oy := body_top + (body_bot - body_top - int(maxy * unit)) / 2
	gap0 := wide ? 8 : 7
	gap := max(int(f32(gap0 * S) * unit / f32(cap * S)), 3 * S) // (the board's gap, smaller with the keys)
	if wide do km_legend(a, cv, S, H, ox - 56 * S - 340 * S, oy, 340 * S, int(maxy * unit), true)
	for p, i in k.pos {
		x0, y0 := ox + int(p.x * unit), oy + int(p.y * unit)
		kw, kh := int(p.w * unit) - gap, int(p.h * unit) - gap
		if k.state == "cloning" { // grey caps where the keys will be
			km_shape(cv, x0, y0, kw, kh, int(unit * 0.1), S, argb(H.line, 0xff), argb(H.line, 0xff))
			continue
		}
		l := k.layers[shown]
		key := i < len(l.keys) ? l.keys[i] : Km_Key{kind = "none", target = -1}
		km_cap(a, cv, S, H, k, key, shown, i, x0, y0, kw, kh, unit)
	}
}

// The peek: the layer's label, then its keys at 50 px.
@(private = "file")
km_draw_peek :: proc(a: ^App, cv: ^Canvas, S: int) {
	k := KM(a)
	H := hud(a.theme)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, 0xee))
	rounded_rect(cv, 0, 0, w, h, 0, 0, f32(S), argb(H.line, 0xff))
	if len(k.layers) == 0 || len(k.pos) == 0 do return
	shown := km_shown(k)
	l := k.layers[shown]
	px := 22 * S
	yy := 18 * S
	label := fmt.tprintf("%s · %d · %s", l.n == k.live && l.n != 0 ? "HOLDING" : "LAYER", l.n, l.name)
	lw := tw(k.f12b, label) + 12 * S
	fill_rect(cv, px, yy, lw, 22 * S, argb(a.theme.blue, 0xff))
	text_in(cv, k.f12b, label, px + 6 * S, yy, 22 * S, argb(H.bg, 0xff))
	text_in(cv, k.f12, "peek · 5 s after a layer key · never takes focus", px + lw + 10 * S, yy, 22 * S, argb(H.dim, 0xff))
	yy += 22 * S + 12 * S
	unit := f32(KM_PEEK_U * S)
	gap := 4 * S
	for p, i in k.pos {
		key := i < len(l.keys) ? l.keys[i] : Km_Key{kind = "none", target = -1}
		km_cap(a, cv, S, H, k, key, shown, i, px + int(p.x * unit), yy + int(p.y * unit), int(p.w * unit) - gap, int(p.h * unit) - gap, unit)
	}
}

// One keycap, as the board draws it.
@(private = "file")
km_cap :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, k: ^Keymap, key: Km_Key, li, idx, x, y, w, h: int, unit: f32) {
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	cut := int(unit * 0.1)
	kk := key
	trans := false
	if key.kind == "trans" {
		if down, ok := km_fallthrough(k, li, idx); ok { kk = down; trans = true }
	}
	bg, bd, lc := H.panel, H.line, H.fg
	legend, hold, hc := kk.tap, strings.to_upper(kk.hold, context.temp_allocator), H.acc
	switch {
	case trans:
		bg, bd, lc = mix(H.bg, H.panel, 0.5), mix(H.bg, H.line, 0.7), mix(H.bg, H.dim, 0.6)
		hold = ""
		if kk.kind == "layer" && kk.target >= 0 && legend == fmt.tprintf("L%d", kk.target) do legend = km_layer_name(k, kk.target)
		if kk.kind == "none" do legend = ""
	case kk.kind == "none" || key.kind == "trans":
		km_shape(cv, x, y, w, h, cut, S, argb(mix(H.bg, 0x000000, 0.35), 0xff), argb(mix(H.bg, H.line, 0.5), 0xff))
		return
	case kk.kind == "layer":
		exists := km_has_layer(k, kk.target)
		c := exists ? th.blue : th.red
		on := exists && kk.target == k.live
		if legend == fmt.tprintf("L%d", kk.target) do legend = exists ? km_layer_name(k, kk.target) : fmt.tprintf("L%d", kk.target)
		hold = exists ? fmt.tprintf("HOLD · %d", kk.target) : fmt.tprintf("LAYER %d ?", kk.target)
		if strings.has_prefix(kk.code, "TG(") do hold = fmt.tprintf("TOGGLE · %d", kk.target)
		if strings.has_prefix(kk.code, "LT(") do hold = exists ? fmt.tprintf("LAYER %d", kk.target) : fmt.tprintf("LAYER %d ?", kk.target)
		bg, bd, lc, hc = mix(H.bg, c, 0.07), mix(H.bg, c, 0.6), c, c
		if on { // its layer is on: filled, glowing
			bg, bd, lc, hc = mix(H.bg, c, 0.28), c, H.fg, H.fg
			rounded_rect(cv, x - 3 * S, y - 3 * S, w + 6 * S, h + 6 * S, 0, 0, 2 * f32(S), argb(c, 0x40))
		}
	case kk.kind == "media" || kk.kind == "mouse":
		lc, hold, hc = soft, strings.to_upper(kk.kind, context.temp_allocator), H.dim
	case kk.kind == "mod" && kk.hold == "": // a modifier on its own (Ctrl, Shift…)
		lc = H.acc
	}
	km_shape(cv, x, y, w, h, cut, S, argb(bg, 0xff), argb(bd, 0xff))
	// the legend: one character large, a word smaller, a long one smaller still
	n := strings.rune_count(legend)
	f := n <= 1 ? k.f24 : (n > 4 ? k.f12b : k.f15b)
	if kk.kind == "media" || kk.kind == "mouse" do f = n > 4 ? k.f11b : k.f12b
	if unit < f32(60 * S) do f = k.f11b
	if tw(f, legend) > w - 8 * S do f = k.f10b
	lift := hold != "" ? int(unit * 0.1) : 0
	text_in(cv, f, ellipsize(f, legend, w - 6 * S), x + (w - min(tw(f, legend), w - 6 * S)) / 2, y + (h - int(f.line_h)) / 2 - lift, int(f.line_h), argb(lc, 0xff))
	if hold != "" {
		hf := k.f10b
		hl := ellipsize(hf, hold, w - 6 * S)
		text_in(cv, hf, hl, x + (w - tw(hf, hl)) / 2, y + h - int(unit * 0.08) - int(hf.line_h), int(hf.line_h), argb(hc, 0xff))
	}
	if trans do text_in(cv, k.f10, "▽", x + w - int(unit * 0.07) - tw(k.f10, "▽"), y + int(unit * 0.04), 14 * S, argb(H.dim, 0xff))
}

// How to read a key: six samples with a word each; in a row (the strip) or a column (wide).
@(private = "file")
km_legend :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, column: bool) {
	k := KM(a)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	Sample :: struct { l, hold, words: string, bg, bd, lc, hc: u32, tri: bool }
	blue := th.blue
	samples := [6]Sample{
		{"A", "", "key", H.panel, H.line, H.fg, 0, false},
		{"F", "SHIFT", "tap F, hold Shift", H.panel, H.line, H.fg, H.acc, false},
		{"Num", "", "hold for a layer · lit while live", mix(H.bg, blue, 0.07), mix(H.bg, blue, 0.6), blue, 0, false},
		{"Q", "", "transparent", mix(H.bg, H.panel, 0.5), mix(H.bg, H.line, 0.7), mix(H.bg, H.dim, 0.6), 0, true},
		{"", "", "none", mix(H.bg, 0x000000, 0.35), mix(H.bg, H.line, 0.5), 0, 0, false},
		{"Vol+", "", "media, mouse", H.panel, H.line, soft, 0, false},
	}
	s := (column ? 52 : 44) * S
	if column {
		spaced(cv, k.f11b, "READING A KEY", x, y, 16 * S, H.dim, S)
	}
	cx, cy := x, y + (column ? 28 * S : (h - s) / 2)
	if !column { // centred: measure first
		total := 0
		for sm in samples do total += s + 10 * S + tw(k.f12, sm.words) + 28 * S
		cx = x + (w - total + 28 * S) / 2
	}
	for sm in samples {
		km_shape(cv, cx, cy, s, s, 5 * S, S, argb(sm.bg, 0xff), argb(sm.bd, 0xff))
		f := strings.rune_count(sm.l) > 1 ? k.f11b : k.f15b
		text_in(cv, f, sm.l, cx + (s - tw(f, sm.l)) / 2, cy + (s - int(f.line_h)) / 2 - (sm.hold != "" ? 4 * S : 0), int(f.line_h), argb(sm.lc, 0xff))
		if sm.hold != "" do text_in(cv, k.f8, sm.hold, cx + (s - tw(k.f8, sm.hold)) / 2, cy + s - 13 * S, 10 * S, argb(sm.hc, 0xff))
		if sm.tri do text_in(cv, k.f8, "▽", cx + s - 10 * S, cy + 3 * S, 10 * S, argb(H.dim, 0xff))
		text_in(cv, k.f12, sm.words, cx + s + 10 * S, cy, s, argb(soft, 0xff))
		if column do cy += s + 12 * S
		else do cx += s + 10 * S + tw(k.f12, sm.words) + 28 * S
	}
}

// The keymap could not be read: why, and what to do.
@(private = "file")
km_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, w, top, bottom: int) {
	k := KM(a)
	c := a.theme.yellow
	cw := min(620 * S, w - 88 * S)
	l1 := wrap_text(k.f12, k.note != "" ? k.note : "keymap.c could not be read", cw - 44 * S)
	l2 := wrap_text(k.f12, fmt.tprintf("From %s. Fix the file and pull again; the keyboard itself is fine.", k.url != "" ? strings.trim_prefix(k.url, "https://") : k.repo), cw - 44 * S)
	ch := 20 * S + 22 * S + 12 * S + (len(l1) + len(l2)) * 19 * S + 12 * S + 30 * S + 20 * S
	cx, cy := (w - cw) / 2, top + (bottom - top - ch) / 2
	fill_rect(cv, cx, cy, cw, ch, argb(c, 0x0d))
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, cx, cy, 4 * S, ch, argb(c, 0xff))
	yy := cy + 20 * S
	text_in(cv, k.f15b, "Can’t read keymap.c", cx + 22 * S, yy, 22 * S, argb(c, 0xff))
	yy += 22 * S + 12 * S
	for l in l1 { text_in(cv, k.f12, l, cx + 22 * S, yy, 19 * S, argb(H.fg, 0xff)); yy += 19 * S }
	for l in l2 { text_in(cv, k.f12, l, cx + 22 * S, yy, 19 * S, argb(H.dim, 0xff)); yy += 19 * S }
	yy += 12 * S
	bx := cx + 22 * S
	for b, i in ([2][2]string{{"Pull again", "r"}, {"Open on GitHub", "o"}}) {
		bw := tw(k.f11b, b[0]) + 8 * S + tw(k.f11, b[1]) + 28 * S
		if i == 0 do fill_rect(cv, bx, yy, bw, 30 * S, argb(c, 0xff))
		rounded_rect(cv, bx, yy, bw, 30 * S, 0, 0, f32(S), argb(i == 0 ? c : H.line, 0xff))
		text_in(cv, k.f11b, b[0], bx + 14 * S, yy, 30 * S, argb(i == 0 ? H.bg : mix(H.fg, H.bg, 0.2), 0xff))
		text_in(cv, k.f11, b[1], bx + 14 * S + tw(k.f11b, b[0]) + 8 * S, yy, 30 * S, argb(i == 0 ? H.bg : H.dim, 0xff))
		hit_add(a, bx, yy, bw, 30 * S, .Chip, i + 1, 0)
		bx += bw + 8 * S
	}
}

km_dump :: proc(a: ^App) -> string {
	k := KM(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "keymap %s · %s · %s · %d keys%s", k.state, k.board, k.layout, len(k.pos), k.note != "" ? fmt.tprintf(" · %s", k.note) : "")
	shown := km_shown(k)
	tabs := make([dynamic]string, 0, len(k.layers), context.temp_allocator)
	for l, i in k.layers do append(&tabs, fmt.tprintf("%s%d %s%s%s", i == shown && !l.missing ? "*" : "", l.n, l.name, l.missing ? " (missing)" : "", l.n == k.live && !l.missing ? " (live)" : ""))
	fmt.sbprintfln(&sb, "layers %s", strings.join(tabs[:], " | ", context.temp_allocator))
	if k.live < 0 && k.nolive != "" do fmt.sbprintfln(&sb, "%s", km_why(k.nolive))
	if k.live >= 0 do fmt.sbprintfln(&sb, "%s", k.pick < 0 || k.pick == k.live ? "following" : "picked")
	if shown < len(k.layers) {
		l := k.layers[shown]
		row := make([dynamic]string, 0, 8, context.temp_allocator)
		for key, i in l.keys {
			s := key.tap
			switch key.kind {
			case "none": s = "·"
			case "trans": if d, ok := km_fallthrough(k, shown, i); ok do s = fmt.tprintf("▽%s", d.tap); else do s = "▽"
			case "layer": if key.tap == fmt.tprintf("L%d", key.target) do s = km_has_layer(k, key.target) ? fmt.tprintf("[%s]", km_layer_name(k, key.target)) : fmt.tprintf("[L%d ?]", key.target)
			}
			if key.hold != "" && key.kind != "layer" do s = fmt.tprintf("%s/%s", s, key.hold)
			append(&row, s)
		}
		fmt.sbprintfln(&sb, "keys %s", strings.join(row[:], " "))
	}
	panel_dump_toast(&k.pn, &sb)
	return strings.to_string(sb)
}
