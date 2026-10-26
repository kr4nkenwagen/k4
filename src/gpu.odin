package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:egl"
import gl "vendor:OpenGL"

// Ghostty's custom shaders on k4: the frame k4 draws on the CPU becomes a texture, and the
// shaders Ghostty uses (the custom-shader lines of ~/.config/ghostty/config and the files it
// includes, such as the ghostty-shaders.conf that starfield-toggle writes) run over it in
// order, each one's output the next one's iChannel0, as in Ghostty. The uniforms follow
// Ghostty's Shadertoy set: iResolution, iTime, iTimeDelta, iFrame, iChannel0, and the
// cursor ones (iCurrentCursor, iPreviousCursor, iTimeCursorChange), fed with k4's caret.
// Without EGL / OpenGL 4.3, or with K4_SHADERS=off, k4 draws as before.

Gpu_Prog :: struct {
	id: u32,
	path: string,
	timed, cursor: bool, // reads iTime / iTimeCursorChange
	u_res, u_time, u_delta, u_frame, u_ch0, u_cur, u_prev, u_ccol, u_pcol, u_tcc, u_chres: i32,
}

Gpu :: struct {
	ok:          bool,
	display:     egl.Display,
	ctx:         egl.Context,
	config:      egl.Config,
	surface:     egl.Surface,
	egl_window:  rawptr,
	progs:       [dynamic]Gpu_Prog,
	blit:        Gpu_Prog, // no shaders: copy the canvas
	vao:         u32,
	canvas_tex:  u32,
	tex_w, tex_h: int,
	fbo:         [3]u32, // two ping-pong targets, and the final one for read-back
	fbo_tex:     [3]u32,
	fbo_w, fbo_h: int,
	start:       time.Tick,
	last:        f32,
	frame:       i32,
	animate:     bool,   // a shader reads iTime for more than the cursor: draw every frame
	cursor_anim: bool,   // a shader animates cursor moves: draw frames for a moment after one
	list:        string, // the shader paths, to notice a change (the starfield toggle)
	cursor, prev_cursor: [4]f32,
	cursor_time: f32,
	cursor_color: [4]f32,
	flip:        []u32,
}

G: Gpu

foreign import wl_egl "system:wayland-egl"
@(default_calling_convention = "c")
foreign wl_egl {
	wl_egl_window_create  :: proc(surface: rawptr, w, h: i32) -> rawptr ---
	wl_egl_window_resize  :: proc(win: rawptr, w, h, dx, dy: i32) ---
	wl_egl_window_destroy :: proc(win: rawptr) ---
}

// ---------- the shader list ----------

// The shader files Ghostty would run, in order. K4_SHADERS=off: none; K4_SHADERS=a.glsl:b.glsl:
// those (tests).
shader_paths :: proc() -> [dynamic]string {
	out := make([dynamic]string)
	env := os.get_env("K4_SHADERS", context.temp_allocator)
	if env == "off" do return out
	if env == "list" { // print what Ghostty's config gives, for checking
		home := os.get_env("HOME", context.temp_allocator)
		ghostty_shaders(strings.concatenate({home, "/.config/ghostty/config"}, context.temp_allocator), &out, 0)
		for p in out do fmt.eprintln(p)
		return out
	}
	if env != "" {
		for p in strings.split(env, ":", context.temp_allocator) do if p != "" do append(&out, strings.clone(p))
		return out
	}
	home := os.get_env("HOME", context.temp_allocator)
	cfg := strings.concatenate({home, "/.config/ghostty/config"}, context.temp_allocator)
	ghostty_shaders(cfg, &out, 0)
	return out
}

@(private)
ghostty_shaders :: proc(path: string, out: ^[dynamic]string, depth: int) {
	if depth > 3 do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	dir := path[:max(strings.last_index_byte(path, '/'), 0)]
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 do continue
		key, val := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		val = strings.trim(strings.trim_prefix(val, "?"), "\"") // ?"path": an optional include (the ? comes before the quotes)
		if strings.has_prefix(val, "~/") do val = strings.concatenate({os.get_env("HOME", context.temp_allocator), val[1:]}, context.temp_allocator)
		else if len(val) > 0 && val[0] != '/' do val = strings.concatenate({dir, "/", val}, context.temp_allocator)
		switch key {
		case "custom-shader":
			if val == "" do clear(out)
			else do append(out, strings.clone(val))
		case "config-file": ghostty_shaders(val, out, depth + 1)
		}
	}
}

// ---------- setup ----------

