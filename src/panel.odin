package k4

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// The shared parts of k4's script-fed windows (--pass, --keyring, --media, --drives, --snap): a
// table of the mode's procedures, the fonts, the script's runner and loader run in the
// background, the footer's message, a text field, and the Kestrel design's pieces (head, footer,
// notice, buttons, tags). The script's data comes on stdin; two of its lines are the panel's:
//   R <command>   actions run as `<command> VERB [ARG…]` (a typed secret in $K4_INPUT); its
//                 output's last line is the footer's message; k4: lines are directives:
//                 k4:close closes, k4:result TEXT closes printing TEXT, k4:tone red|yellow|green
//                 colours the message, k4:reload loads again; the mode reads the rest
//   L <command>   the data again (after every run, and every refresh while open)
// Without R (tests) a run only says what it would run: "(VERB ARG)".

Mode :: struct {
	draw:   proc(a: ^App, cv: ^Canvas, S: int),
	key:    proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool,
	click:  proc(a: ^App, x, y, button: int) -> bool,
	scroll: proc(a: ^App, n: int) -> bool,              // may be nil
	loaded: proc(a: ^App, data: string),                // stdin at the start, then the loader's output
	ran:    proc(a: ^App, verb, line: string) -> bool,  // a k4: line the panel does not know; true: used
	tick:   proc(a: ^App) -> int,                       // may be nil: ms to the mode's next tick, -1 none
	stream: proc(a: ^App, line: string),                // may be nil: a streamed run's lines as they come, then "k4:end"
	dump:   proc(a: ^App) -> string,
}

Pjob :: struct {
	p:       os.Process,
	out:     string,
	verb:    string,
	running: bool,
	started: time.Tick,
}

Panel :: struct {
	mode:       Mode, // the procedures
	name:       string, // the mode's name: temp files, the layer's namespace
	runner, loader: string,
	refresh_ms: int,    // load again every N ms while open (0: only after runs)
	loaded_at:  time.Tick,
	run, load:  Pjob,
	sjob:       Pjob,   // a streamed run (panel_stream): its output is read as it grows
	soff:       int,    // how much of it was handed over
	spart:      [dynamic]u8, // a line not finished yet
	toast:      string,
	tone:       u32,    // the message's colour; 0 the accent
	toast_at:   time.Tick,
	input:      [dynamic]u8, // a text field (a name, a passphrase)
	reveal:     bool,        // the field shows what was typed (Tab)
	popup:      bool,        // under a bar module (--popup)
	f8, f9, f9b, f10, f10b, f11, f11b, f12, f12b, f13, f13b, f15, f15b, f24, f34, icon: ^Font,
}

panel_init :: proc(a: ^App, p: ^Panel, name: string, data: string) {
	a.pn = p
	p.name = name
	p.popup = a.opts.popup.set
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	p.f8, p.f9, p.f10, p.f11, p.f12, p.f13, p.f15, p.icon = reg(a, 8), reg(a, 9), reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 13), reg(a, 15), reg(a, 16)
	p.f9b, p.f10b, p.f11b, p.f12b, p.f13b, p.f15b, p.f24, p.f34 = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 15), reg(a, 24), reg(a, 34)
	panel_lines(p, data)
	p.mode.loaded(a, data)
	p.loaded_at = time.tick_now()
}

// The panel's own lines of some data: the runner and the loader.
@(private = "file")
panel_lines :: proc(p: ^Panel, data: string) {
	text := data
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "R\t") { delete(p.runner); p.runner = strings.clone(line[2:]) }
		if strings.has_prefix(line, "L\t") { delete(p.loader); p.loader = strings.clone(line[2:]) }
	}
}

// Fields of a tab-separated line; missing ones are "".
fields :: proc(line: string) -> []string { return strings.split(line, "\t", context.temp_allocator) }
fget :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }

panel_say :: proc(p: ^Panel, msg: string, tone: u32 = 0) {
	if len(p.toast) > 0 do delete(p.toast)
	p.toast = strings.clone(msg)
	p.tone = tone
	p.toast_at = time.tick_now()
}

