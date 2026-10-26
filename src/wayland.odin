package k4

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import wl "vendor_k4:wayland"
import "vendor_k4:wayland/wlr"

Buffer :: struct {
	wl:   ^wl.buffer,
	px:   []u32,
	w, h: int,
	busy: bool,
}

Output :: struct { wl: ^wl.output, scale: int, name: string }

Wl :: struct {
	app:        ^App,
	ctx:        runtime.Context,
	display:    ^wl.display,
	compositor: ^wl.compositor,
	shm:        ^wl.shm,
	seat:       ^wl.seat,
	keyboard:   ^wl.keyboard,
	pointer:    ^wl.pointer,
	ptr_x, ptr_y: int,  // buffer pixels
	axis_src:   int,    // this frame's axis source (0 wheel: steps come as axis_discrete)
	axis_acc:   f32,    // touchpad scrolling, accumulated
	cursor_theme: rawptr,
	cursor_surface: ^wl.surface,
	shell:      ^wlr.layer_shell_v1,
	outputs:    [dynamic]Output,
	surface:    ^wl.surface,
	layer:      ^wlr.layer_surface_v1,
	buffers:    [2]Buffer,
	width, height: int, // logical, from configure
	scale:      int,
	pref_scale: int,    // wl_surface.preferred_buffer_scale, 0 = not sent
	configured: bool,
	dirty:      bool,
	frame_pending: bool,
	xkb:        ^xkb_context,
	keymap:     ^xkb_keymap,
	state:      ^xkb_state,
	compose:    ^xkb_compose_state,
	repeat_rate, repeat_delay: int,
	repeat_key: u32,
	repeat_at:  time.Tick,
	cpu:        []u32, // GPU path: the CPU frame before the shaders
	bar_h:      int,   // the bar's requested surface height (it grows for a tooltip)
	// the menu's click catcher: a transparent surface under it over the rest of the output
	// (clear of the bar's exclusive zone): a click there closes k4
	catcher:    ^wl.surface,
	catcher_layer: ^wlr.layer_surface_v1,
	catcher_buf: Buffer,
	ptr_surf:   ^wl.surface, // the surface the pointer is on
}

W: Wl

@(private) u :: #force_inline proc "contextless" (v: $T) -> u32 { return u32(uint(v) & 0xffffffff) }
@(private) i :: #force_inline proc "contextless" (v: $T) -> i32 { return i32(u32(uint(v) & 0xffffffff)) }

// ---------- registry ----------
registry_global :: proc "c" (data: rawptr, reg: ^wl.registry, name: uint, iface: cstring, version: uint) {
	context = W.ctx
	ver := u(version)
	switch string(iface) {
	case "wl_compositor": W.compositor = cast(^wl.compositor)wl.registry_bind(reg, name, &wl.compositor_interface, uint(min(ver, 6)))
	case "wl_shm": W.shm = cast(^wl.shm)wl.registry_bind(reg, name, &wl.shm_interface, 1)
	case "wl_seat":
		W.seat = cast(^wl.seat)wl.registry_bind(reg, name, &wl.seat_interface, uint(min(ver, 7)))
		wl.seat_add_listener(W.seat, &seat_listener, nil)
	case "zwlr_layer_shell_v1": W.shell = cast(^wlr.layer_shell_v1)wl.registry_bind(reg, name, &wlr.layer_shell_v1_interface, uint(min(ver, 4)))
	case "wl_output":
		o := cast(^wl.output)wl.registry_bind(reg, name, &wl.output_interface, uint(min(ver, 4)))
		append(&W.outputs, Output{o, 1, ""})
		wl.output_add_listener(o, &output_listener, nil)
	}
}
registry_remove :: proc "c" (data: rawptr, reg: ^wl.registry, name: uint) {}
registry_listener := wl.registry_listener{global = registry_global, global_remove = registry_remove}

