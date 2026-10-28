package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// --osd SPEC: the on-screen display (the Kestrel design's KOsd board): one 400×64 box for every
// kind, bottom centre of the focused output 64 px above its edge, over everything, no input at
// all. It answers a key just pressed (volume, microphone, brightness, the keyboard light, media,
// Caps Lock, the layout, the touchpad) for 1.5 s (media 2.5 s); a second call while it shows
// updates it in place (a datagram to the first one's socket, $XDG_RUNTIME_DIR/k4-osd.sock) and
// starts its hold again.
// The box: a 40 px tile (an icon, or a picture), the label in bold with a line beside it, under
// them a bar, steps or a line, and at the right a value, chips or a media glyph; corners in its
// colour; media also a progress line along the foot.
// SPEC: key=value fields, '|' between (k4-osd and media-menu write them):
//   icon=GLYPH icon_tone=T art=PICTURE tile=T (the tile's outline)
//   label=TEXT label_tone=T sub=TEXT sub_tone=T
//   bar=0..150 (20 steps of 5%, 30 past 100: those yellow) bar_off=1 (muted: grey) flash=last|first
//   steps=N/M (the keyboard light) line=TEXT line_tone=T
//   val=TEXT val_tone=T chips=TEXT:TONE[:fill],… glyph=play|pause|next|prev glyph_tone=T glyph_fill=1
//   prog=0..1000 (media, per mille) prog_tone=T edge=T (the corners) hold=MS
// T: accent fg soft dim faint line red yellow green blue.
// e.g. "icon=󰕾|label=Volume|sub=Speakers · built-in|bar=62|val=62%"

OSD_MS :: 1500
OSD_W, OSD_H :: 400, 64

Osd :: struct {
	f: map[string]string, // the spec's fields
	until: time.Tick,
	sock: linux.Fd,
}

osd_set :: proc(o: ^Osd, spec: string) {
	for k, v in o.f { delete(k); delete(v) }
	clear(&o.f)
	for part in strings.split(spec, "|", context.temp_allocator) {
		eq := strings.index_byte(part, '=')
		if eq <= 0 do continue
		o.f[strings.clone(part[:eq])] = strings.clone(part[eq + 1:])
	}
	hold, ok := strconv.parse_int(osd_get(o, "hold"))
	if !ok || hold <= 0 do hold = OSD_MS
	o.until = time.tick_add(time.tick_now(), time.Duration(hold) * time.Millisecond)
}

osd_get :: proc(o: ^Osd, k: string) -> string { return o.f[k] or_else "" }

@(private)
osd_num :: proc(o: ^Osd, k: string, def: int) -> int {
	n, ok := strconv.parse_int(osd_get(o, k))
	return ok ? n : def
}

@(private)
osd_path :: proc() -> string {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if run == "" do run = "/tmp"
	return fmt.tprintf("%s/k4-osd.sock", run)
}

@(private)
osd_addr :: proc() -> (addr: linux.Sock_Addr_Un, ok: bool) {
	p := osd_path()
	addr.sun_family = .UNIX
	if len(p) >= len(addr.sun_path) do return
	copy(addr.sun_path[:], p)
	return addr, true
}