panel_close :: proc(a: ^App, result := "") {
	a.result = strings.clone(result)
	a.exit = 0
	a.done = true
}

// ---------- the script ----------

@(private = "file")
pjob_start :: proc(p: ^Panel, j: ^Pjob, tag, cmd: string, secret: string) -> bool {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	j.out = fmt.aprintf("%s/k4-%s-%s-%d.out", run != "" ? run : "/tmp", p.name, tag, os.get_pid())
	env: [dynamic]string
	env.allocator = context.temp_allocator
	if secret != "" { // a passphrase goes in the environment, not on the command line
		envs, _ := os.environ(context.temp_allocator)
		for e in envs do append(&env, e)
		append(&env, strings.concatenate({"K4_INPUT=", secret}, context.temp_allocator))
	}
	pr, err := os.process_start({command = {"sh", "-c", fmt.tprintf("%s > %s 2>&1 </dev/null", cmd, sh_quote(j.out))}, env = len(env) > 0 ? env[:] : nil})
	if err != nil { delete(j.out); j.out = ""; return false }
	j.p, j.running, j.started = pr, true, time.tick_now()
	return true
}

@(private = "file")
pjob_poll :: proc(j: ^Pjob) -> (text: string, done: bool) {
	if !j.running do return
	st, _ := os.process_wait(j.p, 0)
	if !st.exited do return
	j.running = false
	data, err := os.read_entire_file(j.out, context.temp_allocator)
	if err == nil do text = string(data)
	os.remove(j.out)
	delete(j.out)
	j.out = ""
	return text, true
}

// Runs `<runner> VERB ARG…` in the background (in the foreground for dry runs and dumps, so a
// test's runner answers before the frame). secret: $K4_INPUT.
panel_run :: proc(a: ^App, verb: string, args: ..string, secret := "") {
	p := a.pn
	if p.runner == "" {
		parts := make([dynamic]string, 0, 4, context.temp_allocator)
		append(&parts, verb)
		for x in args do append(&parts, x)
		panel_say(p, fmt.tprintf("(%s)", strings.join(parts[:], " ", context.temp_allocator)))
		return
	}
	if p.run.running { panel_say(p, "Still busy with the last one…", a.theme.yellow); return }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, p.runner)
	strings.write_byte(&sb, ' ')
	strings.write_string(&sb, sh_quote(verb))
	for x in args { strings.write_byte(&sb, ' '); strings.write_string(&sb, sh_quote(x)) }
	delete(p.run.verb)
	p.run.verb = strings.clone(verb)
	if a.opts.dump || a.opts.dry_run != "" {
		env: [dynamic]string
		env.allocator = context.temp_allocator
		if secret != "" {
			envs, _ := os.environ(context.temp_allocator)
			for e in envs do append(&env, e)
			append(&env, strings.concatenate({"K4_INPUT=", secret}, context.temp_allocator))
		}
		_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}, env = len(env) > 0 ? env[:] : nil}, context.temp_allocator)
		panel_ran(a, verb, string(out))
		return
	}
	if !pjob_start(p, &p.run, "run", strings.to_string(sb), secret) do panel_say(p, fmt.tprintf("Could not run %s", p.runner), a.theme.red)
}

// The loader again, in the background (unless one runs already).
panel_reload :: proc(a: ^App) {
	p := a.pn
	p.loaded_at = time.tick_now()
	if p.loader == "" || p.load.running do return
	if a.opts.dump || a.opts.dry_run != "" {
		_, out, _, _ := os.process_exec({command = {"sh", "-c", p.loader}}, context.temp_allocator)
		panel_lines(p, string(out))
		p.mode.loaded(a, string(out))
		return
	}
	pjob_start(p, &p.load, "load", p.loader, "")
}

