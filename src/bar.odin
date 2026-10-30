package k4

import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:slice"
import "core:time"
import "logic"

// --bar: a status bar (Waybar's job) on one output, drawn as the design's strip: 26 px with a
// 2 px accent rule, modules text-coloured on the theme background; only hover (selection),
// open (accent block, while its click command runs: a popup) and alarm (red block) fill.
// Modules come from stdin, one a line, tab-separated:
//   B <key>=<value>…    height=26 · position=top|bottom · transparent=1 (Ghostty's background-opacity, else 55%)
//                       · icons=1 (each module its icon alone, with its count tag; text, boxes and levels go,
//                       the window title too, the clock keeps its time; the tooltips keep the info)
//   M <id> <side> <kind> <arg> <interval> <tone> <left> <right> <middle> <up> <down> [flags]
//      side: left center right · kind: workspaces, window, clock, text / icon (arg), exec
//      (arg = a shell command: interval > 0 runs it every that many seconds and keeps its last
//      line; 0 keeps it running and takes every line). Clock arg: "time;date|alt time;alt date"
//      (strftime; the time bold, the date dim); the wheel (or a right click without a command) switches, middle shows UTC for 3 s.
//      An exec line is plain text or Waybar's JSON {"text","tooltip","class","percentage"}
//      plus k4's "icon", "icon_tone", "text_tone", "text2" (dim, after the text), "text2_tone",
//      "level" (a 4 px level bar, 0–100), "battery" (the battery glyph, 0–100) and "badge"
//      (a count tag over the content's end, 99+ at most; "badge_tone": red when the app needs
//      you, dnd quiet, else the accent), "pill" (the same tag with a short text: "?", "!") and
//      "outline" (true: an accent ring round the module, the visible-workspace look, for news),
//      "box" (a short label in an outlined box after the icon: a bus line; "box_tone", default the
//      accent) and "text2_bold"; "shape" (a drawn line icon in place of the glyph: shield-on,
//      shield-off, shield-broken, shield-unsafe; shapes.odin), "wash" (a faint tint of that tone
//      behind it: a click's feedback) and "minw" (the least width in px: a countdown that must not jitter).
//      An empty text, icon and battery hide the module. class critical/urgent: a red block;
//      warning: yellow; dim/muted/off/disconnected/stale/empty: the dim colour.
//      tone: the icon's colour unless the line names one (accent fg dim red orange yellow
//      green cyan blue magenta). left/right/middle/up/down: shell commands for the buttons
//      and the wheel ("-" = none); they get K4_BAR_X (the module's centre), K4_BAR_MX and
//      K4_BAR_MW (its left edge and width), K4_BAR_SIDE, K4_BAR_WIDTH, K4_BAR_OUTPUT,
//      K4_BAR_POS (top|bottom) and K4_BAR_H, and the module runs again right after. While a
//      click's command runs the module is drawn open, so a popup's module stays an accent block.
//      flags (k=v;…): px=N (inner padding, default 7), maxw=N / maxw2=N (text caps),
//      compact (text hidden below 1440 px), slim (only the first text hidden below 1440 px), wide (the
//      whole module hidden below 1440 px), flash (the wheel shows the percentage for 1.2 s),
//      tip=TEXT (a tooltip for modules that print none), next=PATH (the clock: a meeting from
//      that TSV of today's "start end title video" replaces the date: "Review in 8 min" in
//      yellow 10 min before, "Review · j join" in the accent while it runs).
//      group=NAME (its kind: status, apps, info, network, system).
//   G <id> <glyph> <label> <pin> <command>   a group (the KGroups board). With B groups=1 its members fold
//      into one chip: the group's glyph (Network: the network module's) and at most one value: the
//      most urgent member's (red fill for critical, red for needs-you, yellow for degraded, accent for
//      something running), else the pinned member's (<pin>, or the pins file's: K4_BAR_PINS, lines
//      "group member"), Apps the unread sum as a pill, Status how many show; System adds a red mic when
//      muted and a keyboard layout that isn't the default. Its left click runs <command> (the drawer).
//      The bar writes what each module shows to $XDG_RUNTIME_DIR/k4-bar-<output>.tsv for the drawer:
//      id group icon shape text text2 icon_tone text_tone class badge badge_tone pill tooltip left.
// Hovering a module for 500 ms shows its tooltip under it (one line): the surface grows for it,
// its input region and exclusive zone stay the strip.

Mod_Kind :: enum { Exec, Workspaces, Window, Clock, Text }

Module :: struct {
	id, arg, tone: string,
	side: int, // 0 left, 1 center, 2 right
	kind: Mod_Kind,
	interval: f64,
	on: [5]string, // left right middle up down
	px, maxw, maxw2: int, // flags
	compact, slim, wide, flash: bool,
	tip: string, // flags' tip=: the tooltip when the module prints none
	next_file: string, // clock flag next=PATH: today's meetings (start end title video, TSV)
	timers_file: string, // clock flag timers=PATH: k4-clock's timers, stopwatch, next alarm (bar.tsv)
	group: string,       // flag group=NAME: the kind it is (a group's chip: the group it stands for)
	head: bool,          // a group's chip (from a G line)
	label, pin: string,  // a group's name and its pinned member (the quiet value)
	last_line: string, // the line it shows: the same one again changes nothing (no redraw)
	// what it shows
	text, tooltip, class, icon, icon_tone, text_tone, text2, text2_tone: string,
	level, battery, pct: int, // -1: none
	badge: int, // the count tag; 0 or less: none
	badge_tone: string, // red (the app needs you), dnd (quiet), else the accent
	pill: string, // the tag with a short text instead of a count
	outline: bool, // an accent ring round the module
	box, box_tone: string, // a short label in an outlined box after the icon (a bus line)
	text2_bold: bool,
	shape: Shape, // a drawn icon in place of the glyph
	wash: string, // a faint tint behind it (a tone)
	minw: int,    // the least width, logical px
	lines: int, // lines read so far
	alt: bool,
	utc_until, flash_until: time.Tick,
	// a click's command: the module is open while it runs
	click: os.Process,
	clicking: bool,
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
	redraw: bool, // bar_tick saw something visible change (the clock, a tooltip, a finished click…)
	mods: [dynamic]Module,
	height: int,
	bottom, transparent: bool,
	icons_only: bool, // B icons=1: each module its icon (and its count tag) alone; the info in the tooltip
	grouped: bool,    // B groups=1: each group (G lines) folds into one chip
	pins: map[string]string, // group → member whose value the quiet chip shows (the pins file)
	pins_mtime: i64,
	output: string,
	ws: [dynamic]Ws,
	title: string,
	ipc_q, ipc_ev: linux.Fd,
	hypr: bool, // Hyprland: requests per call, events from socket2 (ipc_ev)
	ev_buf: [dynamic]u8,
	hover, hover_ws: int, // module and workspace under the pointer, -1
	hover_at: time.Tick, // when the pointer came to that module
	tip_off: int, // the module last clicked: no tooltip on it until the pointer leaves it
	tip: int, // module whose tooltip is up, -1
	want_h: int, // surface height: the strip, plus room for a tooltip or the preview while up
	want_region: [4]int, // the preview card's rect (logical; zero: none), for the input region
	prev: Prev, // the workspace preview (wspreview.odin)
	ws_x: [dynamic]int, // each workspace cell's left edge as last drawn (logical)
	f_text, f_bold, f_badge, f_box: ^Font,
	width: int, // logical width of the output strip (from configure)
}

// SIGTERM (a new bar replacing this one, k4-bar stop) or SIGINT: the module commands are told
// first, so their event pipelines go with them instead of outliving the bar.
@(private = "file") bar_term_flag: libc.sig_atomic_t
@(private = "file") bar_on_term :: proc "c" (sig: c.int) { bar_term_flag = 1 }

// Called after every wakeup: true once a SIGTERM came, the modules signalled.
bar_terminated :: proc(a: ^App) -> bool {
	if bar_term_flag == 0 do return false
	for &m in a.bar.mods do if m.running do linux.kill(linux.Pid(m.proc_.pid), .SIGTERM)
	return true
}

