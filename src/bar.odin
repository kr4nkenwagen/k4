package k4

import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "logic"

// --bar: a status bar (Waybar's job) on one output. Modules come from stdin, one a line,
// tab-separated:
//   B <key>=<value>…                                height=26 (logical px)
//   M <id> <side> <kind> <arg> <interval> <tone> <left> <right> <middle> <up> <down>
//      side: left center right · kind: workspaces, window, clock (arg "fmt|alt fmt", strftime),
//      text (arg = the text), exec (arg = a shell command: interval > 0 runs it every that many
//      seconds and keeps its last line; 0 keeps it running and takes every line). A line is plain
//      text or Waybar's JSON {"text","tooltip","class"}; an empty text hides the module.
//      tone: the text colour (accent fg bright dim red orange yellow green cyan blue magenta);
//      a class of critical / warning / muted / off / charging overrides it.
//      left/right/middle/up/down: shell commands for the buttons and the wheel ("-" = none);
//      they get K4_BAR_X (the module's centre), K4_BAR_WIDTH and K4_BAR_OUTPUT, and the module
//      runs again right after.

Mod_Kind :: enum { Exec, Workspaces, Window, Clock, Text }

Module :: struct {
	id, arg, tone: string,
	side: int, // 0 left, 1 center, 2 right
	kind: Mod_Kind,
	interval: f64,
	on: [5]string, // left right middle up down
	text, tooltip, class: string,
	alt: bool,
	// exec
	pipe: ^os.File,
	proc_: os.Process,
	running: bool,
	buf: [dynamic]u8,
	next: time.Tick,
	// last drawn, logical px
	x, w: int,
}

Bar :: struct {
	mods: [dynamic]Module,
	height: int,
	output: string,
	ws: [dynamic]Ws,
	title: string,
	ipc_q, ipc_ev: linux.Fd,
	hover: int, // module under the pointer, -1
	f_text, f_bold: ^Font,
	width: int, // logical width of the output strip (from configure)
}

bar_setup :: proc(a: ^App, data: string) {
	b := new(Bar)
	a.bar = b
	b.height, b.hover = 26, -1
	b.ipc_q, b.ipc_ev = -1, -1
	text := data
	get :: proc(f: []string, i: int) -> string { return i < len(f) && f[i] != "-" ? f[i] : "" }
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		switch f[0] {
		case "B":
			for kv in f[1:] {
				if eq := strings.index_byte(kv, '='); eq > 0 && kv[:eq] == "height" do b.height, _ = strconv.parse_int(kv[eq + 1:])
			}
		case "M":
			if len(f) < 4 do continue
			m := Module{id = strings.clone(get(f, 1)), arg = strings.clone(get(f, 4)), tone = strings.clone(get(f, 6))}
			switch get(f, 2) { case "center": m.side = 1; case "right": m.side = 2 }
			switch get(f, 3) {
			case "workspaces": m.kind = .Workspaces
			case "window": m.kind = .Window
			case "clock": m.kind = .Clock
			case "text": m.kind = .Text; m.text = m.arg
			case: m.kind = .Exec
			}
			m.interval, _ = strconv.parse_f64(get(f, 5))
			for i in 0 ..< 5 do m.on[i] = strings.clone(get(f, 7 + i))
			append(&b.mods, m)
		}
	}
	b.f_text = font_sized(&a.font, 13)
	b.f_bold = b.f_text
	if bold, ok := bold_font(a, 13); ok do b.f_bold = bold
	append(&a.fonts, b.f_text, b.f_bold)
	a.width, a.height = 0, b.height
	// sway: workspaces and the focused window, live
	need_ipc := false
	for m in b.mods do if m.kind == .Workspaces || m.kind == .Window do need_ipc = true
	if need_ipc {
		if fd, ok := ipc_connect(); ok {
			b.ipc_q = fd
			if ev, ok2 := ipc_connect(); ok2 {
				if ipc_send(ev, IPC_SUBSCRIBE, `["workspace","window","output"]`) {
					if _, _, ok3 := ipc_recv(ev, context.temp_allocator); ok3 do b.ipc_ev = ev
				}
			}
		}
		bar_ipc_refresh(b)
	}
	if path := os.get_env("K4_BAR_WORKSPACES", context.temp_allocator); path != "" { // tests: workspaces from a file
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil do if list, ok := ws_parse(data); ok do b.ws = list
	}
	now := time.tick_now()
	for &m in b.mods do m.next = now
	bar_tick(a)
}