// ---------- outputs and scale ----------
out_geometry :: proc "c" (data: rawptr, o: ^wl.output, x, y, pw, ph: int, sub: wl.output_subpixel, make, model: cstring, tr: wl.output_transform) {}
out_mode :: proc "c" (data: rawptr, o: ^wl.output, flags: wl.output_mode, w, h, refresh: int) {}
out_done :: proc "c" (data: rawptr, o: ^wl.output) {}
out_scale :: proc "c" (data: rawptr, o: ^wl.output, factor: int) {
	for &out in W.outputs do if out.wl == o do out.scale = int(i(factor))
}
out_name :: proc "c" (data: rawptr, o: ^wl.output, name: cstring) {
	context = W.ctx
	for &out in W.outputs do if out.wl == o do out.name = strings.clone(string(name))
}
out_desc :: proc "c" (data: rawptr, o: ^wl.output, desc: cstring) {}
output_listener := wl.output_listener{geometry = out_geometry, mode = out_mode, done = out_done, scale = out_scale, name = out_name, description = out_desc}

set_scale :: proc(s: int) {
	s := max(s, 1)
	if s == W.scale do return
	W.scale = s
	W.app.scale = s
	font_resize(&W.app.font, W.app.font_px * f32(s))
	for f in W.app.fonts do font_resize(f, f.base_px * f32(s))
	W.dirty = true
}
surf_enter :: proc "c" (data: rawptr, s: ^wl.surface, o: ^wl.output) {
	context = W.ctx
	if W.pref_scale > 0 do return
	for out in W.outputs do if out.wl == o do set_scale(out.scale)
}
surf_leave :: proc "c" (data: rawptr, s: ^wl.surface, o: ^wl.output) {}
surf_pref_scale :: proc "c" (data: rawptr, s: ^wl.surface, factor: int) {
	context = W.ctx
	W.pref_scale = int(i(factor))
	set_scale(W.pref_scale)
}
surf_pref_transform :: proc "c" (data: rawptr, s: ^wl.surface, t: wl.output_transform) {}
surface_listener := wl.surface_listener{enter = surf_enter, leave = surf_leave, preferred_buffer_scale = surf_pref_scale, preferred_buffer_transform = surf_pref_transform}

// ---------- layer surface ----------
layer_configure :: proc "c" (data: rawptr, ls: ^wlr.layer_surface_v1, serial, w, h: u32) {
	context = W.ctx
	wlr.layer_surface_v1_ack_configure(ls, serial)
	if w > 0 do W.width = int(w)
	if h > 0 do W.height = int(h)
	if W.app.bar != nil do W.app.bar.width = W.width
	W.configured = true
	W.dirty = true
}
layer_closed :: proc "c" (data: rawptr, ls: ^wlr.layer_surface_v1) {
	context = W.ctx
	W.app.exit = 1
	W.app.done = true
}
layer_listener := wlr.layer_surface_v1_listener{configure = layer_configure, closed = layer_closed}

// ---------- seat and keyboard ----------
seat_caps :: proc "c" (data: rawptr, s: ^wl.seat, caps: wl.seat_capability) {
	context = W.ctx
	if u(caps) & 1 != 0 && W.pointer == nil {
		W.pointer = wl.seat_get_pointer(s)
		wl.pointer_add_listener(W.pointer, &pointer_listener, nil)
	}
	has_kb := u(caps) & 2 != 0
	if has_kb && W.keyboard == nil {
		W.keyboard = wl.seat_get_keyboard(s)
		wl.keyboard_add_listener(W.keyboard, &keyboard_listener, nil)
	}
}
seat_name :: proc "c" (data: rawptr, s: ^wl.seat, name: cstring) {}
seat_listener := wl.seat_listener{capabilities = seat_caps, name = seat_name}