bar_setup :: proc(a: ^App, data: string) {
	if a.opts.dry_run == "" && !a.opts.dump {
		libc.signal(libc.SIGTERM, bar_on_term)
		libc.signal(libc.SIGINT, bar_on_term)
	}
	b := new(Bar)
	a.bar = b
	b.height, b.hover, b.hover_ws, b.tip, b.tip_off = 26, -1, -1, -1, -1
	b.prev.ws, b.prev.cand, b.prev.row = -1, -1, -1
	b.ipc_q, b.ipc_ev = -1, -1
	text := data
	get :: proc(f: []string, i: int) -> string { return i < len(f) && f[i] != "-" ? f[i] : "" }
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		switch f[0] {
		case "B":
			for kv in f[1:] {
				eq := strings.index_byte(kv, '=')
				if eq <= 0 do continue
				switch kv[:eq] {
				case "height": b.height, _ = strconv.parse_int(kv[eq + 1:])
				case "position": b.bottom = kv[eq + 1:] == "bottom"
				case "transparent": b.transparent = kv[eq + 1:] == "1" || kv[eq + 1:] == "true"
				case "icons": b.icons_only = kv[eq + 1:] == "1" || kv[eq + 1:] == "true"
				case "groups": b.grouped = kv[eq + 1:] == "1" || kv[eq + 1:] == "true"
				}
			}
		case "G": // a group: its chip stands where its first member is (placed once the modules are read)
			if len(f) < 3 do continue
			g := Module{id = strings.clone(fmt.tprintf("group:%s", get(f, 1))), group = strings.clone(get(f, 1)), icon = strings.clone(get(f, 2)), label = strings.clone(get(f, 3)),
				pin = strings.clone(get(f, 4)), head = true, kind = .Text, px = 7, level = -1, battery = -1, pct = -1}
			g.on[0] = strings.clone(get(f, 5))
			append(&b.mods, g)
		case "M":
			if len(f) < 4 do continue
			m := Module{id = strings.clone(get(f, 1)), arg = strings.clone(get(f, 4)), tone = strings.clone(get(f, 6)), px = 7, level = -1, battery = -1, pct = -1}
			switch get(f, 2) { case "center": m.side = 1; case "right": m.side = 2 }
			switch get(f, 3) {
			case "workspaces": m.kind = .Workspaces
			case "window": m.kind = .Window
			case "clock": m.kind = .Clock
			case "text": m.kind = .Text; m.text = m.arg
			case "icon": m.kind = .Text; m.icon = m.arg // a glyph in the tone colour (the menu button)
			case: m.kind = .Exec
			}
			m.interval, _ = strconv.parse_f64(get(f, 5))
			for i in 0 ..< 5 do m.on[i] = strings.clone(get(f, 7 + i))
			for fl in strings.split(get(f, 12), ";", context.temp_allocator) {
				k, _, v := strings.partition(fl, "=")
				n, _ := strconv.parse_int(v)
				switch k {
				case "px": m.px = n
				case "maxw": m.maxw = n
				case "maxw2": m.maxw2 = n
				case "compact": m.compact = true
				case "slim": m.slim = true
				case "wide": m.wide = true
				case "flash": m.flash = true
				case "tip": m.tip = strings.clone(v)
				case "group": m.group = strings.clone(v)
				case "next":
					p := v
					if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
					m.next_file = strings.clone(p)
				case "timers":
					p := v
					if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
					m.timers_file = strings.clone(p)
				}
			}
			append(&b.mods, m)
		}
	}
	{ // each group's chip just before its first member, on that member's side; a group without members goes
		heads := make([dynamic]Module, 0, 8, context.temp_allocator)
		rest := make([dynamic]Module, 0, len(b.mods), context.temp_allocator)
		for m in b.mods { if m.head do append(&heads, m); else do append(&rest, m) }
		clear(&b.mods)
		placed := make(map[string]bool, 8, context.temp_allocator)
		for m in rest {
			if m.group != "" && !placed[m.group] do for h in heads do if h.group == m.group { hh := h; hh.side = m.side; append(&b.mods, hh); placed[m.group] = true; break }
			append(&b.mods, m)
		}
	}
	b.f_text = font_sized(&a.font, 12)
	b.f_bold = b.f_text
	if bold, ok := bold_font(a, 12); ok do b.f_bold = bold
	b.f_badge = font_sized(&a.font, 9)
	if bold, ok := bold_font(a, 9); ok do b.f_badge = bold
	b.f_box = font_sized(&a.font, 11)
	if bold, ok := bold_font(a, 11); ok do b.f_box = bold
	append(&a.fonts, b.f_text, b.f_bold)
	a.width, a.height = 0, b.height
	b.want_h = b.height
	// sway: workspaces and the focused window, live
	need_ipc := false
	for m in b.mods do if m.kind == .Workspaces || m.kind == .Window do need_ipc = true
	if need_ipc && hypr_dir() != "" {
		b.hypr = true
		if ev, ok := hypr_events(); ok do b.ipc_ev = ev
		bar_ipc_refresh(b)
	} else if need_ipc {
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
	set_ws :: proc(b: ^Bar, list: [dynamic]Ws) {
		for w in b.ws { delete(w.name); delete(w.output) }
		delete(b.ws)
		b.ws = list
	}
	set_title :: proc(b: ^Bar, t: string) { if len(b.title) > 0 do delete(b.title); b.title = t } // non-empty titles are clones
	if b.hypr {
		if list, ok := hypr_workspaces(); ok do set_ws(b, list)
		for m in b.mods do if m.kind == .Window { set_title(b, hypr_title()); break }
		return
	}
	if b.ipc_q < 0 do return
	if list, ok := ipc_workspaces(b.ipc_q); ok do set_ws(b, list)
	for m in b.mods do if m.kind == .Window { set_title(b, ipc_focused_title(b.ipc_q)); break }
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

// A line of module output: plain text, or Waybar's JSON with k4's fields.
@(private)
mod_line :: proc(m: ^Module, line: string) {
	for p in ([]^string{&m.text, &m.tooltip, &m.class, &m.icon, &m.icon_tone, &m.text_tone, &m.text2, &m.text2_tone, &m.badge_tone, &m.pill, &m.box, &m.box_tone, &m.wash}) {
		if len(p^) > 0 do delete(p^)
		p^ = ""
	}
	m.level, m.battery, m.pct, m.badge, m.outline, m.text2_bold, m.shape, m.minw = -1, -1, -1, 0, false, false, .None, 0
	m.lines += 1
	l := strings.trim_space(line)
	if strings.has_prefix(l, "{") {
		J :: struct { text, tooltip, class, icon, icon_tone, text_tone, text2, text2_tone, badge_tone, pill, box, box_tone, shape, wash: string, percentage, level, battery, badge, minw: int, outline, text2_bold: bool }
		j := J{percentage = -1, level = -1, battery = -1}
		if json.unmarshal(transmute([]u8)l, &j, allocator = context.temp_allocator) == nil {
			m.text, m.tooltip, m.class = strings.clone(j.text), strings.clone(j.tooltip), strings.clone(j.class)
			m.icon, m.icon_tone, m.text_tone = strings.clone(j.icon), strings.clone(j.icon_tone), strings.clone(j.text_tone)
			m.text2, m.text2_tone = strings.clone(j.text2), strings.clone(j.text2_tone)
			m.level, m.battery, m.pct = j.level, j.battery, j.percentage
			m.badge, m.badge_tone = j.badge, strings.clone(j.badge_tone)
			m.pill, m.outline = strings.clone(j.pill), j.outline
			m.box, m.box_tone, m.text2_bold = strings.clone(j.box), strings.clone(j.box_tone), j.text2_bold
			m.shape, m.wash, m.minw = shape_of(j.shape), strings.clone(j.wash), j.minw
			if m.shape != .None && m.icon == "" do m.icon = strings.clone("◇") // (shown: the shape draws over the glyph's place)
			return
		}
	}
	m.text = strings.clone(l)
}

// Reads what a module printed; true when its text changed.
@(private)
mod_read :: proc(m: ^Module) -> bool {
	chunk: [4096]u8
	n, _ := os.read(m.pipe, chunk[:])
	changed := false
	if n > 0 {
		append(&m.buf, ..chunk[:n])
		if m.interval == 0 { // continuous: every complete line counts
			for {
				nl := -1
				for c, i in m.buf do if c == '\n' { nl = i; break }
				if nl < 0 do break
				line := strings.clone(string(m.buf[:nl]), context.temp_allocator)
				remove_range(&m.buf, 0, nl + 1)
				if strings.trim_space(line) != "" do changed |= mod_show(m, line)
			}
		}
		return changed
	}
	// finished: the last line wins
	os.close(m.pipe)
	_, _ = os.process_wait(m.proc_)
	m.running = false
	if m.interval > 0 {
		last := ""
		text := string(m.buf[:])
		for line in strings.split_lines_iterator(&text) do if strings.trim_space(line) != "" do last = line
		changed = mod_show(m, last)
		m.next = time.tick_add(time.tick_now(), time.Duration(m.interval * f64(time.Second)))
		return changed
	}
	m.next = time.tick_add(time.tick_now(), 3 * time.Second) // a follower died: start it again
	return true
}

@(private = "file") snap_dirty: bool // (mod_show has no bar at hand: bar_tick writes the snapshot)

// A module's new line: parsed and shown unless it is the one already shown (most runs of a
// polled module print the same line; each redraw of a wide bar costs).
@(private)
mod_show :: proc(m: ^Module, line: string) -> bool {
	if line == m.last_line && m.lines > 0 do return false
	delete(m.last_line)
	m.last_line = strings.clone(line)
	mod_line(m, line)
	snap_dirty = true
	return true
}

// Starts what is due, updates the clocks and notices finished clicks; returns ms until the
// next deadline.
bar_tick :: proc(a: ^App) -> int {
	b := a.bar
	bar_snapshot(b) // (groups on: what the drawer lists)
	now := time.tick_now()
	wait := 60_000
	until :: proc(now, t: time.Tick) -> int { return max(int(time.duration_milliseconds(time.tick_diff(now, t))), 0) + 1 }
	// the tooltip: 500 ms after the pointer settles on a module that has one
	old_tip, old_h, old_region := b.tip, b.want_h, b.want_region
	defer if b.tip != old_tip || b.want_h != old_h || b.want_region != old_region || b.prev.ws >= 0 do b.redraw = true
	b.tip = -1
	if b.hover >= 0 && b.hover < len(b.mods) && b.hover != b.tip_off && mod_tooltip(b, b.hover) != "" {
		at := time.tick_add(b.hover_at, 500 * time.Millisecond)
		if time.tick_diff(now, at) <= 0 do b.tip = b.hover
		else do wait = min(wait, until(now, at))
	}
	if pw := prev_tick(a); pw >= 0 do wait = min(wait, pw)
	if b.prev.ws >= 0 do b.tip = -1 // never two at once
	b.want_h = b.tip >= 0 ? b.height + TIP_ROOM : b.height
	b.want_region = {}
	if b.prev.ws >= 0 {
		b.want_h = b.height + 4 + prev_h(&b.prev)
		px := 0
		if b.prev.ws < len(b.ws_x) do px = clamp(b.ws_x[b.prev.ws], 8, max(b.width - 8 - PREV_W, 8))
		b.want_region = {px, b.bottom ? 0 : b.height + 4, PREV_W, prev_h(&b.prev)}
	}
	for &m in b.mods {
		if m.clicking {
			if st, err := os.process_wait(m.click, 0); err == nil && st.exited { m.clicking = false; b.redraw = true }
			else do wait = min(wait, 100)
		}
		if m.flash_until != {} {
			if time.tick_diff(now, m.flash_until) > 0 do wait = min(wait, until(now, m.flash_until))
			else { m.flash_until = {}; b.redraw = true } // the percentage goes back to the icon
		}
		switch m.kind {
		case .Exec:
			if !m.running && time.tick_diff(m.next, now) >= 0 do mod_start(&m)
			if !m.running do wait = min(wait, until(now, m.next))
		case .Clock:
			utc := m.utc_until != {} && time.tick_diff(now, m.utc_until) > 0
			if utc do wait = min(wait, until(now, m.utc_until))
			f := m.alt ? second_field(m.arg) : first_field(m.arg)
			tf, _, df := strings.partition(f, ";")
			if tf == "" do tf = "%H:%M"
			t := clock_text(tf, utc)
			d := utc ? "UTC" : clock_text(df, false)
			tone := utc ? "accent" : ""
			if !utc {
				// what replaces the date: something ringing, a timer, the stopwatch, a meeting, tonight's alarm
				cd, ct, cw := clock_timers(m.timers_file)
				md, mt, mok := clock_meeting(m.next_file)
				switch {
				case cw >= 3: d, tone = cd, ct
				case mok: d, tone = md, mt
				case cw > 0: d, tone = cd, ct
				}
			}
			// m.text outlives this frame's temp allocator: keep heap copies
			if t != m.text { if len(m.text) > 0 do delete(m.text); m.text = strings.clone(t); b.redraw = true }
			if d != m.text2 { if len(m.text2) > 0 do delete(m.text2); m.text2 = strings.clone(d); b.redraw = true }
			if tone != m.text2_tone {
				b.redraw = true
				if len(m.text2_tone) > 0 do delete(m.text2_tone)
				m.text2_tone = strings.clone(tone)
			}
			wait = min(wait, 1000 - int(time.to_unix_nanoseconds(time.now()) / 1_000_000 % 1000) + 5)
		case .Workspaces, .Window, .Text:
		}
	}
	return wait
}

// The meeting the clock shows instead of the date: one running now, or one starting within
// 10 minutes.
@(private)
clock_meeting :: proc(path: string) -> (text, tone: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	now := i64(libc.time(nil))
	text_ := string(data)
	for line in strings.split_lines_iterator(&text_) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 do continue
		st, _ := strconv.parse_i64(f[0])
		en, _ := strconv.parse_i64(f[1])
		video := len(f) > 3 && f[3] != ""
		if st <= now && now < en do return fmt.tprintf("%s · %s", f[2], video ? "j join" : "now"), "accent", true
		if now < st && st - now <= 600 do return fmt.tprintf("%s in %d min", f[2], (st - now + 59) / 60), "yellow", true
	}
	return
}