@(private = "file")
panel_ran :: proc(a: ^App, verb, out: string) {
	p := a.pn
	msg := ""
	tone: u32 = 0
	reload := true
	for line in strings.split_lines(strings.trim_right_space(out), context.temp_allocator) {
		l := strings.trim_right_space(line)
		switch {
		case l == "": continue
		case l == "k4:close": panel_close(a); return
		case strings.has_prefix(l, "k4:result "): panel_close(a, l[10:]); return
		case l == "k4:reload": reload = true
		case l == "k4:noreload": reload = false
		case strings.has_prefix(l, "k4:tone "):
			switch l[8:] {
			case "red": tone = a.theme.red
			case "yellow": tone = a.theme.yellow
			case "green": tone = a.theme.green
			case "dim": tone = a.theme.fg_dim
			}
		case strings.has_prefix(l, "k4:"): p.mode.ran(a, verb, l)
		case: msg = l
		}
	}
	if msg != "" do panel_say(p, msg, tone)
	if reload do panel_reload(a)
}

// How long the event loop may sleep: the jobs are polled, the refresh is due, the mode's own.
panel_tick_ms :: proc(a: ^App) -> int {
	p := a.pn
	t := -1
	if p.run.running || p.load.running do t = 60
	if p.sjob.running do t = 40
	if p.refresh_ms > 0 {
		left := p.refresh_ms - int(time.duration_milliseconds(time.tick_since(p.loaded_at)))
		t = t < 0 ? max(left, 1) : min(t, max(left, 1))
	}
	if p.mode.tick != nil {
		if m := p.mode.tick(a); m >= 0 do t = t < 0 ? m : min(t, m)
	}
	return t
}

panel_on_tick :: proc(a: ^App) {
	p := a.pn
	if p.mode.tick != nil do p.mode.tick(a) // the mode's timers (a countdown, a reveal running out)
	panel_stream_poll(a)
	if out, done := pjob_poll(&p.run); done do panel_ran(a, p.run.verb, out)
	if a.done do return
	if out, done := pjob_poll(&p.load); done {
		panel_lines(p, out)
		p.mode.loaded(a, out)
	}
	if p.refresh_ms > 0 && int(time.duration_milliseconds(time.tick_since(p.loaded_at))) >= p.refresh_ms do panel_reload(a)
}

panel_busy :: proc(p: ^Panel) -> bool { return p.run.running }
panel_streaming :: proc(p: ^Panel) -> bool { return p.sjob.running }

// Runs `<runner> VERB ARG…` and hands its output to the mode's stream proc line by line while it
// runs (an answer appearing as it is written), then "k4:end". Dry runs and dumps run it at once.
panel_stream :: proc(a: ^App, verb: string, args: ..string, secret := "") {
	p := a.pn
	if p.runner == "" {
		parts := make([dynamic]string, 0, 4, context.temp_allocator)
		append(&parts, verb)
		for x in args do append(&parts, x)
		panel_say(p, fmt.tprintf("(%s)", strings.join(parts[:], " ", context.temp_allocator)))
		return
	}
	if p.sjob.running do panel_stop(a)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, p.runner)
	strings.write_byte(&sb, ' ')
	strings.write_string(&sb, sh_quote(verb))
	for x in args { strings.write_byte(&sb, ' '); strings.write_string(&sb, sh_quote(x)) }
	if a.opts.dump || a.opts.dry_run != "" {
		_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}}, context.temp_allocator)
		for line in strings.split_lines(string(out), context.temp_allocator) do if line != "" do p.mode.stream(a, line)
		p.mode.stream(a, "k4:end")
		return
	}
	p.soff = 0
	clear(&p.spart)
	if !pjob_start(p, &p.sjob, "stream", strings.to_string(sb), secret) do panel_say(p, fmt.tprintf("Could not run %s", p.runner), a.theme.red)
}

