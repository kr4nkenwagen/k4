package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "logic"

// --osd SPEC: the bar's on-screen display (the design's feedback box): 300×48, centred 28 px
// above the bottom of the focused output, for 1.2 s after a volume, brightness, microphone or
// layout key. A second call while one shows updates it in place (a datagram to the first one's
// socket, $XDG_RUNTIME_DIR/k4-osd.sock) and starts its 1.2 s again.
// SPEC, '|'-separated: icon | percent (-1: no track) | max (100, or 150: a tick at 100 and red
// past it) | value | value tone | icon tone | label (drawn instead of the track) | muted
// e.g. "󰕾|62|150|62%", "󰝟|62|150|muted|dim|red||muted", "󰍭|-1||muted|red|red|Microphone"

OSD_MS :: 1200

Osd :: struct {
	icon, value, value_tone, icon_tone, label: string,
	pct, vmax: int,
	muted: bool,
	until: time.Tick,
	sock: linux.Fd,
}

osd_set :: proc(o: ^Osd, spec: string) {
	f := strings.split(spec, "|", context.temp_allocator)
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
	o.icon, o.value = strings.clone(get(f, 0)), strings.clone(get(f, 3))
	o.value_tone, o.icon_tone, o.label = strings.clone(get(f, 4)), strings.clone(get(f, 5)), strings.clone(get(f, 6))
	ok: bool
	if o.pct, ok = strconv.parse_int(get(f, 1)); !ok do o.pct = -1
	if o.vmax, ok = strconv.parse_int(get(f, 2)); !ok || o.vmax <= 0 do o.vmax = 100
	o.muted = get(f, 7) == "muted"
	o.until = time.tick_add(time.tick_now(), OSD_MS * time.Millisecond)
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
	buf: [1024]u8
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

osd_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	o := a.osd
	t := a.theme
	canvas_clear(cv)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(t.bg, 0xff))
	rounded_rect(cv, 0, 0, cv.w, cv.h, 0, 0, f32(2 * S), argb(t.accent, 0xff))
	tone :: proc(t: logic.Theme, name: string, def: u32) -> u32 { return token(t, name, def) }
	f := a.osd_font
	fb := a.osd_bold
	x := 16 * S
	right := cv.w - 16 * S
	if o.icon != "" {
		text_in(cv, a.osd_icon, o.icon, x, 0, cv.h, argb(tone(t, o.icon_tone, t.fg), 0xff))
		x += tw(a.osd_icon, o.icon) + 12 * S
	}
	vw := max(tw(fb, o.value), 48 * S)
	text_in(cv, fb, o.value, right - tw(fb, o.value), 0, cv.h, argb(tone(t, o.value_tone, t.fg), 0xff))
	end := right - vw - 12 * S
	if o.label != "" {
		text_in(cv, f, ellipsize(f, o.label, end - x), x, 0, cv.h, argb(t.fg_dim, 0xff))
	} else if o.pct >= 0 {
		ty := (cv.h - 4 * S) / 2
		w := end - x
		fill_rect(cv, x, ty, w, 4 * S, argb(t.selection, 0xff))
		fill_rect(cv, x, ty, w * min(o.pct, 100) / o.vmax, 4 * S, argb(o.muted ? mix(t.bg, t.fg, 0.3) : t.accent, 0xff))
		if o.pct > 100 do fill_rect(cv, x + w * 100 / o.vmax, ty, w * (min(o.pct, o.vmax) - 100) / o.vmax, 4 * S, argb(t.red, 0xff))
		if o.vmax > 100 do fill_rect(cv, x + w * 100 / o.vmax, ty - 4 * S, S, 12 * S, argb(t.fg_dim, 0xff))
	}
}