// The clock's timers file (k4-clock's bar.tsv): "⏰ Call the garage" in red while an alarm
// rings, "⏱ Tea · done" in yellow, "⏱ 1:12 Tea +1" (the soonest running timer, the accent),
// "◷ 04:52" (the stopwatch), after 21:00 "Fri 30 Oct · ⏰ 06:45" (the next alarm within 12 h).
// weight: 3 ringing or running (before a meeting), 1 the alarm tonight (after one), 0 nothing.
@(private)
clock_timers :: proc(path: string) -> (text, tone: string, weight: int) {
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	now := f64(time.to_unix_nanoseconds(time.now())) / 1e9
	timer, watch, alarm: string
	text_ := string(data)
	for line in strings.split_lines_iterator(&text_) {
		f := strings.split(line, "\t", context.temp_allocator)
		switch f[0] {
		case "ring":
			if len(f) < 3 do continue
			if f[1] == "alarm" do return fmt.tprintf("⏰ %s", f[2]), "red", 3
			return fmt.tprintf("⏱ %s · done", f[2] != "" ? f[2] : "Timer"), "yellow", 3
		case "timer":
			if len(f) < 4 || timer != "" do continue
			end, _ := strconv.parse_f64(f[1])
			n, _ := strconv.parse_int(f[3])
			timer = fmt.tprintf("⏱ %s%s%s", clock_dur(end - now), f[2] != "" ? fmt.tprintf(" %s", f[2]) : "", n > 0 ? fmt.tprintf(" +%d", n) : "")
		case "watch":
			if len(f) < 3 do continue
			t0, _ := strconv.parse_f64(f[1])
			base, _ := strconv.parse_f64(f[2])
			el := int(base + now - t0)
			watch = el >= 3600 ? fmt.tprintf("◷ %d:%02d:%02d", el / 3600, el / 60 % 60, el % 60) : fmt.tprintf("◷ %02d:%02d", el / 60, el % 60)
		case "alarm":
			if len(f) < 3 do continue
			at, _ := strconv.parse_f64(f[1])
			if at - now > 12 * 3600 do continue
			t := libc.time(nil)
			if libc.localtime(&t).tm_hour >= 21 do alarm = fmt.tprintf("%s · ⏰ %s", clock_text("%a %d %b"), f[2])
		}
	}
	if timer != "" do return timer, "accent", 3
	if watch != "" do return watch, "", 3
	if alarm != "" do return alarm, "", 1
	return
}