@(private)
bar_ipc_refresh :: proc(b: ^Bar) {
	if b.ipc_q < 0 do return
	if list, ok := ipc_workspaces(b.ipc_q); ok { b.ws = list }
	for m in b.mods do if m.kind == .Window { b.title = ipc_focused_title(b.ipc_q); break }
}

// ---------- modules that run commands ----------

@(private)
mod_start :: proc(m: ^Module) {
	if m.running do return
	r, w, err := os.pipe()
	if err != nil do return
	p, perr := os.process_start({command = {"sh", "-c", m.arg}, stdout = w})
	os.close(w)
	if perr != nil { os.close(r); return }
	m.pipe, m.proc_, m.running = r, p, true
	clear(&m.buf)
}

// A line of module output: plain text, or Waybar's JSON.
@(private)
mod_line :: proc(m: ^Module, line: string) {
	l := strings.trim_space(line)
	if strings.has_prefix(l, "{") {
		J :: struct { text, tooltip, class: string }
		j: J
		if json.unmarshal(transmute([]u8)l, &j, allocator = context.temp_allocator) == nil {
			m.text, m.tooltip, m.class = strings.clone(j.text), strings.clone(j.tooltip), strings.clone(j.class)
			return
		}
	}
	m.text, m.tooltip, m.class = strings.clone(l), "", ""
}

// Reads what a module printed; true when its text changed.
@(private)
mod_read :: proc(m: ^Module) -> bool {
	chunk: [4096]u8
	n, _ := os.read(m.pipe, chunk[:])
	before := m.text
	if n > 0 {
		append(&m.buf, ..chunk[:n])
		if m.interval == 0 { // continuous: every complete line counts
			for {
				nl := -1
				for c, i in m.buf do if c == '\n' { nl = i; break }
				if nl < 0 do break
				line := strings.clone(string(m.buf[:nl]), context.temp_allocator)
				remove_range(&m.buf, 0, nl + 1)
				if strings.trim_space(line) != "" do mod_line(m, line)
			}
		}
		return m.text != before
	}
	// finished: the last line wins
	os.close(m.pipe)
	_, _ = os.process_wait(m.proc_)
	m.running = false
	if m.interval > 0 {
		last := ""
		text := string(m.buf[:])
		for line in strings.split_lines_iterator(&text) do if strings.trim_space(line) != "" do last = line
		mod_line(m, last)
		m.next = time.tick_add(time.tick_now(), time.Duration(m.interval * f64(time.Second)))
	} else {
		m.next = time.tick_add(time.tick_now(), 3 * time.Second) // a follower died: start it again
	}
	return true
}

// Starts what is due and updates the clocks; returns ms until the next deadline.
bar_tick :: proc(a: ^App) -> int {
	b := a.bar
	now := time.tick_now()
	wait := 60_000
	for &m in b.mods {
		switch m.kind {
		case .Exec:
			if !m.running && time.tick_diff(m.next, now) >= 0 do mod_start(&m)
			if !m.running do wait = min(wait, max(int(time.duration_milliseconds(time.tick_diff(now, m.next))), 0) + 1)
		case .Clock:
			m.text = clock_text(m.alt ? second_field(m.arg) : first_field(m.arg))
			wait = min(wait, 1000 - int(time.to_unix_nanoseconds(time.now()) / 1_000_000 % 1000) + 5)
		case .Workspaces, .Window, .Text:
		}
	}
	return wait
}

@(private) first_field :: proc(s: string) -> string { if i := strings.index_byte(s, '|'); i >= 0 do return s[:i]; return s }
@(private) second_field :: proc(s: string) -> string { if i := strings.index_byte(s, '|'); i >= 0 do return s[i + 1:]; return s }