@(private)
gpu_context :: proc(display: egl.Display, window: bool) -> bool {
	G.display = display
	if G.display == egl.NO_DISPLAY do return false
	major, minor: i32
	if !egl.Initialize(G.display, &major, &minor) do return false
	if !egl.BindAPI(egl.OPENGL_API) do return false
	attrs := [?]i32{
		egl.SURFACE_TYPE, window ? egl.WINDOW_BIT : 0,
		egl.RENDERABLE_TYPE, egl.OPENGL_BIT,
		egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.ALPHA_SIZE, 8,
		egl.NONE,
	}
	n: i32
	if !egl.ChooseConfig(G.display, &attrs[0], &G.config, 1, &n) || n < 1 do return false
	ctx_attrs := [?]i32{egl.CONTEXT_MAJOR_VERSION, 4, egl.CONTEXT_MINOR_VERSION, 3, egl.CONTEXT_OPENGL_PROFILE_MASK, egl.CONTEXT_OPENGL_CORE_PROFILE_BIT, egl.NONE}
	G.ctx = egl.CreateContext(G.display, G.config, egl.NO_CONTEXT, &ctx_attrs[0])
	return G.ctx != egl.NO_CONTEXT
}

@(private)
gpu_gl_setup :: proc() -> bool {
	gl.load_up_to(4, 3, proc(p: rawptr, name: cstring) { (^rawptr)(p)^ = egl.GetProcAddress(name) })
	if gl.GenVertexArrays == nil do return false
	gl.GenVertexArrays(1, &G.vao)
	gl.GenTextures(1, &G.canvas_tex)
	gl.GenFramebuffers(3, &G.fbo[0])
	gl.GenTextures(3, &G.fbo_tex[0])
	G.blit = gpu_program("blit", "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }") or_return
	G.start = time.tick_now()
	G.cursor_color = {1, 1, 1, 1}
	gpu_load_shaders()
	return true
}

// On the Wayland surface: a window surface the size of the buffer.
gpu_init_window :: proc(wl_display, wl_surface: rawptr, w, h: int) -> bool {
	if os.get_env("K4_SHADERS", context.temp_allocator) == "off" do return false
	if len(shader_paths()) == 0 do return false // nothing to run: the shm path is lighter
	if !gpu_context(egl.GetDisplay(egl.NativeDisplayType(wl_display)), true) do return false
	G.egl_window = wl_egl_window_create(wl_surface, i32(w), i32(h))
	if G.egl_window == nil do return false
	G.surface = egl.CreateWindowSurface(G.display, G.config, egl.NativeWindowType(G.egl_window), nil)
	if G.surface == egl.NO_SURFACE do return false
	if !egl.MakeCurrent(G.display, G.surface, G.surface, G.ctx) do return false
	egl.SwapInterval(G.display, 0) // k4 paces frames with wl_surface.frame itself
	G.ok = gpu_gl_setup()
	return G.ok
}

// Dry runs: no window (EGL surfaceless), the result read back.
gpu_init_offscreen :: proc() -> bool {
	if !gpu_context(egl.GetPlatformDisplay(.SURFACELESS_MESA, nil, nil), false) do return false
	if !egl.MakeCurrent(G.display, egl.NO_SURFACE, egl.NO_SURFACE, G.ctx) do return false
	G.ok = gpu_gl_setup()
	return G.ok
}

// (Re)compiles the shader list; a shader that does not compile is left out (and reported).
gpu_load_shaders :: proc() {
	paths := shader_paths()
	G.list = strings.join(paths[:], "\n")
	for p in G.progs do gl.DeleteProgram(p.id)
	clear(&G.progs)
	G.animate, G.cursor_anim = false, false
	for path in paths {
		src, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { fmt.eprintfln("k4: cannot read shader %s", path); continue }
		if prog, ok := gpu_program(path, string(src)); ok {
			// a cursor shader's iTime only matters right after the cursor moved
			prog.cursor = strings.contains(string(src), "iTimeCursorChange")
			prog.timed = strings.contains(string(src), "iTime")
			append(&G.progs, prog)
			if prog.timed && !prog.cursor do G.animate = true
			if prog.cursor do G.cursor_anim = true
		}
	}
}

// The shader list changed (the starfield toggle): load it again.
gpu_check_shaders :: proc() {
	if !G.ok do return
	paths := shader_paths()
	if strings.join(paths[:], "\n", context.temp_allocator) != G.list do gpu_load_shaders()
}

VERTEX :: `#version 430 core
void main() {
	vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`