@(private) first_field :: proc(s: string) -> string { if i := strings.index_byte(s, '|'); i >= 0 do return s[:i]; return s }
@(private) second_field :: proc(s: string) -> string { if i := strings.index_byte(s, '|'); i >= 0 do return s[i + 1:]; return s }

@(private)
clock_text :: proc(format: string, utc := false) -> string {
	if format == "" do return ""
	t := libc.time(nil)
	tm := utc ? libc.gmtime(&t) : libc.localtime(&t)
	buf: [128]u8
	f := strings.clone_to_cstring(format, context.temp_allocator)
	n := libc.strftime(&buf[0], len(buf), f, tm)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

bar_poll_fds :: proc(b: ^Bar, out: ^[dynamic]linux.Poll_Fd) {
	for m in b.mods do if m.running do append(out, linux.Poll_Fd{fd = linux.Fd(os.fd(m.pipe)), events = {.IN}})
	if b.ipc_ev >= 0 do append(out, linux.Poll_Fd{fd = b.ipc_ev, events = {.IN}})
}

bar_on_readable :: proc(a: ^App, fd: linux.Fd) -> bool {
	b := a.bar
	if fd == b.ipc_ev && b.hypr {
		// lines "event>>data": refresh on what changes workspaces or the focused window
		chunk: [4096]u8
		n, err := linux.read(b.ipc_ev, chunk[:])
		if err != .NONE || n <= 0 { linux.close(b.ipc_ev); b.ipc_ev = -1; return false }
		append(&b.ev_buf, ..chunk[:n])
		changed := false
		for {
			nl := -1
			for c, i in b.ev_buf do if c == '\n' { nl = i; break }
			if nl < 0 do break
			line := string(b.ev_buf[:nl])
			for ev in ([]string{"workspace", "focusedmon", "activewindow", "createworkspace", "destroyworkspace", "moveworkspace", "openwindow", "closewindow", "movewindow", "monitoradded", "monitorremoved", "renameworkspace"}) {
				if strings.has_prefix(line, ev) && strings.has_prefix(line[len(ev):], ">>") { changed = true; break }
			}
			remove_range(&b.ev_buf, 0, nl + 1)
		}
		if changed do bar_ipc_refresh(b)
		return changed
	}
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
			for m.running && m.lines == 0 do if !mod_read(&m) && !m.running do break
			if m.running { _ = os.process_kill(m.proc_); os.close(m.pipe); _, _ = os.process_wait(m.proc_); m.running = false }
		} else {
			mod_start(&m)
			for m.running do mod_read(&m)
		}
	}
}

// ---------- drawing ----------

@(private)
token :: proc(t: logic.Theme, name: string, def: u32) -> u32 {
	switch name {
	case "accent": return t.accent
	case "fg": return t.fg
	case "bright": return t.fg_bright
	case "dim": return t.fg_dim
	case "red": return t.red
	case "orange": return t.orange
	case "yellow": return t.yellow
	case "green": return t.green
	case "cyan": return t.cyan
	case "blue": return t.blue
	case "magenta": return t.magenta
	case "wow": return 0xE8A33D // World of Warcraft's orange (its raid nights calendar)
	}
	return def
}

Mod_State :: enum { Normal, Dim, Warn, Hover, Open, Crit }

@(private)
mod_state :: proc(b: ^Bar, i: int) -> Mod_State {
	m := &b.mods[i]
	if m.clicking do return .Open
	switch m.class {
	case "critical", "urgent", "error": return .Crit
	}
	if b.hover == i do return .Hover
	switch m.class {
	case "warning": return .Warn
	case "dim", "muted", "off", "disabled", "disconnected", "stale", "empty": return .Dim
	}
	return .Normal
}

// What a module draws: its parts and their colours (the design's chip: icon · battery · level ·
// text · text2, 6 px apart, px inside).
Chip :: struct {
	icon, text, text2: string,
	battery, level: int,
	badge: int, // the count tag over the end of the content (the Kestrel design's chat badge)
	pill: string, // the tag with a short text
	outline: bool,
	box: string, box_c: u32, bold2: bool,
	shape: Shape, minw: int,
	badge_bg, badge_fg: u32,
	bold: bool,
	bg, fg, icon_c, text_c, text2_c, line_c: u32,
	filled: bool,
	px, maxw, maxw2: int,
}

@(private)
mod_chip :: proc(a: ^App, i: int, S: int, narrow: bool) -> (c: Chip, shown: bool) {
	b := a.bar
	t := a.theme
	m := &b.mods[i]
	st := mod_state(b, i)
	c = {icon = m.icon, text = m.text, text2 = m.text2, battery = m.battery, level = m.level, badge = m.badge, pill = m.pill, outline = m.outline, box = m.box, bold2 = m.text2_bold, px = m.px * S, maxw = m.maxw * S, maxw2 = m.maxw2 * S, shape = m.shape, minw = m.minw * S}
	if m.kind == .Clock do c.bold = true
	flashing := m.flash && m.flash_until != {} && time.tick_diff(time.tick_now(), m.flash_until) > 0 && m.pct >= 0
	if narrow && m.compact do c.text, c.text2 = "", ""
	if narrow && m.slim do c.text = ""
	if narrow && m.wide do return c, false
	if b.icons_only { // icons only: the text, the line box and the level go; the clock keeps its time
		if m.kind == .Clock do c.text2 = ""
		else if c.icon == "" && c.battery < 0 do return c, false
		else { c.text, c.text2, c.box = "", "", ""; c.level = -1 }
	}
	if c.icon == "" && c.text == "" && c.text2 == "" && c.battery < 0 do return c, false
	fg := t.fg
	#partial switch st {
	case .Dim: fg = t.fg_dim
	case .Warn: fg = t.yellow
	case .Hover: c.bg = argb(t.selection, 0xff)
	case .Open: c.bg, fg, c.filled = argb(t.accent, 0xff), t.bg, true
	case .Crit: c.bg, fg, c.filled = argb(t.red, 0xff), t.bg, true
	}
	if c.filled do c.bold = true
	if m.wash != "" && !c.filled && st != .Hover do c.bg = argb(token(t, m.wash, t.accent), 0x1f) // a click's feedback: a faint tint of its tone
	if (m.text_tone == "yellow" || m.text_tone == "red" || m.text_tone == "green") && m.shape != .None do c.bold = true // (a shape's state in words: bold)
	c.fg = fg
	if c.filled {
		c.icon_c, c.text_c, c.text2_c, c.line_c = fg, fg, fg, fg
	} else {
		ic := fg
		if st == .Normal || st == .Hover do ic = token(t, m.tone, fg)
		c.icon_c = token(t, m.icon_tone, ic)
		c.text_c = token(t, m.text_tone, fg)
		c.text2_c = token(t, m.text2_tone, t.fg_dim)
		c.line_c = c.battery >= 0 && c.battery <= 25 ? t.yellow : fg
	}
	switch m.badge_tone { // accent for unread, red when the app needs you, faint under do not disturb
	case "red": c.badge_bg, c.badge_fg = t.red, t.bg
	case "yellow": c.badge_bg, c.badge_fg = t.yellow, t.bg // (a parcel's last pickup day)
	case "dnd": c.badge_bg, c.badge_fg = mix(t.bg, t.fg_dim, 0.45), t.fg_dim
	case: c.badge_bg, c.badge_fg = t.accent, t.bg
	}
	c.box_c = st == .Dim ? t.fg_dim : token(t, m.box_tone, t.accent)
	if flashing {
		c.level = m.pct
		c.text2 = fmt.tprintf("%d%%", m.pct)
		if !c.filled do c.text2_c = t.accent
	}
	return c, true
}