// Stops a streamed run (Esc while an answer is coming).
panel_stop :: proc(a: ^App) {
	p := a.pn
	if !p.sjob.running do return
	_ = os.process_kill(p.sjob.p)
	_, _ = os.process_wait(p.sjob.p, 200 * time.Millisecond)
	p.sjob.running = false
	if p.sjob.out != "" { os.remove(p.sjob.out); delete(p.sjob.out); p.sjob.out = "" }
	clear(&p.spart)
	p.mode.stream(a, "k4:end")
}

// The new part of a streamed run's output, as whole lines; at its end the rest, then "k4:end".
@(private = "file")
panel_stream_poll :: proc(a: ^App) {
	p := a.pn
	if !p.sjob.running do return
	st, _ := os.process_wait(p.sjob.p, 0)
	data, err := os.read_entire_file(p.sjob.out, context.temp_allocator)
	if err == nil && len(data) > p.soff {
		append(&p.spart, ..data[p.soff:])
		p.soff = len(data)
		for {
			nl := -1
			for c, i in p.spart do if c == '\n' { nl = i; break }
			if nl < 0 do break
			line := strings.clone(string(p.spart[:nl]), context.temp_allocator)
			remove_range(&p.spart, 0, nl + 1)
			if line != "" do p.mode.stream(a, line)
		}
	}
	if st.exited {
		if len(p.spart) > 0 { p.mode.stream(a, strings.clone(string(p.spart[:]), context.temp_allocator)); clear(&p.spart) }
		p.sjob.running = false
		os.remove(p.sjob.out)
		delete(p.sjob.out)
		p.sjob.out = ""
		p.mode.stream(a, "k4:end")
	}
}

// ---------- a text field ----------

panel_type :: proc(p: ^Panel, text: string) { append(&p.input, ..transmute([]u8)text) }
panel_bs :: proc(p: ^Panel) -> bool {
	if len(p.input) == 0 do return false
	_, n := utf8.decode_last_rune(p.input[:])
	resize(&p.input, len(p.input) - n)
	return true
}
panel_clear :: proc(p: ^Panel) {
	for &b in p.input do b = 0 // a passphrase does not stay in memory
	clear(&p.input)
	p.reveal = false
}
panel_text :: proc(p: ^Panel) -> string { return string(p.input[:]) }
panel_masked :: proc(p: ^Panel) -> string {
	if p.reveal do return panel_text(p)
	return strings.repeat("•", utf8.rune_count(p.input[:]), context.temp_allocator)
}

// ---------- drawing ----------

// The window's ground: the theme's background, see-through as the terminal.
panel_ground :: proc(a: ^App, cv: ^Canvas) -> HUD {
	canvas_clear(cv)
	H := hud(a.theme)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(H.bg, a.bg_alpha))
	return H
}

// The head: the crumb in an accent block, a title, and the right-hand end (drawn by the caller
// from the returned x). big: the launcher-sized window's 56 px head.
panel_head :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, crumb, title: string, big: bool, right_w := 0) -> (hh, px, title_x: int) {
	p := a.pn
	px = (big ? 16 : 12) * S
	hh = (big ? 56 : 40) * S
	cf := big ? p.f12b : p.f11b
	cw := tw(cf, crumb) + (big ? 16 : 12) * S
	ch := (big ? 24 : 20) * S
	fill_rect(cv, px, (hh - ch) / 2, cw, ch, argb(H.acc, 0xff))
	text_in(cv, cf, crumb, px + (cw - tw(cf, crumb)) / 2, (hh - ch) / 2, ch, argb(H.bg, 0xff))
	title_x = px + cw + (big ? 12 : 10) * S
	if title != "" {
		tf := big ? p.f15 : p.f13b
		text_in(cv, tf, ellipsize(tf, title, cv.w - px - right_w - 10 * S - title_x), title_x, 0, hh, argb(H.fg, 0xff))
	}
	fill_rect(cv, 0, hh, cv.w, S, argb(H.line, 0xff))
	return
}