// Ghostty's Shadertoy prelude, as plain uniforms.
PRELUDE :: `#version 430 core
uniform vec3 iResolution;
uniform float iTime;
uniform float iTimeDelta;
uniform float iFrameRate;
uniform int iFrame;
uniform float iChannelTime[4];
uniform vec3 iChannelResolution[4];
uniform vec4 iMouse;
uniform vec4 iDate;
uniform float iSampleRate;
uniform vec4 iCurrentCursor;
uniform vec4 iPreviousCursor;
uniform vec4 iCurrentCursorColor;
uniform vec4 iPreviousCursorColor;
uniform float iTimeCursorChange;
uniform sampler2D iChannel0;
out vec4 k4_fragColor;
`

@(private)
gpu_program :: proc(name, body: string) -> (p: Gpu_Prog, ok: bool) {
	compile :: proc(kind: u32, src: string, name: string) -> (u32, bool) {
		s := gl.CreateShader(kind)
		cs := strings.clone_to_cstring(src, context.temp_allocator)
		gl.ShaderSource(s, 1, &cs, nil)
		gl.CompileShader(s)
		status: i32
		gl.GetShaderiv(s, gl.COMPILE_STATUS, &status)
		if status == 0 {
			log: [2048]u8
			n: i32
			gl.GetShaderInfoLog(s, len(log), &n, &log[0])
			fmt.eprintfln("k4: shader %s does not compile, left out:\n%s", name, string(log[:max(n, 0)]))
			gl.DeleteShader(s)
			return 0, false
		}
		return s, true
	}
	frag := strings.concatenate({PRELUDE, "#line 1\n", body, "\nvoid main() { mainImage(k4_fragColor, gl_FragCoord.xy); }\n"}, context.temp_allocator)
	vs := compile(gl.VERTEX_SHADER, VERTEX, name) or_return
	fs, fok := compile(gl.FRAGMENT_SHADER, frag, name)
	if !fok { gl.DeleteShader(vs); return }
	p.id = gl.CreateProgram()
	gl.AttachShader(p.id, vs)
	gl.AttachShader(p.id, fs)
	gl.LinkProgram(p.id)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
	status: i32
	gl.GetProgramiv(p.id, gl.LINK_STATUS, &status)
	if status == 0 { fmt.eprintfln("k4: shader %s does not link, left out", name); gl.DeleteProgram(p.id); return }
	loc :: proc(id: u32, n: cstring) -> i32 { return gl.GetUniformLocation(id, n) }
	p.u_res, p.u_time, p.u_delta, p.u_frame = loc(p.id, "iResolution"), loc(p.id, "iTime"), loc(p.id, "iTimeDelta"), loc(p.id, "iFrame")
	p.u_ch0, p.u_cur, p.u_prev, p.u_tcc = loc(p.id, "iChannel0"), loc(p.id, "iCurrentCursor"), loc(p.id, "iPreviousCursor"), loc(p.id, "iTimeCursorChange")
	p.u_ccol, p.u_pcol, p.u_chres = loc(p.id, "iCurrentCursorColor"), loc(p.id, "iPreviousCursorColor"), loc(p.id, "iChannelResolution")
	p.path = strings.clone(name)
	return p, true
}

// ---------- drawing ----------

@(private)
tex_params :: proc() {
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
}

// The CPU frame (premultiplied BGRA, top row first) as iChannel0 (bottom row first, as GL
// and Shadertoy count).
gpu_upload :: proc(cv: ^Canvas) {
	if len(G.flip) != len(cv.px) { delete(G.flip); G.flip = make([]u32, len(cv.px)) }
	for y in 0 ..< cv.h do copy(G.flip[(cv.h - 1 - y) * cv.w:][:cv.w], cv.px[y * cv.w:][:cv.w])
	gl.BindTexture(gl.TEXTURE_2D, G.canvas_tex)
	if G.tex_w != cv.w || G.tex_h != cv.h {
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(cv.w), i32(cv.h), 0, gl.BGRA, gl.UNSIGNED_BYTE, raw_data(G.flip))
		tex_params()
		G.tex_w, G.tex_h = cv.w, cv.h
	} else {
		gl.TexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, i32(cv.w), i32(cv.h), gl.BGRA, gl.UNSIGNED_BYTE, raw_data(G.flip))
	}
}

// The caret (top-left origin, buffer pixels) as Ghostty's cursor: x, y of the top-left
// corner counted from the bottom, width, height. A move starts the smear.
gpu_set_cursor :: proc(x, y, w, h, buf_h: int, now: f32) {
	c := [4]f32{f32(x), f32(buf_h - y), f32(w), f32(h)}
	if w == 0 do c = {-1000, -1000, 0, 0}
	if c != G.cursor {
		G.prev_cursor = G.cursor == {} ? c : G.cursor
		G.cursor = c
		G.cursor_time = now
	}
}