// How much a module asks for attention (the KGroups board): 4 critical (fills), 3 needs you (red),
// 2 soon / degraded (yellow), 1 something running (accent with a value), 0 quiet.
@(private)
mod_sev :: proc(m: ^Module) -> int {
	switch m.class { case "critical", "urgent", "error": return 4 }
	// (the icon's tone, the class and the badge say it; a coloured text alone is the value's own colour, as WoW's gold)
	tone := m.icon_tone != "" || m.icon != "" || m.shape != .None ? m.icon_tone : m.text_tone
	if tone == "red" || m.badge_tone == "red" do return 3
	if m.class == "warning" || tone == "yellow" || m.badge_tone == "yellow" do return 2
	if (m.icon_tone == "accent" || m.text_tone == "accent") && m.text != "" do return 1
	return 0
}

// The pins file (K4_BAR_PINS, else ~/.local/state/sway/bar-pins): "group member" lines, read again when it changes.
@(private)
bar_pins :: proc(b: ^Bar) {
	p := os.get_env("K4_BAR_PINS", context.temp_allocator)
	if p == "" do p = fmt.tprintf("%s/.local/state/sway/bar-pins", os.get_env("HOME", context.temp_allocator))
	fi, err := os.stat(p, context.temp_allocator)
	mt := err == nil ? time.time_to_unix(fi.modification_time) : 0
	if mt == b.pins_mtime && b.pins != nil do return
	b.pins_mtime = mt
	if b.pins == nil do b.pins = make(map[string]string)
	for k, v in b.pins { delete(k); delete(v) }
	clear(&b.pins)
	data, rerr := os.read_entire_file(p, context.temp_allocator)
	if rerr != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		g, _, mem := strings.partition(strings.trim_space(line), " ")
		if g != "" && mem != "" do b.pins[strings.clone(g)] = strings.clone(mem)
	}
}

// A group's chip (the KGroups board): its glyph and at most one value, the most urgent member speaking
// for the group in that member's colour; quiet: the pinned member's value (Info, System), the unread
// sum (Apps), how many show (Status). Hidden when no member shows; open (the accent) while its drawer is up.
@(private)
group_chip :: proc(a: ^App, i: int, S: int, narrow: bool) -> (c: Chip, shown: bool) {
	b := a.bar
	t := a.theme
	h := &b.mods[i]
	bar_pins(b)
	c = {icon = h.icon, battery = -1, level = -1, px = 7 * S, fg = t.fg, icon_c = t.fg, text_c = t.fg, text2_c = t.fg_dim, badge_bg = t.accent, badge_fg = t.bg}
	pin := b.pins[h.group] or_else h.pin
	worst, nvis, unread, red_badge := -1, 0, 0, false
	pinned, active, mic, kb, net := -1, -1, -1, -1, -1
	for &m, k in b.mods {
		if m.head || m.group != h.group do continue
		if _, ok := mod_chip(a, k, S, narrow); !ok do continue
		nvis += 1
		sv := mod_sev(&m)
		if worst < 0 || sv > mod_sev(&b.mods[worst]) do worst = k
		if m.badge > 0 { unread += m.badge; if m.badge_tone == "red" do red_badge = true }
		else if n, ok := strconv.parse_int(m.pill); ok && n > 0 { unread += n; if m.badge_tone == "red" do red_badge = true }
		if m.id == pin do pinned = k
		if sv == 1 && active < 0 do active = k
		switch m.id {
		case "microphone": mic = k
		case "keyboard": kb = k
		case "network": net = k
		}
	}
	if nvis == 0 do return c, false
	if net >= 0 && b.mods[net].icon != "" do c.icon = b.mods[net].icon // (Network: the Wi-Fi or Ethernet glyph is the group's)
	w := &b.mods[worst]
	wsev := mod_sev(w)
	tone := wsev == 3 ? t.red : t.yellow
	switch {
	case wsev >= 4: // critical: the group fills, in that member's words
		c.bg, c.fg, c.filled, c.bold = argb(t.red, 0xff), t.bg, true, true
		c.icon, c.shape, c.text = w.icon, w.shape, w.text
	case wsev >= 2 && w.text != "": c.icon_c, c.text_c, c.text, c.bold = tone, tone, w.text, true
	case wsev >= 2: c.icon_c = tone
	case pinned >= 0 && b.mods[pinned].text != "": c.text = b.mods[pinned].text
	}
	if c.text == "" && active >= 0 { c.text, c.text_c = b.mods[active].text, t.accent; if c.icon_c == t.fg do c.icon_c = t.accent }
	if h.group == "apps" && unread > 0 { c.badge = unread; if red_badge { c.badge_bg = t.red; if !c.filled do c.icon_c = t.red } }
	if h.group == "status" && c.text == "" { c.text, c.text_c = fmt.tprint(nvis), t.fg_dim }
	if mic >= 0 && mod_sev(&b.mods[mic]) == 3 { c.text2, c.text2_c = b.mods[mic].icon, t.red } // a muted mic joins in red
	if kb >= 0 && b.mods[kb].class != "dim" && b.mods[kb].text != "" && !c.filled { c.text2 = c.text2 != "" ? fmt.tprintf("%s %s", c.text2, b.mods[kb].text) : b.mods[kb].text; c.text2_c = t.fg }
	if b.icons_only { c.text, c.text2 = "", ""; c.px = 6 * S }
	if h.clicking { c.bg, c.fg, c.filled, c.bold = argb(t.accent, 0xff), t.bg, true, true } // its drawer is up
	else if b.hover == i && !c.filled do c.bg = argb(t.selection, 0xff)
	if c.filled do c.icon_c, c.text_c, c.text2_c = c.fg, c.fg, c.fg
	return c, true
}

// A member of a group while groups are on: its group's chip stands for it. Off: the chips go.
@(private)
grouped_away :: proc(b: ^Bar, m: ^Module) -> bool {
	if m.head do return !b.grouped
	return b.grouped && m.group != "" && bar_has_head(b, m.group)
}

@(private)
bar_has_head :: proc(b: ^Bar, g: string) -> bool { for &m in b.mods do if m.head && m.group == g do return true; return false }

// What each module shows, for the drawer (k4-bar drawer-data): written when something changed.
@(private)
bar_snapshot :: proc(b: ^Bar) {
	if !snap_dirty || !b.grouped do return
	snap_dirty = false
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if run == "" do run = "/tmp"
	sb := strings.builder_make(context.temp_allocator)
	cl :: proc(s: string) -> string { r, _ := strings.replace_all(s, "\t", " ", context.temp_allocator); r2, _ := strings.replace_all(r, "\n", " · ", context.temp_allocator); return r2 }
	shapes := [Shape]string{.None = "", .Shield_On = "shield-on", .Shield_Off = "shield-off", .Shield_Broken = "shield-broken", .Shield_Unsafe = "shield-unsafe", .Key = "key"}
	for &m in b.mods {
		if m.head || m.kind == .Workspaces || m.kind == .Window do continue
		fmt.sbprintfln(&sb, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s", m.id, m.group, cl(m.icon), shapes[m.shape], cl(m.text), cl(m.text2), m.icon_tone, m.text_tone,
			m.class, m.badge, m.badge_tone, cl(m.pill), cl(m.tooltip != "" ? m.tooltip : m.tip), cl(m.on[0]))
	}
	path := fmt.tprintf("%s/k4-bar-%s.tsv", run, b.output != "" ? b.output : "bar")
	_ = os.write_entire_file(fmt.tprintf("%s.tmp", path), transmute([]u8)strings.to_string(sb))
	_ = os.rename(fmt.tprintf("%s.tmp", path), path)
}