@(private)
clock_text :: proc(format: string) -> string {
	t := libc.time(nil)
	tm := libc.localtime(&t)
	buf: [128]u8
	f := strings.clone_to_cstring(format != "" ? format : "%H:%M", context.temp_allocator)
	n := libc.strftime(&buf[0], len(buf), f, tm)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

bar_poll_fds :: proc(b: ^Bar, out: ^[dynamic]linux.Poll_Fd) {
	for m in b.mods do if m.running do append(out, linux.Poll_Fd{fd = linux.Fd(os.fd(m.pipe)), events = {.IN}})
	if b.ipc_ev >= 0 do append(out, linux.Poll_Fd{fd = b.ipc_ev, events = {.IN}})
}

bar_on_readable :: proc(a: ^App, fd: linux.Fd) -> bool {
	b := a.bar
	if fd == b.ipc_ev {
		if _, _, ok := ipc_recv(b.ipc_ev, context.temp_allocator); !ok { linux.close(b.ipc_ev); b.ipc_ev = -1; return false }
		bar_ipc_refresh(b)
		return true
	}
	for &m in b.mods do if m.running && linux.Fd(os.fd(m.pipe)) == fd do return mod_read(&m)
	return false
}

// Dry runs: every module once.
bar_load_all :: proc(a: ^App) {
	for &m in a.bar.mods do if m.kind == .Exec {
		if m.interval == 0 { // one line from a follower is enough for a frame
			mod_start(&m)
			for m.running && m.text == "" do if !mod_read(&m) && !m.running do break
			if m.running { _ = os.process_kill(m.proc_); os.close(m.pipe); _, _ = os.process_wait(m.proc_); m.running = false }
		} else {
			mod_start(&m)
			for m.running do mod_read(&m)
		}
	}
}

// ---------- drawing ----------

@(private)
tone_of :: proc(t: logic.Theme, m: ^Module) -> u32 {
	switch m.class {
	case "critical", "urgent", "error": return t.red
	case "warning": return t.yellow
	case "muted", "off", "disabled", "disconnected", "stale": return t.fg_dim
	case "charging", "good": return t.green
	}
	switch m.tone {
	case "accent": return t.accent
	case "bright": return t.fg_bright
	case "dim": return t.fg_dim
	case "red": return t.red
	case "orange": return t.orange
	case "yellow": return t.yellow
	case "green": return t.green
	case "cyan": return t.cyan
	case "blue": return t.blue
	case "magenta": return t.magenta
	}
	return t.fg
}

bar_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	b := a.bar
	t := a.theme
	canvas_clear(cv)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(t.bg, 0xd9))
	fill_rect(cv, 0, cv.h - 2 * S, cv.w, 2 * S, argb(t.accent, 0xff)) // the accent rule along the bottom
	pad := 8 * S
	h := cv.h - 2 * S
	widths := make([]int, len(b.mods), context.temp_allocator)
	ws_w :: proc(b: ^Bar, S: int) -> int {
		w := 0
		for ws in b.ws do if b.output == "" || ws.output == b.output do w += tw(ws.focused ? b.f_bold : b.f_text, ws.name) + 2 * 8 * S + 4 * S
		return w
	}
	for &m, i in b.mods {
		switch m.kind {
		case .Workspaces: widths[i] = ws_w(b, S)
		case .Window: widths[i] = b.title != "" ? min(tw(b.f_text, b.title), 420 * S) + 2 * pad : 0
		case .Clock: widths[i] = m.text != "" ? tw(b.f_bold, m.text) + 2 * 10 * S : 0
		case .Exec, .Text: widths[i] = m.text != "" ? tw(b.f_text, m.text) + 2 * pad : 0
		}
	}
	// left from the start, right from the end, center around the middle
	place :: proc(a: ^App, cv: ^Canvas, S, i, x, w, h: int) {
		b := a.bar
		t := a.theme
		m := &b.mods[i]
		m.x, m.w = x / S, w / S
		if w == 0 do return
		hit_add(a, x, 0, w, cv.h, .Row, i, -1)
		switch m.kind {
		case .Workspaces:
			xx := x
			for ws, wi in b.ws {
				if b.output != "" && ws.output != b.output do continue
				f := ws.focused ? b.f_bold : b.f_text
				ww := tw(f, ws.name) + 2 * 8 * S
				c := ws.urgent ? t.red : (ws.focused ? t.accent : (ws.visible ? t.fg : t.fg_dim))
				if b.hover == i && !ws.focused do c = t.fg_bright
				hit_add(a, xx, 0, ww + 4 * S, cv.h, .Row, i, wi)
				text_in(cv, f, ws.name, xx + 8 * S + 2 * S, 0, h, argb(c, 0xff))
				xx += ww + 4 * S
			}
		case .Window:
			text_in(cv, b.f_text, ellipsize(b.f_text, b.title, w - 16 * S), x + 8 * S, 0, h, argb(b.hover == i ? t.fg_bright : t.fg, 0xff))
		case .Clock:
			text_in(cv, b.f_bold, m.text, x + 10 * S, 0, h, argb(t.fg_bright, 0xff))
		case .Exec, .Text:
			c := tone_of(t, m)
			if b.hover == i && m.class == "" do c = mix(c, t.fg_bright, 0.35)
			text_in(cv, b.f_text, m.text, x + 8 * S, 0, h, argb(c, 0xff))
		}
	}
	x := 6 * S
	for &m, i in b.mods do if m.side == 0 { place(a, cv, S, i, x, widths[i], h); x += widths[i] }
	x = cv.w - 6 * S
	#reverse for &m, i in b.mods do if m.side == 2 { x -= widths[i]; place(a, cv, S, i, x, widths[i], h) }
	total := 0
	for &m, i in b.mods do if m.side == 1 do total += widths[i]
	x = (cv.w - total) / 2
	for &m, i in b.mods do if m.side == 1 { place(a, cv, S, i, x, widths[i], h); x += widths[i] }
}