kb_keymap :: proc "c" (data: rawptr, kb: ^wl.keyboard, format: wl.keyboard_keymap_format, fd: int, size: uint) {
	context = W.ctx
	f := linux.Fd(i(fd))
	defer linux.close(f)
	if u(format) != 1 do return
	sz := uint(u(size))
	m, err := linux.mmap(0, sz, {.READ}, {.PRIVATE}, f, 0)
	if err != .NONE do return
	defer linux.munmap(m, sz)
	km := keymap_new_from_string(W.xkb, cstring(m), XKB_KEYMAP_FORMAT_TEXT_V1, 0)
	if km == nil do return
	if W.state != nil do state_unref(W.state)
	if W.keymap != nil do keymap_unref(W.keymap)
	W.keymap = km
	W.state = state_new(km)
}
kb_enter :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, s: ^wl.surface, keys: wl.array) {}
kb_leave :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial: uint, s: ^wl.surface) {
	W.repeat_key = 0
}
kb_modifiers :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial, dep, lat, lock, group: uint) {
	if W.state != nil do state_update_mask(W.state, u(dep), u(lat), u(lock), 0, 0, u(group))
}
kb_repeat_info :: proc "c" (data: rawptr, kb: ^wl.keyboard, rate, delay: int) {
	W.repeat_rate = int(i(rate))
	W.repeat_delay = int(i(delay))
}
kb_key :: proc "c" (data: rawptr, kb: ^wl.keyboard, serial, t, key: uint, state: wl.keyboard_key_state) {
	context = W.ctx
	code := u(key) + 8
	if u(state) == 0 { // released
		if W.repeat_key == code do W.repeat_key = 0
		return
	}
	handle_keycode(code)
	if W.keymap != nil && keymap_key_repeats(W.keymap, code) != 0 && W.repeat_rate > 0 {
		W.repeat_key = code
		W.repeat_at = time.tick_add(time.tick_now(), time.Duration(W.repeat_delay) * time.Millisecond)
	}
}
keyboard_listener := wl.keyboard_listener{keymap = kb_keymap, enter = kb_enter, leave = kb_leave, key = kb_key, modifiers = kb_modifiers, repeat_info = kb_repeat_info}

// ---------- pointer ----------
foreign import wl_cursor_lib "system:wayland-cursor"
Wl_Cursor_Image :: struct { width, height, hotspot_x, hotspot_y, delay: u32 }
Wl_Cursor :: struct { image_count: u32, images: [^]^Wl_Cursor_Image, name: cstring }
@(default_calling_convention = "c")
foreign wl_cursor_lib {
	wl_cursor_theme_load       :: proc(name: cstring, size: c.int, shm: ^wl.shm) -> rawptr ---
	wl_cursor_theme_get_cursor :: proc(theme: rawptr, name: cstring) -> ^Wl_Cursor ---
	wl_cursor_image_get_buffer :: proc(image: ^Wl_Cursor_Image) -> ^wl.buffer ---
}

// The theme's arrow over k4 (an entering pointer has no image until the client sets one).
set_cursor :: proc(serial: uint) {
	if W.cursor_theme == nil {
		size := 24
		if v, ok := strconv.parse_int(os.get_env("XCURSOR_SIZE", context.temp_allocator)); ok && v > 0 do size = v
		theme := os.get_env("XCURSOR_THEME", context.temp_allocator)
		W.cursor_theme = wl_cursor_theme_load(theme != "" ? strings.clone_to_cstring(theme, context.temp_allocator) : nil, c.int(size * W.scale), W.shm)
		if W.cursor_theme == nil do return
		W.cursor_surface = wl.compositor_create_surface(W.compositor)
	}
	cur := wl_cursor_theme_get_cursor(W.cursor_theme, "default")
	if cur == nil do cur = wl_cursor_theme_get_cursor(W.cursor_theme, "left_ptr")
	if cur == nil || cur.image_count == 0 do return
	img := cur.images[0]
	buf := wl_cursor_image_get_buffer(img)
	if buf == nil do return
	wl.surface_attach(W.cursor_surface, buf, 0, 0)
	wl.surface_set_buffer_scale(W.cursor_surface, W.scale)
	wl.surface_damage_buffer(W.cursor_surface, 0, 0, int(img.width), int(img.height))
	wl.surface_commit(W.cursor_surface)
	wl.pointer_set_cursor(W.pointer, serial, W.cursor_surface, int(img.hotspot_x) / W.scale, int(img.hotspot_y) / W.scale)
}