@(private)
chip_w :: proc(b: ^Bar, c: Chip, S: int) -> int {
	w := 0
	n := 0
	f := c.bold ? b.f_bold : b.f_text
	if c.shape != .None { w += 14 * S; n += 1 } else if c.icon != "" { w += tw(b.f_text, c.icon); n += 1 }
	if c.box != "" { w += tw(b.f_box, c.box) + 8 * S; n += 1 }
	if c.battery >= 0 { w += 22 * S; n += 1 }
	if c.level >= 0 { w += 4 * S; n += 1 }
	if c.text != "" { w += c.maxw > 0 ? min(tw(f, c.text), c.maxw) : tw(f, c.text); n += 1 }
	if c.text2 != "" { f2 := c.bold2 ? b.f_bold : b.f_text; w += c.maxw2 > 0 ? min(tw(f2, c.text2), c.maxw2) : tw(f2, c.text2); n += 1 }
	w += 6 * S * max(n - 1, 0) + 2 * c.px
	if c.badge > 0 do w += max(0, count_tag_w(b.f_badge, c.badge, S) - 5 * S - c.px + S) // the tag overhangs the end, into the padding
	else if c.pill != "" do w += max(0, pill_tag_w(b.f_badge, c.pill, S) - 5 * S - c.px + S)
	return max(w, c.minw)
}

@(private)
chip_draw :: proc(a: ^App, cv: ^Canvas, c: Chip, x, w, h, S: int) {
	b := a.bar
	t := a.theme
	if c.bg != 0 do fill_rect(cv, x, 0, w, h, c.bg)
	f := c.bold ? b.f_bold : b.f_text
	xx := x + c.px
	right := x + w - c.px
	if c.shape != .None { // a drawn icon (the Pi-hole shield), 14 px
		shape_draw(cv, c.shape, xx, (h - 14 * S) / 2, 14 * S, c.icon_c)
		xx += 14 * S + 6 * S
	} else if c.icon != "" {
		text_in(cv, b.f_text, c.icon, xx, 0, h, argb(c.icon_c, 0xff))
		xx += tw(b.f_text, c.icon) + 6 * S
	}
	if c.box != "" { // the outlined label: a bus line's number
		bw, bh := tw(b.f_box, c.box) + 8 * S, 16 * S
		by := (h - bh) / 2
		if !c.filled do fill_rect(cv, xx, by, bw, bh, argb(c.box_c, 0x1a))
		rounded_rect(cv, xx, by, bw, bh, 0, 0, f32(S), argb(c.filled ? c.fg : mix(t.bg, c.box_c, 0.55), 0xff))
		text_in(cv, b.f_box, c.box, xx + 4 * S, by, bh, argb(c.filled ? c.fg : c.box_c, 0xff))
		xx += bw + 6 * S
	}
	if c.battery >= 0 { // a 20×10 outline with the charge inside, a 2×4 nub
		by := (h - 10 * S) / 2
		rounded_rect(cv, xx, by, 20 * S, 10 * S, 0, 0, f32(S), argb(c.fg, 0xff))
		fill_rect(cv, xx + 2 * S, by + 2 * S, max(16 * S * clamp(c.battery, 0, 100) / 100, c.battery > 0 ? S : 0), 6 * S, argb(c.line_c, 0xff))
		fill_rect(cv, xx + 20 * S, by + 3 * S, 2 * S, 4 * S, argb(c.fg, 0xff))
		xx += 22 * S + 6 * S
	}
	if c.level >= 0 { // a 4×12 level bar, filled from the bottom
		ly := (h - 12 * S) / 2
		if !c.filled do fill_rect(cv, xx, ly, 4 * S, 12 * S, argb(t.selection, 0xff))
		lh := 12 * S * min(c.level, 100) / 100
		fill_rect(cv, xx, ly + 12 * S - lh, 4 * S, lh, argb(c.filled ? c.fg : (c.level > 100 ? t.red : t.accent), 0xff))
		xx += 4 * S + 6 * S
	}
	if c.text != "" {
		s := c.maxw > 0 ? ellipsize(f, c.text, min(c.maxw, right - xx)) : ellipsize(f, c.text, right - xx)
		text_in(cv, f, s, xx, 0, h, argb(c.text_c, 0xff))
		xx += tw(f, s) + 6 * S
	}
	if c.text2 != "" && xx < right {
		f2 := c.bold2 ? b.f_bold : b.f_text
		s := ellipsize(f2, c.text2, c.maxw2 > 0 ? min(c.maxw2, right - xx) : right - xx)
		text_in(cv, f2, s, xx, 0, h, argb(c.text2_c, 0xff))
		xx += tw(f2, s) + 6 * S
	}
	if c.badge > 0 { // its left edge 5 px inside the content's end, 2 px under the strip's top
		end := xx - 6 * S
		ring := c.bg != 0 ? c.bg : argb(t.bg, 0xff)
		count_tag(cv, b.f_badge, end - 5 * S, 2 * S, c.badge, S, c.badge_bg, c.badge_fg, ring)
	} else if c.pill != "" {
		end := xx - 6 * S
		ring := c.bg != 0 ? c.bg : argb(t.bg, 0xff)
		pill_tag(cv, b.f_badge, end - 5 * S, 2 * S, c.pill, S, c.badge_bg, c.badge_fg, ring)
	}
	if c.outline && !c.filled do rounded_rect(cv, x, 0, w, h, 0, 0, f32(S), argb(t.accent, 0xff))
}

// The workspaces of this output (all of them when the bar has none), with 1–5 always there
// on a single output.
@(private)
bar_workspaces :: proc(b: ^Bar) -> []Ws {
	out := make([dynamic]Ws, 0, 12, context.temp_allocator)
	outputs := make(map[string]bool, 4, context.temp_allocator)
	for ws in b.ws do outputs[ws.output] = true
	for ws in b.ws do if b.output == "" || ws.output == b.output do append(&out, ws)
	if len(outputs) <= 1 {
		for n in 1 ..= 5 {
			have := false
			for ws in out do if ws.num == n { have = true; break }
			if !have do append(&out, Ws{name = fmt.tprintf("%d", n), num = n, output = b.output, empty = true})
		}
		slice.sort_by(out[:], proc(x, y: Ws) -> bool { return x.num < y.num })
	}
	return out[:]
}

// "2:web" -> "2 web"; a plain number stays as it is.
@(private)
ws_label :: proc(ws: Ws) -> (string, bool) {
	if c := strings.index_byte(ws.name, ':'); c > 0 do return fmt.tprintf("%s %s", ws.name[:c], ws.name[c + 1:]), true
	if fmt.tprintf("%d", ws.num) == ws.name || ws.num <= 0 do return ws.name, false
	return fmt.tprintf("%d %s", ws.num, ws.name), true
}

@(private)
ws_cell_w :: proc(b: ^Bar, ws: Ws, S: int) -> int {
	label, named := ws_label(ws)
	f := ws.focused || ws.urgent ? b.f_bold : b.f_text
	return max(24 * S, tw(f, label) + (named ? 16 * S : 8 * S))
}

TIP_ROOM :: 36 // logical px the surface grows by while a tooltip is up

// A module's tooltip as one line.
@(private)
mod_tooltip :: proc(b: ^Bar, i: int) -> string {
	m := &b.mods[i]
	tip := m.tooltip != "" ? m.tooltip : m.tip
	if m.kind == .Window do tip = b.title
	if !strings.contains(tip, "\n") do return strings.trim_space(tip)
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	for l in strings.split_lines(tip, context.temp_allocator) do if strings.trim_space(l) != "" do append(&parts, strings.trim_space(l))
	return strings.join(parts[:], "  ·  ", context.temp_allocator)
}