// ---------- the pointer ----------

bar_pointer_move :: proc(a: ^App, x, y: int) -> bool {
	b := a.bar
	h, ok := hit_at(a, x, y)
	nh := ok ? h.a : -1
	if nh == b.hover do return false
	b.hover = nh
	return true
}

// button: 1 left, 3 right, 2 middle; scroll: n steps (negative = up)
bar_pointer_click :: proc(a: ^App, x, y, button: int) -> bool {
	b := a.bar
	h := hit_at(a, x, y) or_return
	m := &b.mods[h.a]
	if m.kind == .Workspaces && button == 1 && h.b >= 0 && h.b < len(b.ws) {
		if b.ipc_q >= 0 do ipc_query(b.ipc_q, IPC_RUN_COMMAND, fmt.tprintf("workspace \"%s\"", b.ws[h.b].name), context.temp_allocator)
		bar_ipc_refresh(b)
		return true
	}
	if m.kind == .Clock && button == 3 && m.on[1] == "" { m.alt = !m.alt; bar_tick(a); return true }
	cmd := ""
	switch button { case 1: cmd = m.on[0]; case 3: cmd = m.on[1]; case 2: cmd = m.on[2] }
	if cmd == "" do return false
	bar_run(a, m, cmd)
	return true
}

bar_pointer_scroll :: proc(a: ^App, n: int) -> bool {
	b := a.bar
	if b.hover < 0 || b.hover >= len(b.mods) do return false
	m := &b.mods[b.hover]
	if m.kind == .Workspaces && b.ipc_q >= 0 {
		ipc_query(b.ipc_q, IPC_RUN_COMMAND, n > 0 ? "workspace next_on_output" : "workspace prev_on_output", context.temp_allocator)
		bar_ipc_refresh(b)
		return true
	}
	cmd := n < 0 ? m.on[3] : m.on[4]
	if cmd == "" do return false
	bar_run(a, m, cmd)
	return true
}

// A click's command, detached, told where the module is; the module runs again soon after.
@(private)
bar_run :: proc(a: ^App, m: ^Module, cmd: string) {
	b := a.bar
	env := fmt.tprintf("K4_BAR_X=%d K4_BAR_WIDTH=%d K4_BAR_OUTPUT=%s", m.x + m.w / 2, b.width, b.output != "" ? b.output : "-")
	full := strings.clone_to_cstring(fmt.tprintf("%s setsid -f sh -c %s >/dev/null 2>&1 </dev/null", env, sh_quote(cmd)), context.temp_allocator)
	libc.system(full)
	if m.kind == .Exec && m.interval > 0 && !m.running do m.next = time.tick_add(time.tick_now(), 250 * time.Millisecond)
}

// --dump for a bar: each module's text, left to right per side.
bar_dump :: proc(a: ^App) -> string {
	b := a.bar
	sb := strings.builder_make(context.temp_allocator)
	sides := [3]string{"left", "center", "right"}
	for side in 0 ..< 3 {
		fmt.sbprintf(&sb, "%s:", sides[side])
		for m in b.mods {
			if m.side != side do continue
			switch m.kind {
			case .Workspaces:
				parts := make([dynamic]string, 0, 8, context.temp_allocator)
				for ws in b.ws do if b.output == "" || ws.output == b.output do append(&parts, fmt.tprintf("%s%s", ws.name, ws.focused ? "*" : ""))
				fmt.sbprintf(&sb, " [%s]", strings.join(parts[:], " ", context.temp_allocator))
			case .Window: if b.title != "" do fmt.sbprintf(&sb, " [%s]", b.title)
			case .Clock, .Exec, .Text: if m.text != "" do fmt.sbprintf(&sb, " [%s%s]", m.text, m.class != "" ? fmt.tprintf(" (%s)", m.class) : "")
			}
		}
		fmt.sbprintln(&sb)
	}
	return strings.to_string(sb)
}

_ :: c