// The cursor shaders' colour: the theme's accent (the selection's colour), as Ghostty gives them
// its cursor colour.
gpu_cursor_color :: proc(rgb: u32) {
	G.cursor_color = {f32(rgb >> 16 & 0xff) / 255, f32(rgb >> 8 & 0xff) / 255, f32(rgb & 0xff) / 255, 1}
}

gpu_time :: proc() -> f32 { return f32(time.duration_seconds(time.tick_since(G.start))) }

// Draw again next frame without a content change: an animated shader, or a smear in progress.
gpu_animating :: proc() -> bool {
	if !G.ok do return false
	return G.animate || (G.cursor_anim && gpu_time() - G.cursor_time < 0.5)
}

@(private)
fbo_size :: proc(w, h: int) {
	if G.fbo_w == w && G.fbo_h == h do return
	for i in 0 ..< 3 {
		gl.BindTexture(gl.TEXTURE_2D, G.fbo_tex[i])
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
		tex_params()
		gl.BindFramebuffer(gl.FRAMEBUFFER, G.fbo[i])
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, G.fbo_tex[i], 0)
	}
	G.fbo_w, G.fbo_h = w, h
}

// Runs the chain over the uploaded frame; the last pass draws to `final` (0: the window).
gpu_render :: proc(w, h: int, final: u32, now: f32) {
	fbo_size(w, h)
	gl.BindVertexArray(G.vao)
	gl.Disable(gl.BLEND)
	progs := G.progs[:]
	if len(progs) == 0 do progs = ([]Gpu_Prog{G.blit})
	input := G.canvas_tex
	delta := now - G.last
	for p, i in progs {
		last := i == len(progs) - 1
		target := last ? final : G.fbo[i % 2]
		gl.BindFramebuffer(gl.FRAMEBUFFER, target)
		gl.Viewport(0, 0, i32(w), i32(h))
		gl.UseProgram(p.id)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, input)
		gl.Uniform1i(p.u_ch0, 0)
		gl.Uniform3f(p.u_res, f32(w), f32(h), 1)
		gl.Uniform1f(p.u_time, now)
		gl.Uniform1f(p.u_delta, delta)
		gl.Uniform1i(p.u_frame, G.frame)
		gl.Uniform4f(p.u_cur, G.cursor.x, G.cursor.y, G.cursor.z, G.cursor.w)
		gl.Uniform4f(p.u_prev, G.prev_cursor.x, G.prev_cursor.y, G.prev_cursor.z, G.prev_cursor.w)
		gl.Uniform4f(p.u_ccol, G.cursor_color.x, G.cursor_color.y, G.cursor_color.z, G.cursor_color.w)
		gl.Uniform4f(p.u_pcol, G.cursor_color.x, G.cursor_color.y, G.cursor_color.z, G.cursor_color.w)
		gl.Uniform1f(p.u_tcc, G.cursor_time)
		if p.u_chres >= 0 do gl.Uniform3f(p.u_chres, f32(w), f32(h), 1)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)
		input = G.fbo_tex[i % 2]
	}
	G.last = now
	G.frame += 1
}

// Window: one frame to the surface (the caller asked wl_surface.frame first).
gpu_present :: proc(w, h: int, now: f32) {
	if G.egl_window != nil do wl_egl_window_resize(G.egl_window, i32(w), i32(h), 0, 0)
	gpu_render(w, h, 0, now)
	egl.SwapBuffers(G.display, G.surface)
}

// Dry runs with K4_DRY_SHADERS=1: render offscreen at K4_DRY_TIME seconds and read back.
gpu_dry_run :: proc(cv: ^Canvas) -> bool {
	if !gpu_init_offscreen() do return false
	now: f32 = 1
	if v, ok := strconv.parse_f32(os.get_env("K4_DRY_TIME", context.temp_allocator)); ok do now = v
	gpu_upload(cv)
	fbo_size(cv.w, cv.h)
	gpu_render(cv.w, cv.h, G.fbo[2], now)
	gl.BindFramebuffer(gl.FRAMEBUFFER, G.fbo[2])
	gl.ReadPixels(0, 0, i32(cv.w), i32(cv.h), gl.BGRA, gl.UNSIGNED_BYTE, raw_data(G.flip))
	for y in 0 ..< cv.h do copy(cv.px[y * cv.w:][:cv.w], G.flip[(cv.h - 1 - y) * cv.w:][:cv.w])
	return true
}