bar_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	b := a.bar
	t := a.theme
	canvas_clear(cv)
	sh := min(b.height * S, cv.h)
	oy := b.bottom ? cv.h - sh : 0 // the strip's top in the surface
	strip := Canvas{cv.px[oy * cv.w:], cv.w, sh}
	bar_draw_strip(a, &strip, S)
	if oy > 0 do for &h in a.hits do h.y += oy
	if b.prev.ws >= 0 && b.prev.ws < len(b.ws_x) && cv.h >= sh + (4 + prev_h(&b.prev)) * S {
		y0 := b.bottom ? oy - (4 + prev_h(&b.prev)) * S : sh + 4 * S
		prev_draw(a, cv, S, b.ws_x[b.prev.ws] * S, y0)
	}
	// the tooltip: under the module (above it at the bottom), kept 8 px from the edges
	if b.tip >= 0 && b.tip < len(b.mods) && cv.h > sh {
		m := &b.mods[b.tip]
		tip := mod_tooltip(b, b.tip)
		w := min(tw(b.f_text, tip) + 18 * S, cv.w - 16 * S)
		h := int(b.f_text.line_h) + 10 * S
		x := clamp(m.x * S, 8 * S, max(cv.w - 8 * S - w, 8 * S))
		y := b.bottom ? oy - 6 * S - h : sh + 6 * S
		if y >= 0 && y + h <= cv.h {
			rounded_rect(cv, x, y, w, h, 0, argb(t.bg, a.bg_alpha), f32(S), argb(t.fg_dim, 0xff))
			text_in(cv, b.f_text, ellipsize(b.f_text, tip, w - 18 * S), x + 9 * S, y, h, argb(t.fg, 0xff))
		}
	}
}

@(private)
bar_draw_strip :: proc(a: ^App, cv: ^Canvas, S: int) {
	b := a.bar
	t := a.theme
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(t.bg, b.transparent ? (a.bg_alpha < 0xff ? a.bg_alpha : 0x8c) : 0xff)) // see-through: as the terminal
	// the 2 px rule: along the bottom (top when the bar sits at the bottom); dim on an output
	// without focus
	focused_here := true
	if b.output != "" do for ws in b.ws do if ws.focused { focused_here = ws.output == b.output; break }
	rule := argb(focused_here ? t.accent : t.fg_dim, 0xff)
	rule_y := b.bottom ? 0 : cv.h - 2 * S
	fill_rect(cv, 0, rule_y, cv.w, 2 * S, rule)
	ch := cv.h - 2 * S // the modules' height
	cv_mods := Canvas{cv.px[(b.bottom ? 2 * S : 0) * cv.w:], cv.w, ch} // drawn above (below) the rule
	gap := 2 * S
	narrow := cv.w / S < 1440
	wss := bar_workspaces(b)

	chips := make([]Chip, len(b.mods), context.temp_allocator)
	shown := make([]bool, len(b.mods), context.temp_allocator)
	widths := make([]int, len(b.mods), context.temp_allocator)
	title_i := -1
	for &m, i in b.mods {
		switch m.kind {
		case .Workspaces:
			w := 0
			for ws, k in wss { if k > 0 do w += gap; w += ws_cell_w(b, ws, S) }
			widths[i], shown[i] = w, len(wss) > 0
		case .Window:
			if b.title == "" || b.icons_only do break
			title_i = i
			chips[i] = Chip{text = b.title, px = 10 * S, maxw = 420 * S, fg = t.fg_dim, text_c = t.fg_dim, icon_c = t.fg_dim, battery = -1, level = -1}
			if b.hover == i do chips[i].bg = argb(t.selection, 0xff)
			widths[i], shown[i] = chip_w(b, chips[i], S), true
		case .Clock, .Exec, .Text:
			if grouped_away(b, &m) do break
			c: Chip
			ok: bool
			if m.head do c, ok = group_chip(a, i, S, narrow)
			else do c, ok = mod_chip(a, i, S, narrow)
			if m.kind == .Clock do c.px = (m.px == 7 ? 10 : m.px) * S
			chips[i], shown[i] = c, ok
			if ok do widths[i] = chip_w(b, c, S)
		}
	}
	span :: proc(side: int, b: ^Bar, shown: []bool, widths: []int, gap: int) -> int {
		w, n := 0, 0
		for m, i in b.mods do if m.side == side && shown[i] { w += widths[i]; n += 1 }
		return w + gap * max(n - 1, 0)
	}
	// the window title gives way first when the left group would run into the centre
	cw := span(1, b, shown, widths, gap)
	cx := (cv.w - cw) / 2
	if title_i >= 0 {
		over := 6 * S + span(0, b, shown, widths, gap) - (cx - 12 * S)
		if over > 0 {
			widths[title_i] = max(widths[title_i] - over, 0)
			if widths[title_i] < 2 * chips[title_i].px + 12 * S do shown[title_i] = false
		}
	}
	draw_mod :: proc(a: ^App, cv: ^Canvas, S, i, x, w: int, chips: []Chip, wss: []Ws) {
		b := a.bar
		t := a.theme
		m := &b.mods[i]
		m.x, m.w = x / S, w / S
		hit_add(a, x, 0, w, cv.h, .Row, i, -1)
		if m.kind != .Workspaces { chip_draw(a, cv, chips[i], x, w, cv.h, S); return }
		xx := x
		clear(&b.ws_x)
		for ws, k in wss {
			cw := ws_cell_w(b, ws, S)
			label, _ := ws_label(ws)
			f := b.f_text
			c := t.fg
			switch {
			case ws.urgent: fill_rect(cv, xx, 0, cw, cv.h, argb(t.red, 0xff)); c, f = t.bg, b.f_bold
			case ws.focused: fill_rect(cv, xx, 0, cw, cv.h, argb(t.accent, 0xff)); c, f = t.bg, b.f_bold
			case b.hover == i && b.hover_ws == k: fill_rect(cv, xx, 0, cw, cv.h, argb(t.selection, 0xff))
			case ws.visible: rounded_rect(cv, xx, 0, cw, cv.h, 0, 0, f32(S), argb(t.accent, 0xff)); c = t.accent
			case ws.empty: c = t.fg_dim
			}
			if ws.visible && !ws.focused && !ws.urgent && b.hover == i && b.hover_ws == k do c = t.accent
			hit_add(a, xx, 0, cw, cv.h, .Row, i, k)
			append(&b.ws_x, xx / S)
			text_in(cv, f, label, xx + (cw - tw(f, label)) / 2, 0, cv.h, argb(c, 0xff))
			xx += cw + 2 * S
		}
	}
	x := 6 * S
	for &m, i in b.mods do if m.side == 0 && shown[i] { draw_mod(a, &cv_mods, S, i, x, widths[i], chips, wss); x += widths[i] + gap }
	x = cv.w - 6 * S + gap
	#reverse for &m, i in b.mods do if m.side == 2 && shown[i] { x -= widths[i] + gap; draw_mod(a, &cv_mods, S, i, x, widths[i], chips, wss) }
	x = cx
	for &m, i in b.mods do if m.side == 1 && shown[i] { draw_mod(a, &cv_mods, S, i, x, widths[i], chips, wss); x += widths[i] + gap }
	for &m, i in b.mods do if !shown[i] do m.x, m.w = 0, 0
	// hits were added in the modules' canvas: move them below the rule when it is on top
	if b.bottom do for &h in a.hits do h.y += 2 * S
}

// ---------- the pointer ----------

bar_pointer_move :: proc(a: ^App, x, y: int) -> bool {
	b := a.bar
	h, ok := hit_at(a, x, y)
	if ok && (h.kind == .Item || h.kind == .Web) { // on the preview card: keep it, follow the rows
		row := h.kind == .Item ? h.a : -1
		if row == b.prev.row do return false
		b.prev.row = row
		return true
	}
	changed := false
	if ok && h.a >= 0 && h.a < len(b.mods) && b.mods[h.a].kind == .Workspaces && h.b >= 0 do changed = prev_pointer(a, h.b, false)
	else do changed = prev_pointer(a, -1, false)
	b.prev.row = -1
	if changed do bar_tick(a)
	nh, nw := ok ? h.a : -1, ok ? h.b : -1
	if nh == b.hover && nw == b.hover_ws do return changed
	if nh != b.hover { b.hover_at = time.tick_now(); b.tip_off = -1 }
	b.hover, b.hover_ws = nh, nw
	bar_tick(a) // a tooltip goes at once
	return true
}