// Hands the spec to an OSD already showing; false when there is none (this one shows it).
osd_send :: proc(spec: string) -> bool {
	addr := osd_addr() or_return
	fd, err := linux.socket(.UNIX, .DGRAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE do return false
	defer linux.close(fd)
	if linux.connect(fd, &addr) != .NONE do return false
	n, werr := linux.write(fd, transmute([]u8)spec)
	return werr == .NONE && n == len(spec)
}

// The socket later calls reach this one through.
osd_listen :: proc(o: ^Osd) {
	o.sock = -1
	addr, ok := osd_addr()
	if !ok do return
	linux.unlink(strings.clone_to_cstring(osd_path(), context.temp_allocator))
	fd, err := linux.socket(.UNIX, .DGRAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if err != .NONE do return
	if linux.bind(fd, &addr) != .NONE { linux.close(fd); return }
	o.sock = fd
}

osd_close :: proc(o: ^Osd) {
	if o.sock >= 0 {
		linux.close(o.sock)
		linux.unlink(strings.clone_to_cstring(osd_path(), context.temp_allocator))
	}
}

// A datagram arrived: the newest spec wins.
osd_on_readable :: proc(o: ^Osd) -> bool {
	buf: [2048]u8
	got := false
	for {
		n, err := linux.read(o.sock, buf[:])
		if err != .NONE || n <= 0 do break
		osd_set(o, string(buf[:n]))
		got = true
	}
	return got
}

// ms until the box goes; 0 when it has.
osd_left :: proc(o: ^Osd) -> int {
	d := time.tick_diff(time.tick_now(), o.until)
	return max(int(time.duration_milliseconds(d)), 0)
}

// The design's colour names, from the theme.
@(private)
osd_tone :: proc(a: ^App, name: string, def: u32) -> u32 {
	t := a.theme
	H := hud(t)
	switch name {
	case "accent": return H.acc
	case "fg": return H.fg
	case "soft": return mix(H.fg, H.bg, 0.2)
	case "dim": return H.dim
	case "faint": return H.faint
	case "line": return H.line
	case "red": return t.red
	case "yellow": return t.yellow
	case "green": return t.green
	case "blue": return t.blue
	}
	return def
}

osd_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	o := a.osd
	H := hud(a.theme)
	soft := mix(H.fg, H.bg, 0.2)
	tone :: proc(a: ^App, o: ^Osd, k: string, def: u32) -> u32 { return osd_tone(a, osd_get(o, k), def) }
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, 0xff))
	edge := tone(a, o, "edge", H.acc)
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(edge, 0xff), 12)

	// the tile: a picture, else the icon
	ts := 40 * S
	tx, ty := 12 * S, (h - ts) / 2
	fill_rect(cv, tx, ty, ts, ts, argb(H.panel, 0xff))
	drawn := false
	if art := osd_get(o, "art"); art != "" {
		if img := image_cover(a, art, ts - 2 * S, ts - 2 * S); img.ok { blit_image(cv, img.px, img.w, img.h, tx + S, ty + S); drawn = true }
	}
	if !drawn {
		ic := osd_get(o, "icon")
		text_in(cv, a.osd_icon, ic, tx + (ts - tw(a.osd_icon, ic)) / 2, ty, ts, argb(tone(a, o, "icon_tone", H.acc), 0xff))
	}
	rounded_rect(cv, tx, ty, ts, ts, 0, 0, f32(S), argb(tone(a, o, "tile", H.line), 0xff))

	// the right end: a value, chips, or the media glyph
	right := w - 14 * S
	if val := osd_get(o, "val"); val != "" {
		vw := max(tw(a.osd_big, val), 62 * S)
		text_in(cv, a.osd_big, val, right - tw(a.osd_big, val), 0, h, argb(tone(a, o, "val_tone", H.fg), 0xff))
		right -= vw + 12 * S
	} else if chips := osd_get(o, "chips"); chips != "" {
		parts := strings.split(chips, ",", context.temp_allocator)
		cx := right
		#reverse for c in parts {
			f := strings.split(c, ":", context.temp_allocator)
			text := f[0]
			col := osd_tone(a, len(f) > 1 ? f[1] : "", H.acc)
			fill := len(f) > 2 && f[2] == "fill"
			cw := tw(a.osd_chip, text) + 14 * S
			cx -= cw
			cy := (h - 22 * S) / 2
			if fill do fill_rect(cv, cx, cy, cw, 22 * S, argb(col, 0xff))
			if text != "→" do rounded_rect(cv, cx, cy, cw, 22 * S, 0, 0, f32(S), argb(col, 0xff))
			text_in(cv, a.osd_chip, text, cx + 7 * S, cy, 22 * S, argb(fill ? H.bg : col, 0xff))
			cx -= 6 * S
		}
		right = cx - 6 * S
	} else if g := osd_get(o, "glyph"); g != "" {
		gs := 34 * S
		gx, gy := right - gs, (h - gs) / 2
		col := tone(a, o, "glyph_tone", H.acc)
		fill := osd_get(o, "glyph_fill") == "1"
		if fill do fill_rect(cv, gx, gy, gs, gs, argb(col, 0xff))
		rounded_rect(cv, gx, gy, gs, gs, 0, 0, f32(S), argb(fill ? col : H.faint, 0xff))
		gl := "󰐊"
		switch g {
		case "pause": gl = "󰏤"
		case "next": gl = "󰒭"
		case "prev": gl = "󰒮"
		}
		text_in(cv, a.osd_glyph, gl, gx + (gs - tw(a.osd_glyph, gl)) / 2, gy, gs, argb(fill ? H.bg : col, 0xff))
		right = gx - 12 * S
	}

	// the middle: the label and its line, then a bar, steps or a line
	x := tx + ts + 12 * S
	mw := right - x
	label, sub := osd_get(o, "label"), osd_get(o, "sub")
	bar, has_bar := strconv.parse_int(osd_get(o, "bar"))
	steps := osd_get(o, "steps")
	line := osd_get(o, "line")
	second := has_bar || steps != "" || line != ""
	lh := 17 * S
	sh := line != "" ? 15 * S : 8 * S
	y := second ? (h - lh - 7 * S - sh) / 2 : (h - lh) / 2
	lt := ellipsize(a.osd_bold, label, mw)
	text_in(cv, a.osd_bold, lt, x, y, lh, argb(tone(a, o, "label_tone", H.fg), 0xff))
	if sub != "" {
		sx := x + tw(a.osd_bold, lt) + 8 * S
		if sx < x + mw - 20 * S do text_in(cv, a.osd_font, ellipsize(a.osd_font, sub, x + mw - sx), sx, y + S, lh, argb(tone(a, o, "sub_tone", H.dim), 0xff))
	}
	y += lh + 7 * S
	switch {
	case has_bar: // 20 segments of 5%, 30 past 100 (those yellow)
		bar = clamp(bar, 0, 150)
		n := bar > 100 ? 30 : 20
		off := osd_get(o, "bar_off") == "1"
		gap := 2 * S
		extra := n == 30 ? 3 * S : 0
		segw := (mw - (n - 1) * gap - extra) / n
		sx := x
		flash := osd_get(o, "flash")
		for i in 0 ..< n {
			if i == 20 && n == 30 do sx += extra
			lo := i * 5
			over := lo >= 100
			on := off ? H.faint : (over ? a.theme.yellow : H.acc)
			track := over ? mix(H.bg, a.theme.yellow, 0.13) : H.line
			fw := clamp((bar - lo) * segw / 5, 0, segw)
			fill_rect(cv, sx, y, segw, 8 * S, argb(track, 0xff))
			if fw > 0 do fill_rect(cv, sx, y, fw, 8 * S, argb(on, 0xff))
			last := bar > lo && bar - lo <= 5
			if (flash == "last" && i == n - 1) || (flash == "first" && i == 0) do rounded_rect(cv, sx - S, y - S, segw + 2 * S, 10 * S, 0, 0, f32(S), argb(H.fg, 0xff))
			else if last && !off do fill_rect(cv, sx, y - S, fw, S, argb(on, 0x80)) // (the last lit one glows)
			sx += segw + gap
		}
	case steps != "": // the keyboard light's steps
		f := strings.split(steps, "/", context.temp_allocator)
		lv, _ := strconv.parse_int(f[0])
		total := 2
		if len(f) > 1 do total, _ = strconv.parse_int(f[1])
		total = max(total, 1)
		gap := 4 * S
		segw := (mw - (total - 1) * gap) / total
		for i in 0 ..< total do fill_rect(cv, x + i * (segw + gap), y, segw, 8 * S, argb(i < lv ? H.acc : H.line, 0xff))
	case line != "":
		text_in(cv, a.osd_font, ellipsize(a.osd_font, line, mw), x, y, 15 * S, argb(tone(a, o, "line_tone", H.dim), 0xff))
	}
	_ = soft

	// media: how far along, on the foot
	if p, ok := strconv.parse_int(osd_get(o, "prog")); ok {
		fill_rect(cv, S, h - 3 * S, w - 2 * S, 2 * S, argb(H.line, 0xff))
		fill_rect(cv, S, h - 3 * S, (w - 2 * S) * clamp(p, 0, 1000) / 1000, 2 * S, argb(tone(a, o, "prog_tone", H.acc), 0xff))
	}
}

// --dump: the fields as text, in a fixed order (tests).
osd_dump :: proc(o: ^Osd) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "osd")
	for k in ([]string{"label", "sub", "bar", "bar_off", "flash", "steps", "line", "val", "chips", "glyph", "prog", "edge", "hold"}) {
		if v := osd_get(o, k); v != "" do fmt.sbprintf(&sb, " · %s %s", k, v)
	}
	return strings.to_string(sb)
}