// A state at the right of the head: a small square (filled when on) and a label; boxed: inside
// an outline (the Passwords lock). Returns its left x.
panel_state :: proc(a: ^App, cv: ^Canvas, S, x_right, hh: int, label: string, c: u32, on, boxed: bool) -> int {
	p := a.pn
	lw := tw(p.f10b, label)
	w := lw + 6 * S + 5 * S + (boxed ? 16 * S : 0)
	x := x_right - w
	bh := 24 * S
	by := (hh - bh) / 2
	if boxed {
		if !on do fill_rect(cv, x, by, w, bh, argb(c, 0x12))
		rounded_rect(cv, x, by, w, bh, 0, 0, f32(S), argb(mix(a.theme.bg, c, on ? 0.4 : 0.55), 0xff))
	}
	dx := x + (boxed ? 8 * S : 0)
	if on do fill_rect(cv, dx, (hh - 6 * S) / 2, 6 * S, 6 * S, argb(c, 0xff))
	else do rounded_rect(cv, dx, (hh - 6 * S) / 2, 6 * S, 6 * S, 0, 0, f32(S), argb(c, 0xff))
	text_in(cv, p.f10b, label, dx + 6 * S + 5 * S, by, bh, argb(c, 0xff))
	return x
}

// The footer: the message, or the key hints; brand: "k4" at the right (the big windows).
panel_foot :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, hints: [][2]string, big: bool) -> (fy: int) {
	p := a.pn
	soft := mix(H.fg, H.bg, 0.2)
	fh := (big ? 40 : 30) * S
	fy = cv.h - fh
	px := (big ? 16 : 12) * S
	fill_rect(cv, 0, fy, cv.w, S, argb(H.line, 0xff))
	ff := big ? p.f11 : p.f10
	if p.toast != "" {
		text_in(cv, ff, ellipsize(ff, p.toast, cv.w - 2 * px - 30 * S), px, fy, fh, argb(p.tone != 0 ? p.tone : H.acc, 0xff))
	} else {
		kx := px
		for k in hints {
			kw := tw(ff, k[0]) + (big ? 10 : 8) * S
			if kx + kw + tw(ff, k[1]) > cv.w - px - 24 * S do break
			fill_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, argb(a.theme.fg, 0x0d))
			if big do rounded_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, ff, k[0], kx + (kw - tw(ff, k[0])) / 2, fy, fh, argb(big ? soft : H.fg, 0xff))
			kx += kw + 5 * S
			text_in(cv, ff, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(ff, k[1]) + (big ? 16 : 12) * S
		}
	}
	if big do text_in(cv, ff, "k4", cv.w - px - tw(ff, "k4"), fy, fh, argb(H.acc, 0xff))
	return
}

// A notice: a tinted box with a 3 px edge in its colour, a bold title and a wrapped body.
// Returns its height.
panel_notice :: proc(a: ^App, cv: ^Canvas, S, x, y, w: int, H: HUD, title, body: string, c: u32, draw := true) -> int {
	p := a.pn
	lines := wrap_text(p.f11, body, w - 24 * S)
	h := 10 * S + int(p.f12b.line_h) + 4 * S + len(lines) * 16 * S + 10 * S
	if body == "" do h = 10 * S + int(p.f12b.line_h) + 10 * S
	if !draw do return h
	fill_rect(cv, x, y, w, h, argb(c, 0x0d))
	rounded_rect(cv, x, y, w, h, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, x, y, 3 * S, h, argb(c, 0xff))
	yy := y + 10 * S
	text_in(cv, p.f12b, ellipsize(p.f12b, title, w - 24 * S), x + 12 * S, yy, int(p.f12b.line_h), argb(c, 0xff))
	yy += int(p.f12b.line_h) + 4 * S
	soft := mix(H.fg, H.bg, 0.2)
	for l in lines { text_in(cv, p.f11, l, x + 12 * S, yy, 16 * S, argb(soft, 0xff)); yy += 16 * S }
	return h
}