ptr_xy :: proc(x, y: wl.fixed_t) { W.ptr_x, W.ptr_y = int(f32(x) / 256 * f32(W.scale)), int(f32(y) / 256 * f32(W.scale)) }
ptr_enter :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, s: ^wl.surface, x, y: wl.fixed_t) {
	context = W.ctx
	W.ptr_surf = s
	set_cursor(serial)
	if s == W.catcher do return
	ptr_xy(x, y)
}
ptr_leave :: proc "c" (data: rawptr, p: ^wl.pointer, serial: uint, s: ^wl.surface) {
	context = W.ctx
	if W.app.bar != nil && app_pointer_move(W.app, -1, -1) do W.dirty = true // no hover, no tooltip
}
ptr_motion :: proc "c" (data: rawptr, p: ^wl.pointer, t: uint, x, y: wl.fixed_t) {
	context = W.ctx
	if W.ptr_surf == W.catcher && W.catcher != nil do return
	ptr_xy(x, y)
	if app_pointer_move(W.app, W.ptr_x, W.ptr_y) do W.dirty = true
}
ptr_button :: proc "c" (data: rawptr, p: ^wl.pointer, serial, t, button: uint, state: wl.pointer_button_state) {
	context = W.ctx
	if state != .pressed do return
	if W.ptr_surf == W.catcher && W.catcher != nil { W.app.exit = 1; W.app.done = true; return } // a click outside closes
	// Hyprland hands the pointer to a keyboard-exclusive layer even off it (negative or past
	// its size): that is a click outside too
	if W.app.bar == nil && W.app.osd == nil && (W.ptr_x < 0 || W.ptr_y < 0 || W.ptr_x >= W.width * W.scale || W.ptr_y >= W.height * W.scale) {
		W.app.exit = 1
		W.app.done = true
		return
	}
	b := 0
	switch u(button) { case 0x110: b = 1; case 0x111: b = 3; case 0x112: b = 2 } // BTN_LEFT, RIGHT, MIDDLE
	if b != 0 && app_pointer_click(W.app, W.ptr_x, W.ptr_y, b) do W.dirty = true
}
ptr_axis :: proc "c" (data: rawptr, p: ^wl.pointer, t: uint, axis: wl.pointer_axis, value: wl.fixed_t) {
	context = W.ctx
	if axis != .vertical_scroll || W.axis_src == 0 do return // a wheel's steps come as axis_discrete
	W.axis_acc += f32(value) / 256
	n := int(W.axis_acc / 15)
	if n != 0 { W.axis_acc -= f32(n) * 15; if app_pointer_scroll(W.app, n) do W.dirty = true }
}
ptr_frame :: proc "c" (data: rawptr, p: ^wl.pointer) { W.axis_src = 0 }
ptr_axis_source :: proc "c" (data: rawptr, p: ^wl.pointer, src: wl.pointer_axis_source) { W.axis_src = int(src) }
ptr_axis_stop :: proc "c" (data: rawptr, p: ^wl.pointer, t: uint, axis: wl.pointer_axis) { W.axis_acc = 0 }
ptr_axis_discrete :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, discrete: int) {
	context = W.ctx
	if axis == .vertical_scroll && app_pointer_scroll(W.app, int(i(discrete))) do W.dirty = true
}
ptr_axis_value120 :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, v: int) {}
ptr_axis_rel :: proc "c" (data: rawptr, p: ^wl.pointer, axis: wl.pointer_axis, d: wl.pointer_axis_relative_direction) {}
pointer_listener := wl.pointer_listener{
	enter = ptr_enter, leave = ptr_leave, motion = ptr_motion, button = ptr_button, axis = ptr_axis, frame = ptr_frame,
	axis_source = ptr_axis_source, axis_stop = ptr_axis_stop, axis_discrete = ptr_axis_discrete,
	axis_value120 = ptr_axis_value120, axis_relative_direction = ptr_axis_rel,
}