// button: 1 left, 3 right, 2 middle; scroll: n steps (negative = up)
bar_pointer_click :: proc(a: ^App, x, y, button: int) -> bool {
	b := a.bar
	h := hit_at(a, x, y) or_return
	if h.kind != .Item && h.kind != .Web { b.tip_off = h.a; bar_tick(a) } // a click: its tooltip goes and stays gone (a popup opens there)
	if h.kind == .Item { if button == 1 do prev_click(a, h.a); return true }
	if h.kind == .Web do return false
	m := &b.mods[h.a]
	if m.kind == .Workspaces && button == 1 {
		wss := bar_workspaces(b)
		if h.b < 0 || h.b >= len(wss) do return false
		name := wss[h.b].name
		if b.hypr do hypr_focus_workspace(name)
		else if b.ipc_q >= 0 do ipc_query(b.ipc_q, IPC_RUN_COMMAND, fmt.tprintf("workspace \"%s\"", name), context.temp_allocator)
		bar_ipc_refresh(b)
		return true
	}
	if m.kind == .Clock && button == 3 && m.on[1] == "" { m.alt = !m.alt; bar_tick(a); return true }
	if m.kind == .Clock && button == 2 && m.on[2] == "" { m.utc_until = time.tick_add(time.tick_now(), 3 * time.Second); bar_tick(a); return true }
	cmd := ""
	switch button { case 1: cmd = m.on[0]; case 3: cmd = m.on[1]; case 2: cmd = m.on[2] }
	if cmd == "" do return false
	bar_run(a, m, cmd, button == 1)
	return true
}

bar_pointer_scroll :: proc(a: ^App, n: int) -> bool {
	b := a.bar
	if b.hover < 0 || b.hover >= len(b.mods) do return false
	m := &b.mods[b.hover]
	if m.kind == .Workspaces && (b.ipc_q >= 0 || b.hypr) {
		if b.hypr do hypr_focus_workspace(n > 0 ? "m+1" : "m-1")
		else do ipc_query(b.ipc_q, IPC_RUN_COMMAND, n > 0 ? "workspace next_on_output" : "workspace prev_on_output", context.temp_allocator)
		bar_ipc_refresh(b)
		return true
	}
	cmd := n < 0 ? m.on[3] : m.on[4]
	if m.kind == .Clock && cmd == "" { m.alt = !m.alt; bar_tick(a); return true } // the wheel: the other format
	if cmd == "" do return false
	bar_run(a, m, cmd, false)
	if m.flash do m.flash_until = time.tick_add(time.tick_now(), 1200 * time.Millisecond)
	return true
}

// A click's command, told where the module is. A left click's command is watched: the module
// is drawn open while it runs (a popup's k4 lives that long). The module runs again soon after.
@(private)
bar_run :: proc(a: ^App, m: ^Module, cmd: string, watch: bool) {
	b := a.bar
	sides := [3]string{"left", "center", "right"}
	env := fmt.tprintf("export K4_BAR_X=%d K4_BAR_MX=%d K4_BAR_MW=%d K4_BAR_SIDE=%s K4_BAR_WIDTH=%d K4_BAR_OUTPUT=%s K4_BAR_POS=%s K4_BAR_H=%d; ",
		m.x + m.w / 2, m.x, m.w, sides[m.side], b.width, b.output != "" ? b.output : "-", b.bottom ? "bottom" : "top", b.height)
	if watch && !m.clicking {
		if p, err := os.process_start({command = {"sh", "-c", strings.concatenate({env, cmd}, context.temp_allocator)}}); err == nil {
			m.click, m.clicking = p, true
		}
	} else {
		full := strings.clone_to_cstring(fmt.tprintf("%s setsid -f sh -c %s >/dev/null 2>&1 </dev/null", env, sh_quote(cmd)), context.temp_allocator)
		libc.system(full)
	}
	if m.kind == .Exec && m.interval > 0 && !m.running do m.next = time.tick_add(time.tick_now(), 250 * time.Millisecond)
}

// --dump for a bar: each module's text, left to right per side.
bar_dump :: proc(a: ^App) -> string {
	b := a.bar
	sb := strings.builder_make(context.temp_allocator)
	sides := [3]string{"left", "center", "right"}
	for side in 0 ..< 3 {
		fmt.sbprintf(&sb, "%s:", sides[side])
		for &m, i in b.mods {
			if m.side != side do continue
			switch m.kind {
			case .Workspaces:
				parts := make([dynamic]string, 0, 8, context.temp_allocator)
				for ws in bar_workspaces(b) do append(&parts, fmt.tprintf("%s%s", ws.name, ws.focused ? "*" : (ws.urgent ? "!" : (ws.empty ? "_" : ""))))
				fmt.sbprintf(&sb, " [%s]", strings.join(parts[:], " ", context.temp_allocator))
			case .Window: if b.title != "" && !b.icons_only do fmt.sbprintf(&sb, " [%s]", b.title)
			case .Clock, .Exec, .Text:
				if grouped_away(b, &m) do continue
				if m.head { // a group's chip, as drawn
					c, ok := group_chip(a, i, 1, false)
					if !ok do continue
					st := c.filled ? (m.clicking ? " open" : " fill") : (c.text_c == a.theme.red || c.icon_c == a.theme.red ? " red" : (c.text_c == a.theme.yellow || c.icon_c == a.theme.yellow ? " yellow" : ""))
					fmt.sbprintf(&sb, " <%s%s%s%s%s%s>", m.group, c.text != "" ? fmt.tprintf(" %s", c.text) : "", c.text2 != "" ? fmt.tprintf(" · %s", c.text2) : "",
						c.badge > 0 ? fmt.tprintf(" badge:%d", c.badge) : "", st, c.badge > 0 && c.badge_bg == a.theme.red ? "/red" : "")
					continue
				}
				if m.text == "" && m.icon == "" && m.text2 == "" && m.battery < 0 do continue
				if b.icons_only && m.kind != .Clock && m.icon == "" && m.battery < 0 do continue
				parts := make([dynamic]string, 0, 6, context.temp_allocator)
				if b.icons_only { // as drawn: the icon, the battery glyph and the tags; the clock its time
					if m.kind == .Clock do append(&parts, m.text)
					if m.icon != "" do append(&parts, m.icon)
					if m.battery >= 0 do append(&parts, fmt.tprintf("bat:%d", m.battery))
					if m.pill != "" do append(&parts, fmt.tprintf("pill:%s", m.pill))
					if m.badge > 0 do append(&parts, fmt.tprintf("badge:%d", m.badge))
					fmt.sbprintf(&sb, " [%s]", strings.join(parts[:], " ", context.temp_allocator))
					continue
				}
				if m.icon != "" do append(&parts, m.icon)
				if m.battery >= 0 do append(&parts, fmt.tprintf("bat:%d", m.battery))
				if m.level >= 0 do append(&parts, fmt.tprintf("lvl:%d", m.level))
				if m.text != "" do append(&parts, m.text)
				if m.text2 != "" do append(&parts, fmt.tprintf("· %s", m.text2))
				if m.pill != "" do append(&parts, fmt.tprintf("pill:%s", m.pill))
				if m.outline do append(&parts, "outline")
				if m.box != "" do append(&parts, fmt.tprintf("box:%s", m.box))
				if m.badge > 0 do append(&parts, fmt.tprintf("badge:%d%s", m.badge, m.badge_tone != "" ? fmt.tprintf("/%s", m.badge_tone) : ""))
				fmt.sbprintf(&sb, " [%s%s%s]", strings.join(parts[:], " ", context.temp_allocator), m.class != "" ? fmt.tprintf(" (%s)", m.class) : "", m.clicking ? " open" : "")
			}
		}
		fmt.sbprintln(&sb)
	}
	prev_dump(a, &sb)
	return strings.to_string(sb)
}

_ :: c

// The same tag with a short text ("?", "!").
@(private)
pill_tag_w :: proc(f: ^Font, l: string, S: int) -> int { return max(11 * S, tw(f, l) + 6 * S) }
@(private)
pill_tag :: proc(cv: ^Canvas, f: ^Font, x, y: int, l: string, S: int, bg, fg, ring: u32) -> int {
	w := pill_tag_w(f, l, S)
	h := 11 * S
	fill_rect(cv, x - 2 * S, y - 2 * S, w + 4 * S, h + 4 * S, argb(ring, 0xff))
	fill_rect(cv, x, y, w, h, argb(bg, 0xff))
	text_in(cv, f, l, x + (w - tw(f, l)) / 2, y, h, argb(fg, 0xff))
	return w
}