// An action button: the label and its key; kind 0 outlined, 1 accent, 2 red. Returns its width.
Btn_Kind :: enum { Plain, Prime, Hot }
panel_btn_w :: proc(a: ^App, S: int, label, key: string) -> int {
	p := a.pn
	return tw(p.f10b, label) + (key != "" ? 6 * S + tw(p.f10, key) : 0) + 16 * S
}
panel_btn :: proc(a: ^App, cv: ^Canvas, S, x, y, h: int, H: HUD, label, key: string, kind: Btn_Kind, hit: int) -> int {
	p := a.pn
	w := panel_btn_w(a, S, label, key)
	soft := mix(H.fg, H.bg, 0.2)
	bc, fg, kc := H.line, soft, H.dim
	switch kind {
	case .Prime: bc, fg, kc = H.acc, H.bg, H.bg
	case .Hot: bc, fg, kc = H.hot, H.bg, H.bg
	case .Plain:
	}
	if kind != .Plain do fill_rect(cv, x, y, w, h, argb(bc, 0xff))
	rounded_rect(cv, x, y, w, h, 0, 0, f32(S), argb(bc, 0xff))
	text_in(cv, p.f10b, label, x + 8 * S, y, h, argb(fg, 0xff))
	if key != "" do text_in(cv, p.f10, key, x + 8 * S + tw(p.f10b, label) + 6 * S, y, h, argb(kc, 0xff))
	if hit >= 0 do hit_add(a, x, y, w, h, .Chip, hit, 0)
	return w
}

// An outlined tag (USB, PRE, WIFI…): fixed width when w > 0, centred text. Returns its width.
panel_tag :: proc(cv: ^Canvas, f: ^Font, x, y, w, h, S: int, text: string, c: u32, fill: u32 = 0) -> int {
	ww := w > 0 ? w : tw(f, text) + 10 * S
	if fill != 0 do fill_rect(cv, x, y, ww, h, fill)
	rounded_rect(cv, x, y, ww, h, 0, 0, f32(S), argb(c, 0xff))
	text_in(cv, f, text, x + (ww - tw(f, text)) / 2, y, h, argb(c, 0xff))
	return ww
}

// A group heading: tracked capitals and a faint count.
panel_group :: proc(a: ^App, cv: ^Canvas, S, x, y, h: int, H: HUD, title, count: string) {
	p := a.pn
	spaced(cv, p.f10b, title, x, y, h, H.dim, S)
	if count != "" do text_in(cv, p.f10, count, x + spaced_w(p.f10b, title, S) + 8 * S, y, h, argb(H.faint, 0xff))
}

// A thin meter: the track and the filled part.
panel_meter :: proc(cv: ^Canvas, x, y, w, h: int, frac: f32, c, track: u32) {
	fill_rect(cv, x, y, w, h, argb(track, 0xff))
	fill_rect(cv, x, y, int(f32(w) * clamp(frac, 0, 1)), h, argb(c, 0xff))
}

// The count tag (the Kestrel design's chat badge): 11 px tall, at least as wide, 9 px bold
// digits in the surface colour, a 2 px ring of the surface around it; 99+ at most.
count_label :: proc(n: int) -> string { return n > 99 ? "99+" : fmt.tprint(n) }
count_tag_w :: proc(f: ^Font, n, S: int) -> int { return max(11 * S, tw(f, count_label(n)) + 6 * S) }
count_tag :: proc(cv: ^Canvas, f: ^Font, x, y, n, S: int, bg, fg, ring: u32) -> int {
	l := count_label(n)
	w := count_tag_w(f, n, S)
	h := 11 * S
	fill_rect(cv, x - 2 * S, y - 2 * S, w + 4 * S, h + 4 * S, argb(ring, 0xff))
	fill_rect(cv, x, y, w, h, argb(bg, 0xff))
	text_in(cv, f, l, x + (w - tw(f, l)) / 2, y, h, argb(fg, 0xff))
	return w
}

// A dump's footer line.
panel_dump_toast :: proc(p: ^Panel, sb: ^strings.Builder) {
	if p.toast != "" do fmt.sbprintfln(sb, "toast %s", p.toast)
}