handle_keycode :: proc(code: u32) {
	if W.state == nil do return
	sym := state_key_get_one_sym(W.state, code)
	ctrl := state_mod_name_is_active(W.state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0
	alt := state_mod_name_is_active(W.state, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0
	buf: [64]u8
	text: string
	if W.compose != nil && !ctrl && compose_state_feed(W.compose, sym) == XKB_COMPOSE_FEED_ACCEPTED {
		switch compose_state_get_status(W.compose) {
		case XKB_COMPOSE_COMPOSING: return
		case XKB_COMPOSE_CANCELLED: compose_state_reset(W.compose); return
		case XKB_COMPOSE_COMPOSED:
			n := compose_state_get_utf8(W.compose, &buf[0], len(buf))
			compose_state_reset(W.compose)
			text = string(buf[:max(n, 0)])
			if app_key(W.app, .None, false, 0, text) do W.dirty = true
			return
		}
	}
	k := keysym_to_key(sym)
	ch := rune(keysym_to_utf32(sym))
	if k == .None && !ctrl && !alt {
		n := state_key_get_utf8(W.state, code, &buf[0], len(buf))
		text = string(buf[:max(n, 0)])
	}
	if (ctrl || alt) && ch >= 'A' && ch <= 'Z' do ch += 'a' - 'A'
	if app_key(W.app, k, ctrl, ch, text, alt) do W.dirty = true
}

// ---------- buffers and drawing ----------
buffer_release :: proc "c" (data: rawptr, b: ^wl.buffer) {
	(cast(^Buffer)data).busy = false
}
buffer_listener := wl.buffer_listener{release = buffer_release}

buffer_make :: proc(b: ^Buffer, w, h: int) -> bool {
	if b.wl != nil {
		wl.buffer_destroy(b.wl)
		linux.munmap(raw_data(b.px), uint(len(b.px) * 4))
		b^ = {}
	}
	size := w * h * 4
	fd, err := linux.memfd_create("k4", {.CLOEXEC})
	if err != .NONE do return false
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(size)) != .NONE do return false
	m, merr := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE do return false
	pool := wl.shm_create_pool(W.shm, int(fd), size)
	b.wl = wl.shm_pool_create_buffer(pool, 0, w, h, w * 4, .argb8888)
	wl.shm_pool_destroy(pool)
	b.px = (cast([^]u32)m)[:w * h]
	b.w, b.h = w, h
	wl.buffer_add_listener(b.wl, &buffer_listener, b)
	return true
}

frame_done :: proc "c" (data: rawptr, cb: ^wl.callback, t: uint) {
	wl.callback_destroy(cb)
	W.frame_pending = false
}
frame_listener := wl.callback_listener{done = frame_done}

redraw :: proc() {
	if !W.configured || W.frame_pending do return
	w, h := W.width * W.scale, W.height * W.scale
	if G.ok {
		// Ghostty's shaders: redraw the frame on the CPU only when something changed, then run
		// the shader chain to the EGL surface (every frame while one animates)
		if W.dirty || len(W.cpu) != w * h {
			if len(W.cpu) != w * h { delete(W.cpu); W.cpu = make([]u32, w * h) }
			cv := Canvas{W.cpu, w, h}
			app_draw(W.app, &cv, W.scale)
			gpu_upload(&cv)
		}
		now := gpu_time()
		c := W.app.caret
		gpu_set_cursor(c.x, c.y, c.z, c.w, h, now)
		wl.surface_set_buffer_scale(W.surface, W.scale)
		cb := wl.surface_frame(W.surface)
		wl.callback_add_listener(cb, &frame_listener, nil)
		gpu_present(w, h, now) // eglSwapBuffers commits the surface
		W.frame_pending = true
		W.dirty = false
		return
	}
	b: ^Buffer
	for &cand in W.buffers do if !cand.busy { b = &cand; break }
	if b == nil do return
	if b.w != w || b.h != h do if !buffer_make(b, w, h) do return
	cv := Canvas{b.px, w, h}
	app_draw(W.app, &cv, W.scale)
	wl.surface_set_buffer_scale(W.surface, W.scale)
	wl.surface_attach(W.surface, b.wl, 0, 0)
	wl.surface_damage_buffer(W.surface, 0, 0, w, h)
	cb := wl.surface_frame(W.surface)
	wl.callback_add_listener(cb, &frame_listener, nil)
	wl.surface_commit(W.surface)
	b.busy = true
	W.frame_pending = true
	W.dirty = false
}

// The bar grows for a tooltip and shrinks after: the exclusive zone and the input region stay
// the strip, so windows keep their place and clicks under the tooltip reach them.
bar_resize :: proc(b: ^Bar) {
	W.bar_h = b.want_h
	wlr.layer_surface_v1_set_size(W.layer, 0, u32(b.want_h))
	r := wl.compositor_create_region(W.compositor)
	wl.region_add(r, 0, b.bottom ? b.want_h - b.height : 0, 1 << 20, b.height)
	wl.surface_set_input_region(W.surface, r)
	wl.region_destroy(r)
	wl.surface_commit(W.surface)
}

// A popup under a bar module (the bar keeps its exclusive zone, so the margin is from the bar):
// aligned by the module's group, 8 px from the screen edges, 4 px off the bar.
popup_place :: proc(a: ^App) {
	TOP, BOTTOM, LEFT :: i32(1), i32(2), i32(4)
	p := a.opts.popup
	x := p.x
	switch p.side {
	case 1: x = p.x + p.w / 2 - a.width / 2
	case 2: x = p.x + p.w - a.width
	}
	x = clamp(x, 8, max(p.out_w - a.width - 8, 8))
	wlr.layer_surface_v1_set_anchor(W.layer, wlr.layer_surface_v1_anchor((p.bottom ? BOTTOM : TOP) | LEFT))
	if p.bottom do wlr.layer_surface_v1_set_margin(W.layer, 0, 0, 4, i32(x))
	else do wlr.layer_surface_v1_set_margin(W.layer, 4, 0, 0, i32(x))
}

// The menu's size changed (a compact popup fitting its page, or leaving the frame for the
// launcher's): ask for the new size, placed again.
menu_resize :: proc(a: ^App) {
	W.width, W.height = a.width, a.height
	wlr.layer_surface_v1_set_size(W.layer, u32(a.width), u32(a.height))
	if a.opts.popup.set do popup_place(a)
	wl.surface_commit(W.surface)
}

// The click catcher: on the top layer (under k4's overlay surface), anchored to every edge with
// exclusive zone 0, so it covers the output except the bar: clicks there close k4, the bar's
// still reach the bar.
catcher_configure :: proc "c" (data: rawptr, ls: ^wlr.layer_surface_v1, serial, w, h: u32) {
	context = W.ctx
	wlr.layer_surface_v1_ack_configure(ls, serial)
	if w == 0 || h == 0 do return
	b := &W.catcher_buf
	if b.w != int(w) || b.h != int(h) {
		if !buffer_make(b, int(w), int(h)) do return
		for &p in b.px do p = 0 // transparent
	}
	wl.surface_attach(W.catcher, b.wl, 0, 0)
	wl.surface_damage_buffer(W.catcher, 0, 0, b.w, b.h)
	wl.surface_commit(W.catcher)
}
catcher_closed :: proc "c" (data: rawptr, ls: ^wlr.layer_surface_v1) {}
catcher_listener := wlr.layer_surface_v1_listener{configure = catcher_configure, closed = catcher_closed}

catcher_make :: proc() {
	if os.get_env("K4_NO_CATCHER", context.temp_allocator) != "" do return
	TOP, BOTTOM, LEFT, RIGHT :: i32(1), i32(2), i32(4), i32(8)
	W.catcher = wl.compositor_create_surface(W.compositor)
	W.catcher_layer = wlr.layer_shell_v1_get_layer_surface(W.shell, W.catcher, nil, .top, "k4-catcher")
	wlr.layer_surface_v1_add_listener(W.catcher_layer, &catcher_listener, nil)
	wlr.layer_surface_v1_set_anchor(W.catcher_layer, wlr.layer_surface_v1_anchor(TOP | BOTTOM | LEFT | RIGHT))
	wlr.layer_surface_v1_set_exclusive_zone(W.catcher_layer, 0)
	wlr.layer_surface_v1_set_keyboard_interactivity(W.catcher_layer, .none)
	wl.surface_commit(W.catcher)
}

// ---------- main loop ----------
run_wayland :: proc(a: ^App) -> bool {
	W.app = a
	W.ctx = context
	W.scale = 1
	W.repeat_rate, W.repeat_delay = 25, 600
	W.display = wl.display_connect(nil)
	if W.display == nil {
		fmt.eprintln("k4: cannot connect to a Wayland display")
		return false
	}
	W.xkb = context_new(0)
	locale := os.get_env("LC_ALL", context.temp_allocator)
	if locale == "" do locale = os.get_env("LC_CTYPE", context.temp_allocator)
	if locale == "" do locale = os.get_env("LANG", context.temp_allocator)
	if locale == "" do locale = "C"
	if tbl := compose_table_new_from_locale(W.xkb, strings.clone_to_cstring(locale, context.temp_allocator), 0); tbl != nil {
		W.compose = compose_state_new(tbl, 0)
	}

	reg := wl.display_get_registry(W.display)
	wl.registry_add_listener(reg, &registry_listener, nil)
	wl.display_roundtrip(W.display)
	if W.compositor == nil || W.shm == nil || W.shell == nil {
		fmt.eprintln("k4: the compositor lacks wl_compositor, wl_shm or zwlr_layer_shell_v1")
		return false
	}
	wl.display_roundtrip(W.display) // seat capabilities, output scales

	W.surface = wl.compositor_create_surface(W.compositor)
	wl.surface_add_listener(W.surface, &surface_listener, nil)
	TOP, BOTTOM, LEFT, RIGHT :: i32(1), i32(2), i32(4), i32(8)
	if a.osd != nil {
		// the feedback box: centred above the bottom of the focused output, no input at all
		W.layer = wlr.layer_shell_v1_get_layer_surface(W.shell, W.surface, nil, .overlay, "k4-osd")
		wlr.layer_surface_v1_add_listener(W.layer, &layer_listener, nil)
		W.width, W.height = a.width, a.height
		wlr.layer_surface_v1_set_size(W.layer, u32(a.width), u32(a.height))
		wlr.layer_surface_v1_set_anchor(W.layer, wlr.layer_surface_v1_anchor(BOTTOM))
		wlr.layer_surface_v1_set_margin(W.layer, 0, 0, 28, 0) // above a bottom bar too (exclusive zone 0 keeps clear of it)
		r := wl.compositor_create_region(W.compositor)
		wl.surface_set_input_region(W.surface, r)
		wl.region_destroy(r)
		wl.surface_commit(W.surface)
	} else if a.bar != nil {
		// the bar: a strip along the top of its output that windows keep clear of, no keyboard
		out: ^wl.output
		for o in W.outputs do if o.name == a.opts.output do out = o.wl
		if a.opts.output != "" && out == nil do fmt.eprintfln("k4: no output %q; the compositor picks one", a.opts.output)
		W.layer = wlr.layer_shell_v1_get_layer_surface(W.shell, W.surface, out, .top, "k4-bar")
		wlr.layer_surface_v1_add_listener(W.layer, &layer_listener, nil)
		W.width, W.height = 0, a.height
		W.bar_h = a.height
		wlr.layer_surface_v1_set_size(W.layer, 0, u32(a.height))
		wlr.layer_surface_v1_set_anchor(W.layer, wlr.layer_surface_v1_anchor((a.bar.bottom ? BOTTOM : TOP) | LEFT | RIGHT))
		wlr.layer_surface_v1_set_exclusive_zone(W.layer, i32(a.height))
		wl.surface_commit(W.surface)
	} else {
	W.layer = wlr.layer_shell_v1_get_layer_surface(W.shell, W.surface, nil, .overlay, "k4")
	wlr.layer_surface_v1_add_listener(W.layer, &layer_listener, nil)
	W.width, W.height = a.width, a.height
	wlr.layer_surface_v1_set_size(W.layer, u32(a.width), u32(a.height))
	anchor: i32
	switch a.opts.anchor {
	case .Center:
	case .Top: anchor = TOP
	case .Top_Left: anchor = TOP | LEFT
	case .Top_Right: anchor = TOP | RIGHT
	case .Bottom: anchor = BOTTOM
	case .Bottom_Left: anchor = BOTTOM | LEFT
	case .Bottom_Right: anchor = BOTTOM | RIGHT
	case .Left: anchor = LEFT
	case .Right: anchor = RIGHT
	}
	wlr.layer_surface_v1_set_anchor(W.layer, wlr.layer_surface_v1_anchor(anchor))
	m := i32(a.opts.margin)
	wlr.layer_surface_v1_set_margin(W.layer, m, m, m, m)
	if a.opts.popup.set do popup_place(a)
	wlr.layer_surface_v1_set_keyboard_interactivity(W.layer, .exclusive)
	wl.surface_commit(W.surface)
	catcher_make()
	// Ghostty's shaders when it has any and EGL / OpenGL 4.3 work; else the shm path
	if !gpu_init_window(W.display, W.surface, a.width * W.scale, a.height * W.scale) && G.display != nil && len(shader_paths()) > 0 {
		fmt.eprintln("k4: shaders need EGL with OpenGL 4.3; drawing without them")
	}
	}

	fd := linux.Fd(i(wl.display_get_fd(W.display)))
	for !a.done {
		for i(wl.display_prepare_read(W.display)) != 0 do wl.display_dispatch_pending(W.display)
		wl.display_flush(W.display)
		timeout: i32 = -1
		if W.repeat_key != 0 {
			left := time.tick_diff(time.tick_now(), W.repeat_at)
			timeout = i32(max(time.duration_milliseconds(left), 0))
		}
		if (W.dirty || gpu_animating()) && !W.frame_pending && W.configured do timeout = 0
		tick := a.menu != nil ? menu_tick_ms(a.menu) : -1 // a slow loader: the waiting count and slow lines
		if a.bar != nil do tick = bar_tick(a)               // the bar: the clock and the next module run
		if a.osd != nil {                                   // the feedback box: gone after 1.2 s
			left := osd_left(a.osd)
			if left == 0 { a.done = true; break }
			tick = left
		}
		if tick >= 0 && (timeout < 0 || i32(tick) < timeout) do timeout = i32(tick)
		fds := make([dynamic]linux.Poll_Fd, 0, 8, context.temp_allocator)
		append(&fds, linux.Poll_Fd{fd = fd, events = {.IN}})
		if a.menu != nil do menu_poll_fds(a.menu, &fds) // background section loaders
		if a.bar != nil do bar_poll_fds(a.bar, &fds)       // module commands, sway events
		if a.osd != nil && a.osd.sock >= 0 do append(&fds, linux.Poll_Fd{fd = a.osd.sock, events = {.IN}})
		n, _ := linux.poll(fds[:], timeout)
		if n == 0 && tick >= 0 {
			if a.bar != nil { bar_tick(a) } else if a.menu != nil do menu_on_tick(a)
			W.dirty = true
		}
		if n > 0 && .IN in fds[0].revents {
			if i(wl.display_read_events(W.display)) < 0 { a.exit = 1; break }
		} else {
			wl.display_cancel_read(W.display)
		}
		for pf in fds[1:] do if pf.revents != {} {
			if a.osd != nil { if osd_on_readable(a.osd) do W.dirty = true }
			else if a.bar != nil { if bar_on_readable(a, pf.fd) do W.dirty = true }
			else if menu_on_readable(a, pf.fd) do W.dirty = true
		}
		free_all(context.temp_allocator)
		if i(wl.display_dispatch_pending(W.display)) < 0 { a.exit = 1; break }
		if W.repeat_key != 0 && time.tick_diff(W.repeat_at, time.tick_now()) >= 0 {
			handle_keycode(W.repeat_key)
			W.repeat_at = time.tick_add(time.tick_now(), time.Second / time.Duration(max(W.repeat_rate, 1)))
		}
		if a.bar != nil && a.bar.want_h != W.bar_h && W.configured do bar_resize(a.bar)
		if a.menu != nil && W.configured {
			w, h := menu_size(a)
			if w != a.width || h != a.height { a.width, a.height = w, h; menu_resize(a) }
		}
		if (W.dirty || gpu_animating()) && !a.done do redraw()
	}
	wl.display_disconnect(W.display)
	return true
}
