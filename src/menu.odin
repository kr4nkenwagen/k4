package k4

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"
import "logic"

// --menu: the Kestrel design. A search-first two-pane menu (sections left, the highlighted
// section's actions right), a shortcut mode on Esc (letters open sections, digits run
// actions), full-width views (wallpaper gallery, theme list), web search ("g ") and a
// calculator ("="). Input on stdin, one record a line, tab-separated:
//   S <id> <name> <letter> <description> [icon]    a section
//   A <id> <label> [meta] [view] [flags]             an action of the last section; with a view
//                                                     name, Enter opens that view instead. flags,
//                                                     ';'-separated: stay (run via R and keep the
//                                                     menu open), confirm=<title>|<body>,
//                                                     jump=<section id>, app, slider=<0-100>
//                                                     [step=<n>] (← → adjust; R runs with
//                                                     K4_VALUE set to the new value)
//   H <text>                                         a heading between actions (not selectable)
//   R <shell command>                                runs "stay" actions: R <id>; its last stdout
//                                                     line becomes the footer message, then the
//                                                     sections and views reload
//   L <shell command>                                the last section's A lines come from this
//                                                     command, run in the background
//   V <name> <title> <subtitle> <shell command>      a list view; the command prints its items:
//                                                     I <id> <label> [image] [current]
//   G <name> <title> <subtitle> <shell command>      the same as a grid of pictures (4 across)
//                                                     items take a 5th field of flags: stay (run via
//                                                     R in place), palette=<#bg>,<#fg>,<6 colours>
//                                                     (theme rows: an "Aa" chip and swatches)
//   P <name> <title> <subtitle> <shell command>      a page: a full-width list whose command prints
//                                                     A/H lines like a section (every flag works);
//                                                     actions open it with view=<name>, ⌫ returns
//   F <name> <title> <subtitle> <shell command>      the same as a font page: each A line's label is
//                                                     a font family, drawn in that font, with a preview
// More action flags: input=<prompt>|<hint>[|password] asks for text inside the menu first, then
// runs the action via R with K4_INPUT set; current selects the row when its page opens.
// The runner's output lines that start with "k4:" are directives, tab-separated:
//   k4:input <id> <prompt> <hint> [password]         ask for text, then run <id> with K4_INPUT
//   k4:page <title> <subtitle> <shell command>       open a page of A/H lines (e.g. search results)
//   k4:back, k4:close                                 go back one level, or close the menu
// After every R run the theme (colors.toml) and font (font.name) are read again.
// Integration components (design: Apps integrations), in a section's or page's lines:
//   H <text> [count]                                 a heading with a count badge
//   E <text>                                          an empty line under a heading ("Nothing to review")
//   N <title> <body> <tone> [slow]                    a notice (tone: accent red muted); slow: only
//                                                     while the loader has run 8 s or more
//   K <n>                                             n loading bars (placeholders until rows land)
//   C <glyph> <state> <title> <line> <flags> [active] the now-playing card
//   B <label> <percent> <meta>                        a progress row (a snapshot)
//   D <desc> [count] [placeholder]                    the section's description, header count, placeholder
//   Y <key> <label> [<key> <label>…]                  the footer hints
//   Q <id>                                            typing is input for <id> (run with K4_INPUT) instead
//                                                     of a filter; Tab steps the first choice row
//   O pane                                            (after a P record) draw the page in the right pane,
//                                                     next to the sections, instead of full width
// A flags for them: mark=<glyph> markc=<tone> sub=<text> chip=<TEXT> chipc=<tone> metac=<tone>
// thumb=<image> dim slow key=<letter> (shortcut mode), choice=<a>|<b>|<c> (the meta is the
// value: ← → steps it and runs R with K4_VALUE set). A section's static lines show until its
// loader's output replaces them (a skeleton, or the last fetch). The action id k4:retry restarts
// the open section's loader. S takes a 7th field of flags: dim, group=<heading>.
//   T <crumb> <placeholder> <count>                   the top level's crumb, placeholder and count
// View items also take sub=<text> (a second line under grid tiles), wide (460×215 tiles) and
// alt=<label>|<id> (Tab runs it).
// Enter prints the chosen action's or item's id; a web search prints "url:<url>".

Entry_Kind :: enum { Row, Heading, Empty, Notice, Bars, Card, Progress }

Action :: struct {
	kind: Entry_Kind,
	id, label, meta, view: string,
	heading: bool, // anything that is not a selectable row
	count: string,
	mark, markc, sub, chip, chipc, metac, thumb, key: string,
	dim, slow: bool,
	choices: []string,
	// notice: label = title, meta = body, tone; card: glyph, state, label = title, meta = line,
	// line2 = flags; progress: label, meta, pct; bars: bars
	tone, glyph, state, line2: string,
	active: bool,
	pct, bars: int,
	stay, app: bool,
	slider: bool,
	value, step: int,
	jump: string,
	confirm_title, confirm_body: string,
	input: bool, input_password: bool,
	input_prompt, input_hint: string,
	current: bool,
}
Item :: struct {
	id, label, image: string,
	current, stay: bool,
	palette: [8]u32, has_palette: bool,
	sub, alt_label, alt_id: string,
	wide: bool,
}

Load_State :: enum { Ready, Lazy, Loading, Failed }

Loader :: struct {
	cmd:   string,
	refresh: bool, // reloading: keep the old rows until the new ones are in
	state: Load_State,
	pipe:  ^os.File,
	proc_: os.Process,
	buf:   [dynamic]u8,
	started: time.Tick,
	stale: bool, // an in-place action ran since it loaded: load again when it is next shown
}

SLOW_MS :: 8000 // a loader this slow gets the section's "slow" lines (K4_SLOW_MS overrides)

Page_Kind :: enum { Section, Page, Font }

// Sections are the left pane; pages (P, F, k4:page) are hidden sections drawn full width.
Section :: struct {
	id, name, key, desc, icon: string,
	kind:    Page_Kind,
	home:    int, // pages: the section they belong to (crumb; ⌫ when opened directly), -1 none
	back, back_si: int, // pages: the section/page and selection ⌫ returns to, -1 = home
	actions: [dynamic]Action,
	load:    Loader,
	desc0:   string, // the S/P description; D lines override it until the next load
	count, ph, query_id: string,
	has_d:   bool, // a D line set the count (an empty one hides it)
	pane:    bool, // a page drawn in the right pane, next to the sections (O pane)
	hints:   [dynamic][2]string,
	dim:     bool,
	group:   string,
}

View :: struct {
	name, title, subtitle: string,
	grid: bool,
	items: [dynamic]Item,
	load:  Loader,
}

Focus :: enum { Menu, Sub, View, Web, Calc, Confirm, Input }

// A font page's faces for one family, loaded on first draw.
Family_Fonts :: struct { ok: bool, name, sample, line, title, bold: ^Font }

Result :: struct { sec: int, act: int } // act < 0: the section itself

Menu :: struct {
	sections: [dynamic]Section,
	views:    [dynamic]View,
	focus:    Focus,
	shortcut: bool,
	cur:      int, // highlighted section (menu focus)
	open:     int, // section whose actions are open
	view:     int, // open view
	view_from: int, // action index that opened the view (Backspace returns to it)
	si:       int, // selection in sub / view / web lists
	scroll:   int,
	shown_sections, shown_items: [dynamic]int,
	shown_actions: [dynamic]int, // displayed entries of the open section (headings included)
	sel_actions:   [dynamic]int, // the selectable ones among them (indices into actions)
	results:  [dynamic]Result,   // global search
	run_cmd:  string,
	runner:   Loader,            // the stay action in flight
	slide_pending: bool,         // a slider moved while the runner was busy
	slide_sec, slide_act: int,
	pending:  Result,            // confirmation target
	confirm_from: Focus,
	cf:       int,               // 0 Yes, 1 No
	loading:  int,
	toast:    string,
	history:  [dynamic][2]string,
	// text input (input= flag, k4:input)
	input_id, input_label, input_prompt, input_hint: string,
	input_password: bool,
	input_from: Focus,
	input_from_si: int,
	dyn_pages: int,
	families: map[string]Family_Fonts,
	top_crumb, top_ph, top_count: string, // T record
	slow_ms: int,
	f_body, f_small, f_tiny, f_big, f_title, f_row, f_huge, f_confirm, f_bold13, f_bold12, f_bold11, f_bold10, f_glyph: ^Font,
}

MENU_W :: 760
MENU_H :: 600
MAX_LOADERS :: 4

// ---------- input ----------

menu_parse :: proc(m: ^Menu, data: string) {
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(strings.trim_suffix(line, "\r"), "\t")
		if len(f) == 0 do continue
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
		switch f[0] {
		case "S":
			s := Section{id = get(f, 1), name = get(f, 2), key = strings.to_upper(get(f, 3)), desc = get(f, 4), icon = get(f, 5), home = len(m.sections), back = -1}
			for flag in strings.split(get(f, 6), ";", context.temp_allocator) {
				if flag == "dim" do s.dim = true
				if strings.has_prefix(flag, "group=") do s.group = strings.clone(flag[6:])
			}
			s.desc0 = s.desc
			append(&m.sections, s)
		case "P", "F":
			if len(f) > 4 {
				home := -1
				#reverse for s, i in m.sections do if s.kind == .Section { home = i; break }
				append(&m.sections, Section{id = f[1], name = f[2], desc = f[3], desc0 = f[3], kind = f[0] == "F" ? .Font : .Page, home = home, back = -1, load = {cmd = strings.join(f[4:], "\t"), state = .Lazy}})
			}
		case "T":
			m.top_crumb, m.top_ph, m.top_count = get(f, 1), get(f, 2), get(f, 3)
		case "A", "H", "E", "N", "K", "C", "B", "D", "Y", "Q", "O":
			if len(m.sections) > 0 do section_line(&m.sections[len(m.sections) - 1], f)
		case "R":
			if len(f) > 1 do m.run_cmd = strings.join(f[1:], "\t")
		case "L":
			if len(m.sections) > 0 && len(f) > 1 {
				s := &m.sections[len(m.sections) - 1]
				s.load = Loader{cmd = strings.join(f[1:], "\t"), state = .Lazy}
			}
		case "V", "G":
			if len(f) > 4 do append(&m.views, View{name = f[1], title = f[2], subtitle = f[3], grid = f[0] == "G", load = {cmd = strings.join(f[4:], "\t"), state = .Lazy}})
		}
	}
}

// One line of a section's or page's body (static in the tree, or from its loader).
@(private)
section_line :: proc(s: ^Section, f: []string) {
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
	switch f[0] {
	case "A", "H": append(&s.actions, action_from(f))
	case "E": append(&s.actions, Action{kind = .Empty, heading = true, label = strings.clone(get(f, 1))})
	case "N":
		append(&s.actions, Action{kind = .Notice, heading = true, label = strings.clone(get(f, 1)), meta = strings.clone(get(f, 2)), tone = strings.clone(get(f, 3)), slow = get(f, 4) == "slow"})
	case "K":
		n, _ := strconv.parse_int(get(f, 1))
		append(&s.actions, Action{kind = .Bars, heading = true, bars = clamp(n, 1, 8)})
	case "C":
		append(&s.actions, Action{kind = .Card, heading = true, glyph = strings.clone(get(f, 1)), state = strings.clone(get(f, 2)), label = strings.clone(get(f, 3)), meta = strings.clone(get(f, 4)), line2 = strings.clone(get(f, 5)), active = get(f, 6) == "active"})
	case "B":
		p, _ := strconv.parse_int(get(f, 2))
		append(&s.actions, Action{kind = .Progress, heading = true, label = strings.clone(get(f, 1)), pct = clamp(p, 0, 100), meta = strings.clone(get(f, 3))})
	case "D":
		s.desc, s.count, s.ph = strings.clone(get(f, 1)), strings.clone(get(f, 2)), strings.clone(get(f, 3))
		s.has_d = true
	case "Y":
		clear(&s.hints)
		for i := 1; i + 1 < len(f); i += 2 do append(&s.hints, [2]string{strings.clone(f[i]), strings.clone(f[i + 1])})
	case "Q":
		s.query_id = strings.clone(get(f, 1))
	case "O":
		for flag in strings.split(get(f, 1), ";", context.temp_allocator) do if flag == "pane" do s.pane = true
	}
}

// A loader's output replaces the section's lines (its skeleton, cached rows, or the last load).
@(private)
section_reset :: proc(s: ^Section) {
	clear(&s.actions)
	clear(&s.hints)
	s.desc, s.count, s.ph, s.query_id = s.desc0, "", "", ""
	s.has_d = false
}

@(private)
action_from :: proc(f: []string) -> Action {
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
	if f[0] == "H" do return Action{kind = .Heading, label = strings.clone(get(f, 1)), count = strings.clone(get(f, 2)), heading = true}
	a := Action{id = strings.clone(get(f, 1)), label = strings.clone(get(f, 2)), meta = strings.clone(get(f, 3)), view = strings.clone(get(f, 4))}
	for flag in strings.split(get(f, 5), ";", context.temp_allocator) {
		switch {
		case flag == "stay": a.stay = true
		case flag == "app": a.app = true
		case strings.has_prefix(flag, "slider="):
			a.slider, a.stay = true, true
			if v, ok := strconv.parse_int(flag[7:]); ok do a.value = clamp(v, 0, 100)
		case strings.has_prefix(flag, "step="):
			if v, ok := strconv.parse_int(flag[5:]); ok do a.step = v
		case strings.has_prefix(flag, "jump="): a.jump = strings.clone(flag[5:])
		case flag == "current": a.current = true
		case flag == "dim": a.dim = true
		case flag == "slow": a.slow = true
		case strings.has_prefix(flag, "mark="): a.mark = strings.clone(flag[5:])
		case strings.has_prefix(flag, "markc="): a.markc = strings.clone(flag[6:])
		case strings.has_prefix(flag, "sub="): a.sub = strings.clone(flag[4:])
		case strings.has_prefix(flag, "chip="): a.chip = strings.clone(flag[5:])
		case strings.has_prefix(flag, "chipc="): a.chipc = strings.clone(flag[6:])
		case strings.has_prefix(flag, "metac="): a.metac = strings.clone(flag[6:])
		case strings.has_prefix(flag, "thumb="): a.thumb = strings.clone(flag[6:])
		case strings.has_prefix(flag, "key="): a.key = strings.to_upper(flag[4:])
		case strings.has_prefix(flag, "choice="):
			a.stay = true
			cs := strings.split(flag[7:], "|")
			for &c in cs do c = strings.clone(c)
			a.choices = cs
		case strings.has_prefix(flag, "input="):
			a.input, a.stay = true, true
			parts := strings.split(flag[6:], "|", context.temp_allocator)
			a.input_prompt = strings.clone(parts[0])
			if len(parts) > 1 do a.input_hint = strings.clone(parts[1])
			a.input_password = len(parts) > 2 && parts[2] == "password"
		case strings.has_prefix(flag, "confirm="):
			t := flag[8:]
			bar := strings.index_byte(t, '|')
			a.confirm_title = strings.clone(bar >= 0 ? t[:bar] : t)
			if bar >= 0 do a.confirm_body = strings.clone(t[bar + 1:])
		}
	}
	return a
}

// ---------- background loading ----------

@(private)
loader_start :: proc(m: ^Menu, l: ^Loader) {
	if l.state != .Lazy || m.loading >= MAX_LOADERS do return
	r, w, err := os.pipe()
	if err != nil { l.state = .Failed; return }
	p, perr := os.process_start({command = {"sh", "-c", l.cmd}, stdout = w})
	os.close(w)
	if perr != nil { os.close(r); l.state = .Failed; return }
	l.pipe, l.proc_, l.state = r, p, .Loading
	l.started = time.tick_now()
	m.loading += 1
}

// The open section's loader has run long enough for its "slow" lines.
@(private)
section_slow :: proc(m: ^Menu, s: ^Section) -> bool {
	if s.load.state != .Loading do return false
	limit := m.slow_ms > 0 ? m.slow_ms : SLOW_MS
	return time.duration_milliseconds(time.tick_since(s.load.started)) >= f64(limit)
}

// Milliseconds until the menu needs a redraw on its own (the slow notice, the waiting
// count), or -1.
menu_tick_ms :: proc(m: ^Menu) -> int {
	if m.focus != .Sub || m.open < 0 || m.open >= len(m.sections) do return -1
	if m.sections[m.open].load.state != .Loading do return -1
	return 1000
}

// Called when menu_tick_ms ran out: the slow lines may have to show now.
menu_on_tick :: proc(a: ^App) {
	menu_refilter(a)
}

// k4:retry: start the open section's loader again.
@(private)
loader_restart :: proc(m: ^Menu, l: ^Loader) {
	if l.state == .Loading {
		_ = os.process_kill(l.proc_)
		os.close(l.pipe)
		_, _ = os.process_wait(l.proc_)
		m.loading -= 1
	}
	clear(&l.buf)
	l.state = .Lazy
	l.refresh = true
	loader_start(m, l)
}

// Sections load in the background from the start; a page only while it is open (a Wi-Fi
// scan or a Bluetooth scan must not run for every menu).
menu_start_loaders :: proc(m: ^Menu) {
	if m.open >= 0 && m.open < len(m.sections) do loader_start(m, &m.sections[m.open].load)
	if m.cur < len(m.sections) do loader_start(m, &m.sections[m.cur].load)
	for &s in m.sections do if s.kind == .Section do loader_start(m, &s.load)
	for &v in m.views do loader_start(m, &v.load)
}

// After a "stay" action: load what is on screen again at once (keeping it shown until the
// new rows arrive); everything else is marked stale and loads again when it is next shown.
// Reloading all of it here queued the visible view behind every section (seconds).
menu_reload :: proc(m: ^Menu) {
	on_screen :: proc(m: ^Menu, i: int) -> bool {
		if m.focus == .Menu do return i == m.cur
		return i == m.open || i == root(m, m.open)
	}
	for &v, i in m.views do if v.load.state == .Ready {
		if m.focus == .View && i == m.view do loader_refresh(m, &v.load)
		else do v.load.stale = true
	}
	for &s, i in m.sections do if s.load.cmd != "" && s.load.state == .Ready {
		if on_screen(m, i) do loader_refresh(m, &s.load)
		else do s.load.stale = true
	}
}

// Load again, keeping the old rows until the new ones are in.
@(private)
loader_refresh :: proc(m: ^Menu, l: ^Loader) {
	if l.state != .Ready do return
	l.state, l.refresh, l.stale = .Lazy, true, false
	clear(&l.buf)
	loader_start(m, l)
}

// A section or view about to be shown: reload it if an action ran since it loaded.
@(private)
refresh_if_stale :: proc(m: ^Menu, l: ^Loader) {
	if l.stale do loader_refresh(m, l)
}

menu_poll_fds :: proc(m: ^Menu, out: ^[dynamic]linux.Poll_Fd) {
	if m.runner.state == .Loading do append(out, linux.Poll_Fd{fd = linux.Fd(os.fd(m.runner.pipe)), events = {.IN}})
	for s in m.sections do if s.load.state == .Loading do append(out, linux.Poll_Fd{fd = linux.Fd(os.fd(s.load.pipe)), events = {.IN}})
	for v in m.views do if v.load.state == .Loading do append(out, linux.Poll_Fd{fd = linux.Fd(os.fd(v.load.pipe)), events = {.IN}})
}

// Reads one chunk from the loader on fd; returns true when it finished.
@(private)
loader_read :: proc(m: ^Menu, l: ^Loader) -> (finished: bool) {
	chunk: [8192]u8
	n, _ := os.read(l.pipe, chunk[:])
	if n > 0 { append(&l.buf, ..chunk[:n]); return false }
	os.close(l.pipe)
	_, _ = os.process_wait(l.proc_)
	l.state = .Ready
	m.loading -= 1
	return true
}

menu_on_readable :: proc(a: ^App, fd: linux.Fd) -> bool {
	m := a.menu
	if m.runner.state == .Loading && linux.Fd(os.fd(m.runner.pipe)) == fd {
		if !loader_read(m, &m.runner) do return false
		last := ""
		directives := make([dynamic]string, 0, 2, context.temp_allocator)
		text := string(m.runner.buf[:])
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "k4:") do append(&directives, line)
			else if strings.trim_space(line) != "" do last = line
		}
		m.toast = last != "" ? strings.clone(last) : "" // no message: drop the "Label  …" of the run
		m.runner = {}
		if m.slide_pending {
			m.slide_pending = false
			execute(a, m.slide_sec, m.slide_act)
			return true
		}
		app_load_style(a, false) // a theme or font change shows up in the menu itself
		menu_reload(m)
		toast := m.toast
		for d in directives do menu_directive(a, d)
		if m.focus != .Input do m.toast = toast // the run's message outlives the page change
		return true
	}
	for &s, si in m.sections {
		if s.load.state != .Loading || linux.Fd(os.fd(s.load.pipe)) != fd do continue
		if !loader_read(m, &s.load) do return false
		first := !s.load.refresh
		s.load.refresh = false
		section_reset(&s)
		text := string(s.load.buf[:])
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) > 0 do section_line(&s, f)
		}
		menu_start_loaders(m)
		menu_refilter(a)
		if first && m.focus == .Sub && m.open == si do select_current_action(m)
		return true
	}
	for &v in m.views {
		if v.load.state != .Loading || linux.Fd(os.fd(v.load.pipe)) != fd do continue
		if !loader_read(m, &v.load) do return false
		if v.load.refresh do clear(&v.items)
		v.load.refresh = false
		text := string(v.load.buf[:])
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t")
			if len(f) < 3 || f[0] != "I" do continue
			it := Item{id = strings.clone(f[1]), label = strings.clone(f[2])}
			if len(f) > 3 do it.image = strings.clone(f[3])
			if len(f) > 4 do it.current = f[4] == "current"
			if len(f) > 5 do item_flags(&it, f[5])
			append(&v.items, it)
		}
		menu_start_loaders(m)
		if m.focus == .View && &m.views[m.view] == &v do menu_select_current(m)
		menu_refilter(a)
		return true
	}
	return false
}

@(private)
has_current :: proc(v: ^View) -> bool {
	for it in v.items do if it.current do return true
	return false
}

@(private)
item_flags :: proc(it: ^Item, flags: string) {
	for flag in strings.split(flags, ";", context.temp_allocator) {
		switch {
		case flag == "stay": it.stay = true
		case flag == "wide": it.wide = true
		case strings.has_prefix(flag, "sub="): it.sub = strings.clone(flag[4:])
		case strings.has_prefix(flag, "alt="):
			t := flag[4:]
			if bar := strings.index_byte(t, '|'); bar >= 0 do it.alt_label, it.alt_id = strings.clone(t[:bar]), strings.clone(t[bar + 1:])
		case strings.has_prefix(flag, "palette="):
			for c, i in strings.split(flag[8:], ",", context.temp_allocator) {
				if i >= len(it.palette) do break
				hex := strings.trim_prefix(strings.trim_space(c), "#")
				if v, ok := strconv.parse_u64_of_base(hex, 16); ok && len(hex) == 6 do it.palette[i] = u32(v)
			}
			it.has_palette = true
		}
	}
}

// A k4: line from the runner (see the format at the top).
@(private)
menu_directive :: proc(a: ^App, line: string) {
	m := a.menu
	f := strings.split(line, "\t", context.temp_allocator)
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
	switch f[0] {
	case "k4:input":
		if len(f) > 2 do enter_input(a, f[1], get(f, 2), get(f, 2), get(f, 3), get(f, 4) == "password")
	case "k4:page":
		if len(f) < 4 do return
		home := m.open >= 0 && m.open < len(m.sections) ? m.sections[m.open].home : -1
		// the same title again (a new search) reuses its page
		idx := -1
		for s, i in m.sections do if s.kind == .Page && strings.has_prefix(s.id, "k4:") && s.name == f[1] { idx = i; break }
		pg := Section{id = fmt.aprintf("k4:%d", m.dyn_pages), name = strings.clone(f[1]), desc = strings.clone(f[2]), desc0 = strings.clone(f[2]), kind = .Page, home = home, back = -1, load = {cmd = strings.clone(strings.join(f[3:], "\t", context.temp_allocator)), state = .Lazy}}
		m.dyn_pages += 1
		if idx >= 0 { if m.sections[idx].load.state != .Loading do m.sections[idx] = pg } else { append(&m.sections, pg); idx = len(m.sections) - 1 }
		page_open(a, idx)
	case "k4:back":
		if m.focus != .Menu do menu_back(a)
	case "k4:close":
		a.exit = 1
		a.done = true
	}
}

// Dry runs and tests: wait for every loader.
menu_load_all :: proc(a: ^App) {
	m := a.menu
	for {
		menu_start_loaders(m)
		if m.runner.state == .Loading do for m.runner.state == .Loading do menu_on_readable(a, linux.Fd(os.fd(m.runner.pipe)))
		if m.loading == 0 do break
		for &s in m.sections do for s.load.state == .Loading do menu_on_readable(a, linux.Fd(os.fd(s.load.pipe)))
		for &v in m.views do for v.load.state == .Loading do menu_on_readable(a, linux.Fd(os.fd(v.load.pipe)))
	}
}

// ---------- state ----------

@(private)
has_fold :: proc(hay, needle: string) -> bool {
	if needle == "" do return true
	return strings.contains(strings.to_lower(hay, context.temp_allocator), strings.to_lower(needle, context.temp_allocator))
}

@(private) q_of :: proc(a: ^App) -> string { return strings.trim_space(string(a.query[:])) }

@(private) searching :: proc(m: ^Menu, a: ^App) -> bool { return m.focus == .Menu && !m.shortcut && q_of(a) != "" }

menu_refilter :: proc(a: ^App) {
	m := a.menu
	q := q_of(a)
	clear(&m.shown_sections); clear(&m.shown_actions); clear(&m.sel_actions); clear(&m.shown_items); clear(&m.results)
	for s, i in m.sections do if s.kind == .Section do append(&m.shown_sections, i)
	sec := m.focus == .Menu ? m.cur : m.open
	if sec >= 0 && sec < len(m.sections) {
		s := &m.sections[sec]
		filter := m.focus == .Sub && !m.shortcut && q != "" && s.query_id == ""
		slow := section_slow(m, s)
		for act, i in s.actions {
			if act.slow && !slow do continue
			if filter && (act.heading || !has_fold(act.label, q)) do continue
			append(&m.shown_actions, i)
			if !act.heading do append(&m.sel_actions, i)
		}
	}
	if m.focus == .View && m.view < len(m.views) {
		for it, i in m.views[m.view].items do if has_fold(it.label, q) do append(&m.shown_items, i)
	}
	if searching(m, a) do menu_search(m, q)
	n := menu_list_len(a)
	m.si = n > 0 ? clamp(m.si, 0, n - 1) : 0
}

// Global search, as in the design: sections whose names hold every word, then every action
// whose label + heading + section holds every word, prefix matches and apps first.
@(private)
menu_search :: proc(m: ^Menu, q: string) {
	toks := strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator)
	all_in :: proc(text: string, toks: []string) -> bool { for t in toks do if !strings.contains(text, t) do return false; return true }
	for s, i in m.sections do if s.kind == .Section && all_in(strings.to_lower(s.name, context.temp_allocator), toks) do append(&m.results, Result{i, -1})
	Scored :: struct { r: Result, score: int }
	items := make([dynamic]Scored, 0, 64, context.temp_allocator)
	ql := strings.to_lower(q, context.temp_allocator)
	for s, si in m.sections {
		if s.kind != .Section do continue
		hdr := ""
		for act, ai in s.actions {
			if act.kind == .Heading { hdr = act.label; if bar := strings.index(hdr, " · "); bar >= 0 do hdr = hdr[:bar]; continue }
			if act.heading || act.slow do continue
			text := strings.to_lower(strings.concatenate({act.label, " ", hdr, " ", s.name}, context.temp_allocator), context.temp_allocator)
			if !all_in(text, toks) do continue
			score := (strings.has_prefix(strings.to_lower(act.label, context.temp_allocator), ql) ? 2 : 0) + (act.app ? 1 : 0)
			append(&items, Scored{Result{si, ai}, score})
		}
	}
	// stable sort by score, highest first
	for i in 1 ..< len(items) {
		j := i
		for j > 0 && items[j - 1].score < items[j].score { items[j - 1], items[j] = items[j], items[j - 1]; j -= 1 }
	}
	for it in items { if len(m.results) >= 60 do break; append(&m.results, it.r) }
}

menu_list_len :: proc(a: ^App) -> int {
	m := a.menu
	switch m.focus {
	case .Menu: return searching(m, a) ? len(m.results) : len(m.sections)
	case .Sub: return len(m.sel_actions)
	case .View: return len(m.shown_items)
	case .Web: return len(web_rows(a))
	case .Calc, .Confirm, .Input: return 0
	}
	return 0
}

@(private)
menu_select_current :: proc(m: ^Menu) {
	v := &m.views[m.view]
	for it, i in v.items do if it.current { m.si = i; return }
	m.si = 0
}

// Typing: "g " starts a web search, "=" the calculator (menu focus only).
menu_on_query :: proc(a: ^App) {
	m := a.menu
	q := string(a.query[:])
	m.toast = ""
	if m.focus == .Menu {
		if len(q) >= 2 && (q[0] == 'g' || q[0] == 'G') && q[1] == ' ' {
			set_query(a, q[2:]); m.focus, m.si = .Web, 0; menu_refilter(a); return
		}
		if len(q) >= 1 && q[0] == '=' {
			set_query(a, q[1:]); m.focus, m.si = .Calc, 0; menu_refilter(a); return
		}
	}
	m.si = 0
	m.scroll = 0
	menu_refilter(a)
}

@(private)
set_query :: proc(a: ^App, s: string) {
	tmp := strings.clone(s, context.temp_allocator)
	clear(&a.query)
	append(&a.query, ..transmute([]u8)tmp)
	a.cursor = len(a.query)
}

@(private) clear_query :: proc(a: ^App) { clear(&a.query); a.cursor = 0 }

// The left-pane section a section or page belongs to.
@(private)
root :: proc(m: ^Menu, idx: int) -> int {
	if idx < 0 || idx >= len(m.sections) do return 0
	if m.sections[idx].kind == .Section do return idx
	h := m.sections[idx].home
	return h >= 0 && h < len(m.sections) ? h : 0
}

@(private) is_page :: proc(m: ^Menu, idx: int) -> bool { return idx >= 0 && idx < len(m.sections) && m.sections[idx].kind != .Section }

menu_enter :: proc(a: ^App, idx: int) {
	m := a.menu
	if idx < 0 || idx >= len(m.sections) do return
	m.focus, m.open, m.cur, m.si, m.scroll, m.toast = .Sub, idx, root(m, idx), 0, 0, ""
	refresh_if_stale(m, &m.sections[idx].load)
	loader_start(m, &m.sections[idx].load)
	clear_query(a)
	menu_refilter(a)
	select_current_action(m)
}

// A row flagged "current" is selected when its section or page opens.
@(private)
select_current_action :: proc(m: ^Menu) {
	if m.open < 0 || m.open >= len(m.sections) do return
	for v, i in m.sel_actions do if m.sections[m.open].actions[v].current { m.si = i; return }
}

// Opens a page from wherever the menu is; ⌫ comes back here.
@(private)
page_open :: proc(a: ^App, idx: int) {
	m := a.menu
	pg := &m.sections[idx]
	pg.back, pg.back_si = -1, 0
	if m.focus == .Sub && m.open != idx do pg.back, pg.back_si = m.open, m.si
	menu_enter(a, idx)
}

menu_open_view :: proc(a: ^App, name: string, from: int) {
	m := a.menu
	for &v, i in m.views {
		if v.name != name do continue
		m.focus, m.view, m.view_from, m.scroll, m.toast = .View, i, from, 0, ""
		refresh_if_stale(m, &v.load)
		loader_start(m, &v.load)
		clear_query(a)
		menu_select_current(m)
		menu_refilter(a)
		return
	}
	m.toast = fmt.aprintf("No %s view", name)
}

menu_back :: proc(a: ^App) {
	m := a.menu
	m.toast = ""
	switch m.focus {
	case .Confirm:
		m.toast = "Cancelled"
		menu_leave_confirm(a)
	case .Input:
		m.toast = "Cancelled"
		leave_input(a)
		return
	case .View:
		m.focus, m.si, m.scroll = .Sub, max(m.view_from, 0), 0
		clear_query(a)
	case .Sub:
		if is_page(m, m.open) {
			pg := m.sections[m.open]
			to, si := pg.back, pg.back_si
			if to < 0 || to >= len(m.sections) do to, si = pg.home, 0
			if to >= 0 && to < len(m.sections) {
				menu_enter(a, to)
				n := len(m.sel_actions)
				m.si = n > 0 ? clamp(si, 0, n - 1) : 0
				return
			}
		}
		m.focus, m.cur, m.si = .Menu, root(m, m.open), 0
		clear_query(a)
	case .Web, .Calc:
		m.focus, m.si = .Menu, 0
		clear_query(a)
	case .Menu:
		if len(a.query) > 0 do clear_query(a)
		else { a.exit = 1; a.done = true }
	}
	menu_refilter(a)
}

menu_move :: proc(a: ^App, d: int) {
	m := a.menu
	m.toast = ""
	if m.focus == .Menu && !searching(m, a) {
		n := len(m.shown_sections)
		if n == 0 do return
		pos := 0
		for s, i in m.shown_sections do if s == m.cur { pos = i; break }
		m.cur = m.shown_sections[((pos + d) % n + n) % n]
		refresh_if_stale(m, &m.sections[m.cur].load)
		loader_start(m, &m.sections[m.cur].load)
		menu_refilter(a)
		return
	}
	n := menu_list_len(a)
	if n == 0 do return
	if m.focus == .View && m.views[m.view].grid do m.si = clamp(m.si + d, 0, n - 1) // grid: no wrap-around
	else do m.si = ((m.si + d) % n + n) % n
}

Web_Row :: struct { tag, label, meta, url: string }

BANGS := [][2]string{{"!aw", "Arch Wiki"}, {"!w", "Wikipedia"}, {"!gh", "GitHub"}, {"!yt", "YouTube"}}

web_rows :: proc(a: ^App) -> []Web_Row {
	q := q_of(a)
	if q == "" do return nil
	rows := make([dynamic]Web_Row, 0, 5, context.temp_allocator)
	ddg :: proc(s: string) -> string { return strings.concatenate({"https://duckduckgo.com/?q=", url_escape(s)}, context.temp_allocator) }
	append(&rows, Web_Row{"DDG", fmt.tprintf("Search DuckDuckGo for “%s”", q), "duckduckgo.com", ddg(q)})
	if q[0] != '!' do for b in BANGS do append(&rows, Web_Row{b[0], q, b[1], ddg(fmt.tprintf("%s %s", b[0], q))})
	return rows[:]
}

@(private)
url_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~': strings.write_byte(&b, c)
		case ' ': strings.write_byte(&b, '+')
		case: fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

menu_run :: proc(a: ^App) {
	m := a.menu
	switch m.focus {
	case .Menu:
		if searching(m, a) {
			if m.si >= len(m.results) do return
			r := m.results[m.si]
			if r.act < 0 do menu_enter(a, r.sec)
			else do run_action(a, r.sec, r.act)
		} else do menu_enter(a, m.cur)
	case .Sub:
		// a Q section: typed text goes to its input action
		if s := &m.sections[m.open]; s.query_id != "" && strings.trim_space(string(a.query[:])) != "" {
			if m.runner.state == .Loading { m.toast = "Still running the last action…"; return }
			value := strings.clone(string(a.query[:]), context.temp_allocator)
			clear_query(a)
			start_runner(a, s.query_id, "K4_INPUT", value, strings.concatenate({s.name, "  …"}))
			return
		}
		if m.si < len(m.sel_actions) do run_action(a, m.open, m.sel_actions[m.si])
	case .View:
		if m.si >= len(m.shown_items) do return
		v := &m.views[m.view]
		it := v.items[m.shown_items[m.si]]
		if it.stay && m.run_cmd != "" {
			if m.runner.state == .Loading { m.toast = "Still running the last action…"; return }
			// the picked one is current right away; the view's reload confirms it
			if it.current || has_current(v) {
				for &x in v.items do x.current = false
				v.items[m.shown_items[m.si]].current = true
			}
			start_runner(a, it.id, "", "", strings.concatenate({it.label, "  …"}))
		} else do finish(a, it.id)
	case .Input:
		value := string(a.query[:])
		if strings.trim_space(value) == "" do return
		if m.runner.state == .Loading { m.toast = "Still running the last action…"; return }
		id, label := m.input_id, m.input_label
		value = strings.clone(value, context.temp_allocator)
		leave_input(a)
		start_runner(a, id, "K4_INPUT", value, strings.concatenate({label, "  …"}))
	case .Web:
		rows := web_rows(a)
		if m.si < len(rows) do finish(a, strings.concatenate({"url:", rows[m.si].url}))
	case .Calc:
		q := q_of(a)
		out, ok := logic.calc_eval(q)
		if !ok do return
		copy_to_clipboard(out)
		inject_at(&m.history, 0, [2]string{strings.clone(q), strings.clone(out)})
		if len(m.history) > 5 do resize(&m.history, 5)
		m.toast = fmt.aprintf("Copied  %s", out)
	case .Confirm:
		if m.cf == 0 do menu_confirmed(a)
		else do menu_back(a)
	}
}

@(private)
run_action :: proc(a: ^App, sec, idx: int) {
	m := a.menu
	act := m.sections[sec].actions[idx]
	m.toast = ""
	switch {
	case act.view != "":
		for s, i in m.sections do if s.kind != .Section && s.id == act.view {
			if m.focus != .Sub || m.open != sec { m.focus, m.open, m.cur = .Sub, sec, root(m, sec); menu_refilter(a) }
			for v, j in m.sel_actions do if v == idx { m.si = j; break }
			page_open(a, i)
			return
		}
		m.open, m.cur = sec, root(m, sec)
		pos := 0
		for v, i in m.sel_actions do if v == idx { pos = i; break }
		menu_open_view(a, act.view, pos)
	case act.jump != "":
		for s, i in m.sections do if s.id == act.jump { menu_enter(a, i); return }
	case act.confirm_title != "":
		m.confirm_from = m.focus
		m.pending = Result{sec, idx}
		m.focus, m.cf = .Confirm, 1
	case:
		execute(a, sec, idx)
	}
}

// Runs the action: "stay" ones in the background through R (the menu stays open and
// reloads), the rest by printing the id and closing.
@(private)
execute :: proc(a: ^App, sec, idx: int) {
	m := a.menu
	act := m.sections[sec].actions[idx]
	if act.id == "k4:retry" {
		if m.open >= 0 && m.open < len(m.sections) && m.sections[m.open].load.cmd != "" {
			loader_restart(m, &m.sections[m.open].load)
			m.toast = "Retrying…"
			menu_refilter(a)
		}
		return
	}
	if !act.stay || m.run_cmd == "" { finish(a, act.id); return }
	if act.input { enter_input(a, act.id, act.label, act.input_prompt, act.input_hint, act.input_password); return }
	if len(act.choices) > 0 do start_runner(a, act.id, "K4_VALUE", act.meta, fmt.aprintf("%s  %s", act.label, act.meta))
	else if act.slider do start_runner(a, act.id, "K4_VALUE", fmt.tprintf("%d", act.value), fmt.aprintf("%s  %d%%", act.label, act.value))
	else do start_runner(a, act.id, "", "", strings.concatenate({act.label, "  …"}))
}

// Runs R <id> in the background, one at a time. key=value goes in the runner's environment
// (not its command line, where other users could read a typed password).
@(private)
start_runner :: proc(a: ^App, id, key, value, toast: string) {
	m := a.menu
	if m.run_cmd == "" || m.runner.state == .Loading do return
	m.runner = Loader{cmd = strings.concatenate({m.run_cmd, " ", sh_quote(id)}), state = .Lazy}
	if key != "" do _ = os.set_env(key, value)
	saved := m.loading // the runner skips the section-loader cap, but counts while it runs
	m.loading = 0
	loader_start(m, &m.runner)
	m.loading = saved + (m.runner.state == .Loading ? 1 : 0)
	if key != "" do os.unset_env(key)
	m.toast = toast
}

@(private)
sh_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`)
	return strings.concatenate({"'", q, "'"})
}

// The text step of an input= action or a k4:input directive: the header field takes the text.
@(private)
enter_input :: proc(a: ^App, id, label, prompt, hint: string, password: bool) {
	m := a.menu
	if m.focus != .Input do m.input_from, m.input_from_si = m.focus, m.si
	m.input_id, m.input_label = strings.clone(id), strings.clone(label)
	m.input_prompt, m.input_hint = strings.clone(prompt != "" ? prompt : label), strings.clone(hint)
	m.input_password = password
	m.focus = .Input
	clear_query(a)
	menu_refilter(a)
}

@(private)
leave_input :: proc(a: ^App) {
	m := a.menu
	m.focus = m.input_from == .Input ? .Sub : m.input_from
	clear_query(a)
	menu_refilter(a)
	n := menu_list_len(a)
	m.si = n > 0 ? clamp(m.input_from_si, 0, n - 1) : 0
}

// ← → on a slider row: move the value now, apply it in the background (coalescing repeats).
@(private)
slide :: proc(a: ^App, d: int) -> bool {
	m := a.menu
	sec, idx := -1, -1
	if m.focus == .Sub && m.si < len(m.sel_actions) do sec, idx = m.open, m.sel_actions[m.si]
	else if searching(m, a) && m.si < len(m.results) && m.results[m.si].act >= 0 do sec, idx = m.results[m.si].sec, m.results[m.si].act
	if sec < 0 do return false
	act := &m.sections[sec].actions[idx]
	if len(act.choices) > 0 {
		// a choice stepper: ‹ value ›, wrapping
		cur := 0
		for c, i in act.choices do if c == act.meta { cur = i; break }
		n := len(act.choices)
		act.meta = act.choices[((cur + d) % n + n) % n]
	} else {
		if !act.slider do return false
		step := act.step > 0 ? act.step : 5
		nv := clamp(act.value + d * step, 0, 100)
		if nv == act.value do return true
		act.value = nv
	}
	if m.runner.state == .Loading {
		m.slide_pending, m.slide_sec, m.slide_act = true, sec, idx
		m.toast = len(act.choices) > 0 ? fmt.aprintf("%s  %s", act.label, act.meta) : fmt.aprintf("%s  %d%%", act.label, act.value)
	} else {
		execute(a, sec, idx)
	}
	return true
}

@(private)
menu_confirmed :: proc(a: ^App) {
	m := a.menu
	p := m.pending
	act := m.sections[p.sec].actions[p.act]
	m.toast = strings.concatenate({"Confirmed  ", m.sections[p.sec].name, " › ", act.label})
	menu_leave_confirm(a)
	execute(a, p.sec, p.act)
}

@(private)
menu_leave_confirm :: proc(a: ^App) {
	m := a.menu
	p := m.pending
	if m.confirm_from == .Sub || m.confirm_from == .Confirm {
		m.focus, m.open, m.cur = .Sub, p.sec, root(m, p.sec)
		clear_query(a)
		menu_refilter(a)
		for v, i in m.sel_actions do if v == p.act { m.si = i; break }
	} else {
		m.focus = m.confirm_from
		menu_refilter(a)
	}
}

@(private)
finish :: proc(a: ^App, id: string) {
	a.result = id
	a.exit = 0
	a.done = true
}

@(private)
copy_to_clipboard :: proc(s: string) {
	r, w, err := os.pipe()
	if err != nil do return
	p, perr := os.process_start({command = {"wl-copy"}, stdin = r})
	os.close(r)
	if perr == nil {
		os.write(w, transmute([]u8)s)
		os.close(w)
		_, _ = os.process_wait(p)
	} else {
		os.close(w)
	}
}

menu_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := a.menu
	empty := len(a.query) == 0
	if m.focus == .Confirm {
		switch {
		case text == "y" || text == "Y": menu_confirmed(a)
		case text == "n" || text == "N" || k == .Escape || k == .Backspace: menu_back(a)
		case k == .Left || k == .Right || k == .Tab || k == .Back_Tab || text == "h" || text == "l": m.cf = 1 - m.cf
		case k == .Enter: menu_run(a)
		case: return false
		}
		return true
	}
	if m.focus == .Input {
		switch {
		case k == .Enter: menu_run(a)
		case k == .Escape: menu_back(a)
		case k == .Backspace && empty: menu_back(a)
		case ctrl && (ch == 'c' || ch == 'g'): a.exit = 1; a.done = true
		case k == .Up || k == .Down || k == .Tab || k == .Back_Tab || k == .Page_Up || k == .Page_Down || alt:
		case: return app_edit_key(a, k, ctrl, ch, text)
		}
		return true
	}
	if alt && ch != 0 {
		up := strings.to_upper(utf8.runes_to_string({ch}, context.temp_allocator), context.temp_allocator)
		for s, i in m.sections do if s.key == up { menu_enter(a, i); return true }
		return false
	}
	// shortcut mode: one keystroke per step, the query is not used
	if m.shortcut && (m.focus == .Menu || m.focus == .Sub) {
		switch {
		case k == .Escape:
			if m.focus == .Sub do menu_back(a)
			else { a.exit = 1; a.done = true }
		case k == .Tab || text == "/":
			m.shortcut = false; menu_refilter(a)
		case (k == .Left || k == .Right) && m.focus == .Sub && slide(a, k == .Left ? -1 : 1):
		case k == .Backspace || k == .Left:
			if m.focus == .Sub do menu_back(a)
		case k == .Down || text == "j": menu_move(a, 1)
		case k == .Up || text == "k": menu_move(a, -1)
		case k == .Enter || k == .Right: menu_run(a)
		case m.focus == .Sub && len(text) == 1 && text[0] >= '1' && text[0] <= '9':
			n := int(text[0] - '1')
			if n < len(m.sel_actions) { m.si = n; menu_run(a) }
		case m.focus == .Sub && len(text) == 1 && action_by_key(m, text) >= 0:
			m.si = action_by_key(m, text)
			menu_run(a)
		case m.focus == .Menu && len(text) == 1 && (text[0] >= 'a' && text[0] <= 'z' || text[0] >= 'A' && text[0] <= 'Z'):
			up := strings.to_upper(text, context.temp_allocator)
			for s, i in m.sections do if s.key == up { menu_enter(a, i); break }
		case: return false
		}
		return true
	}
	if ctrl {
		switch ch {
		case 'j', 'n': menu_move(a, m.focus == .View && m.views[m.view].grid ? 4 : 1); return true
		case 'k', 'p': menu_move(a, m.focus == .View && m.views[m.view].grid ? -4 : -1); return true
		case 'c', 'g': a.exit = 1; a.done = true; return true
		}
		return app_edit_key(a, k, ctrl, ch, text)
	}
	grid := m.focus == .View && m.views[m.view].grid
	if grid && (k == .Left || k == .Right) { menu_move(a, k == .Left ? -1 : 1); return true }
	if k == .Tab && m.focus == .View && m.si < len(m.shown_items) {
		it := m.views[m.view].items[m.shown_items[m.si]]
		if it.alt_id != "" { finish(a, it.alt_id); return true }
	}
	if k == .Tab && m.focus == .Sub && m.sections[m.open].query_id != "" {
		// Tab steps the first choice row (Ollama's model)
		for v, i in m.sel_actions do if len(m.sections[m.open].actions[v].choices) > 0 {
			m.si = i
			slide(a, 1)
			return true
		}
	}
	if (k == .Left || k == .Right) && (m.focus == .Sub || searching(m, a)) && slide(a, k == .Left ? -1 : 1) do return true
	switch k {
	case .Down: menu_move(a, grid ? 4 : 1)
	case .Up: menu_move(a, grid ? -4 : -1)
	case .Tab: menu_move(a, 1)
	case .Back_Tab: menu_move(a, -1)
	case .Page_Down: menu_move(a, 8)
	case .Page_Up: menu_move(a, -8)
	case .Enter: menu_run(a)
	case .Escape:
		if m.focus == .Menu { m.shortcut = true; clear_query(a); m.toast = ""; m.si = 0; menu_refilter(a) }
		else do menu_back(a)
	case .Right:
		if m.focus == .Menu && !searching(m, a) { menu_run(a); return true }
		return app_edit_key(a, k, ctrl, ch, text)
	case .Left:
		if m.focus == .Sub && empty { menu_back(a); return true }
		return app_edit_key(a, k, ctrl, ch, text)
	case .Backspace:
		if m.focus != .Menu && empty { menu_back(a); return true }
		return app_edit_key(a, k, ctrl, ch, text)
	case .Home, .End, .Delete, .None:
		return app_edit_key(a, k, ctrl, ch, text)
	}
	return true
}

// The selectable row whose key= letter is text (shortcut mode), as an index into sel_actions.
@(private)
action_by_key :: proc(m: ^Menu, text: string) -> int {
	up := strings.to_upper(text, context.temp_allocator)
	for v, i in m.sel_actions do if m.sections[m.open].actions[v].key == up do return i
	return -1
}

// ---------- drawing ----------

mix :: proc(a, b: u32, t: f32) -> u32 {
	ch :: proc(a, b: u32, sh: u32, t: f32) -> u32 {
		x, y := f32(a >> sh & 0xff), f32(b >> sh & 0xff)
		return u32(x + (y - x) * t + 0.5) << sh
	}
	return ch(a, b, 16, t) | ch(a, b, 8, t) | ch(a, b, 0, t)
}

@(private) tw :: proc(f: ^Font, s: string) -> int { return int(math.ceil(shape(f, s).width)) }

// Text vertically centred in a box [y, y+h).
@(private)
text_in :: proc(cv: ^Canvas, f: ^Font, s: string, x, y, h: int, color: u32, clip := max(int)) {
	draw_text_f(cv, f, s, x, y + (h - int(f.line_h)) / 2, color, nil, 0, clip)
}

@(private)
kbd :: proc(cv: ^Canvas, a: ^App, label: string, x, cy, S: int) -> int {
	m := a.menu
	t := a.theme
	w := tw(m.f_tiny, label) + 12 * S
	h := 18 * S
	rounded_rect(cv, x, cy - h / 2, w, h, 0, argb(mix(t.bg, t.fg, 0.07), 0xff), f32(S), argb(mix(t.bg, t.fg, 0.18), 0xff))
	text_in(cv, m.f_tiny, label, x + 6 * S, cy - h / 2, h, argb(t.fg, 0xff))
	return w
}

// A small square badge (key letter, action number), centred text.
@(private)
badge :: proc(cv: ^Canvas, f: ^Font, label: string, x_right, y, h, S: int, bg_c, fg_c: u32, filled: bool) -> int {
	w := max(18 * S, tw(f, label) + 6 * S)
	bh := 18 * S
	x := x_right - w
	by := y + (h - bh) / 2
	if filled do fill_rect(cv, x, by, w, bh, argb(bg_c, 0xff))
	text_in(cv, f, label, x + (w - tw(f, label)) / 2, by, bh, argb(fg_c, 0xff))
	return w
}

menu_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	sep := argb(mix(bg, fg, 0.12), 0xff)
	B := 2 * S
	canvas_clear(cv)
	rounded_rect(cv, 0, 0, cv.w, cv.h, 0, argb(bg, 0xf2), f32(B), argb(acc, 0xff))
	x0, x1 := B, cv.w - B
	y := B
	sc := m.shortcut && (m.focus == .Menu || m.focus == .Sub)
	pv := m.focus == .Menu ? m.cur : m.open
	pv_name := pv < len(m.sections) ? m.sections[pv].name : ""

	// ---- header: crumb · query · count
	hh := 56 * S
	srch := searching(m, a)
	crumb, ph, count := menu_header(a, sc)
	cx := x0 + 16 * S
	cw := tw(m.f_small, crumb) + 16 * S
	chh := 24 * S
	fill_rect(cv, cx, y + (hh - chh) / 2, cw, chh, argb(acc, 0xff))
	text_in(cv, m.f_small, crumb, cx + 8 * S, y + (hh - chh) / 2, chh, argb(bg, 0xff))
	qx := cx + cw + 12 * S
	cnt_w := count != "" ? tw(m.f_small, count) : 0
	if cnt_w > 0 do text_in(cv, m.f_small, count, x1 - 16 * S - cnt_w, y, hh, argb(dim, 0xff))
	qclip := x1 - 16 * S - cnt_w - 12 * S
	q := string(a.query[:])
	if m.focus == .Input && m.input_password do q = strings.repeat("•", utf8.rune_count_in_string(q), context.temp_allocator)
	if q == "" do text_in(cv, m.f_big, ph, qx, y, hh, argb(dim, 0xff), qclip)
	else do text_in(cv, m.f_big, q, qx, y, hh, argb(fgb, 0xff), qclip)
	if !sc && m.focus != .Confirm {
		qs := shape(m.f_big, q)
		cur_cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
		caret := qx + int(qs.cp_x[min(cur_cp, len(qs.cp_x) - 1)])
		fill_rect(cv, caret, y + (hh - int(m.f_big.line_h)) / 2, max(S, 2), int(m.f_big.line_h), argb(acc, 0xff))
	}
	y += hh
	fill_rect(cv, x0, y, x1 - x0, S, sep)
	y += S

	// ---- footer: key hints (or a toast) · brand
	fh := 40 * S
	fy := cv.h - B - fh
	fill_rect(cv, x0, fy, x1 - x0, S, sep)
	if m.toast != "" {
		text_in(cv, m.f_small, m.toast, x0 + 16 * S, fy, fh, argb(acc, 0xff), x1 - 60 * S)
	} else {
		hints := menu_hints(a, sc)
		hx := x0 + 16 * S
		for h in hints {
			hx += kbd(cv, a, h[0], hx, fy + fh / 2, S) + 6 * S
			text_in(cv, m.f_small, h[1], hx, fy, fh, argb(dim, 0xff))
			hx += tw(m.f_small, h[1]) + 16 * S
		}
	}
	text_in(cv, m.f_small, "k4", x1 - 16 * S - tw(m.f_small, "k4"), fy, fh, argb(acc, 0xff))

	body := [4]int{x0, y, x1 - x0, fy - y}
	switch m.focus {
	case .Menu, .Sub:
		switch {
		case srch: draw_results(a, cv, S, body)
		case m.focus == .Sub && is_page(m, m.open) && m.sections[m.open].kind == .Font: draw_font(a, cv, S, body)
		case m.focus == .Sub && is_page(m, m.open) && !m.sections[m.open].pane: draw_page(a, cv, S, body, sc)
		case: draw_panes(a, cv, S, body, sc)
		}
	case .Confirm: draw_confirm(a, cv, S, body)
	case .Input: draw_input(a, cv, S, body)
	case .View: draw_view(a, cv, S, body)
	case .Web: draw_web(a, cv, S, body)
	case .Calc: draw_calc(a, cv, S, body)
	}
}

// The header's crumb, placeholder and count for the current state (drawn, and --dump).
menu_header :: proc(a: ^App, sc: bool) -> (crumb, ph, count: string) {
	m := a.menu
	pv := m.focus == .Menu ? m.cur : m.open
	pv_name := pv < len(m.sections) ? m.sections[pv].name : ""
	srch := searching(m, a)
	switch m.focus {
	case .Menu:
		crumb = sc ? "SHORTCUTS" : (srch ? "SEARCH" : (m.top_crumb != "" ? m.top_crumb : "MENU"))
		ph = sc ? "Press a letter   / to search" : (m.top_ph != "" ? m.top_ph : "Search apps and actions…")
		count = sc ? "" : (srch ? fmt.tprintf("%d result%s", len(m.results), len(m.results) == 1 ? "" : "s") : (m.top_count != "" ? m.top_count : fmt.tprintf("%d sections", len(m.shown_sections))))
	case .Confirm:
		crumb = "CONFIRM"
	case .Sub:
		s := &m.sections[m.open]
		if is_page(m, m.open) {
			pg := m.sections[m.open]
			parent := pg.back >= 0 && pg.back < len(m.sections) ? pg.back : root(m, m.open)
			crumb = strings.to_upper(fmt.tprintf("%s › %s", m.sections[parent].name, pg.name), context.temp_allocator)
			noun := page_noun(pg)
			ph = sc ? "Press a number   / to filter" : fmt.tprintf("Filter %s…", noun)
			count = sc ? "" : fmt.tprintf("%d %s", len(m.sel_actions), page_noun(pg, len(m.sel_actions)))
		} else {
			top := m.top_crumb != "" ? m.top_crumb : "MENU"
			crumb = fmt.tprintf("%s › %s", sc ? "SHORTCUTS" : top, strings.to_upper(pv_name, context.temp_allocator))
			ph = sc ? "Press a number   / to search" : fmt.tprintf("Search %s…", pv_name)
			count = sc ? "" : fmt.tprintf("%d action%s", len(m.sel_actions), len(m.sel_actions) == 1 ? "" : "s")
		}
		if !sc {
			if s.ph != "" do ph = s.ph
			if s.has_d do count = s.count
			if section_slow(m, s) do count = fmt.tprintf("waiting %d s", int(time.duration_seconds(time.tick_since(s.load.started))))
		}
	case .Input:
		crumb = strings.to_upper(m.input_prompt, context.temp_allocator)
		ph = m.input_password ? "Password" : "Type here"
		count = "Enter to submit"
	case .View:
		v := m.views[m.view]
		crumb = strings.to_upper(fmt.tprintf("%s › %s", pv_name, v.title), context.temp_allocator)
		// a plural view name says what the items are (games); else the title (Theme -> themes)
		plural := strings.has_suffix(v.name, "s") ? v.name : strings.to_lower(v.title, context.temp_allocator)
		if !strings.has_suffix(plural, "s") do plural = strings.concatenate({plural, "s"}, context.temp_allocator)
		ph = fmt.tprintf("Filter %s…", plural)
		count = fmt.tprintf("%d %s", len(m.shown_items), plural)
	case .Web:
		crumb, ph = "g DUCKDUCKGO", "Search the web…"
		count = q_of(a) != "" ? "Enter to open" : ""
	case .Calc:
		crumb, ph = "= CALC", "sqrt(2) * 15"
	}
	return
}

// The footer's key hints for the current state (drawn, and --dump).
menu_hints :: proc(a: ^App, sc: bool) -> (hints: [][2]string) {
	m := a.menu
	srch := searching(m, a)
	switch {
	case sc && m.focus == .Menu: hints = {{"a–z", "Open"}, {"j k", "Move"}, {"/", "Search"}, {"Esc", "Close"}}
	case sc: hints = {{"1–9", "Run"}, {"j k", "Move"}, {"⌫", "Back"}, {"/", "Search"}}
	case m.focus == .Confirm: hints = {{"y", "Yes"}, {"n Esc", "No"}, {"← →", "Choose"}}
	case m.focus == .Input: hints = {{"↵", "Submit"}, {"Esc", "Cancel"}}
	case m.focus == .Sub && !sc && is_page(m, m.open) && m.sections[m.open].kind == .Font: hints = {{"↑↓", "Preview"}, {"↵", "Apply font"}, {"⌫", "Back"}}
	case m.focus == .Sub && !sc && len(m.sections[m.open].hints) > 0: hints = m.sections[m.open].hints[:]
	case m.focus == .Menu && !sc && m.top_crumb != "":
		keys := make([dynamic]string, 0, 8, context.temp_allocator)
		for i in m.shown_sections do if m.sections[i].key != "" do append(&keys, strings.to_lower(m.sections[i].key, context.temp_allocator))
		hints = {{"↑↓", "Move"}, {"→ ↵", "Open"}, {"Esc", fmt.tprintf("Shortcuts %s", strings.join(keys[:], " ", context.temp_allocator))}}
	case m.focus == .View && view_alt_label(m) != "": hints = {{"←→↑↓", "Move"}, {"↵", "Launch"}, {"Tab", view_alt_label(m)}, {"⌫", "Back"}}
	case srch: hints = {{"↑↓", "Move"}, {"↵", "Run"}, {"Esc", "Shortcuts"}}
	case m.focus == .Menu: hints = {{"↑↓", "Move"}, {"→ ↵", "Open"}, {"type", "Search all"}, {"Esc", "Shortcuts"}}
	case m.focus == .Sub && on_slider(m): hints = {{"↑↓", "Move"}, {"← →", "Adjust"}, {"⌫", "Back"}, {"⌃J ⌃K", "Vim"}}
	case m.focus == .Sub: hints = {{"↑↓", "Move"}, {"↵", "Run"}, {"← ⌫", "Back"}, {"⌃J ⌃K", "Vim"}}
	case m.focus == .Web: hints = {{"↑↓", "Bang"}, {"↵", "Open in browser"}, {"⌫", "Exit mode"}}
	case m.focus == .Calc: hints = {{"↵", "Copy result"}, {"⌫", "Exit mode"}, {"Esc", "Back"}}
	case m.views[m.view].name == "wall": hints = {{"←→↑↓", "Move"}, {"↵", "Set background"}, {"⌫", "Back"}}
	case m.views[m.view].name == "theme": hints = {{"↑↓", "Move"}, {"↵", "Apply theme"}, {"⌫", "Back"}}
	case m.views[m.view].grid: hints = {{"←→↑↓", "Move"}, {"↵", "Open"}, {"⌫", "Back"}}
	case: hints = {{"↑↓", "Move"}, {"↵", "Open"}, {"⌫", "Back"}}
	}
	// the literals above live in this frame: hand out a copy
	out := make([][2]string, len(hints), context.temp_allocator)
	copy(out, hints)
	return out
}

@(private)
on_slider :: proc(m: ^Menu) -> bool {
	return m.focus == .Sub && m.si < len(m.sel_actions) && m.sections[m.open].actions[m.sel_actions[m.si]].slider
}

@(private)
draw_panes :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int, sc: bool) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	x1, fy := x0 + bw, by + bh
	lw := 250 * S
	fill_rect(cv, x0 + lw, by, S, bh, argb(mix(bg, fg, 0.12), 0xff))

	// left: sections (a group= flag starts a heading: "Not installed")
	ry, rh := by + 6 * S, 28 * S
	// every section stays visible (the design: nothing scrolls): rows give up a little height
	groups := 0
	{ g := ""; for i in m.shown_sections do if m.sections[i].group != g { g = m.sections[i].group; if g != "" do groups += 1 } }
	need := len(m.shown_sections) * rh + groups * (18 * S + int(m.f_tiny.line_h))
	if need > bh - 12 * S && len(m.shown_sections) > 0 do rh = max(22 * S, (bh - 12 * S - groups * (18 * S + int(m.f_tiny.line_h))) / len(m.shown_sections))
	if len(m.shown_sections) == 0 do text_in(cv, m.f_body, "No match", x0 + 14 * S, ry + 4 * S, rh, argb(dim, 0xff))
	group := ""
	for i in m.shown_sections {
		if ry + rh > fy do break
		s := m.sections[i]
		if s.group != group {
			group = s.group
			if group != "" {
				ry += 14 * S
				draw_text_f(cv, m.f_tiny, strings.to_upper(group, context.temp_allocator), x0 + 14 * S, ry, argb(dim, 0xff))
				ry += int(m.f_tiny.line_h) + 4 * S
			}
		}
		on := i == (m.focus == .Menu ? m.cur : root(m, m.open))
		strong := on && m.focus == .Menu
		col := s.dim ? mix(bg, fg, 0.3) : fg
		if strong { fill_rect(cv, x0, ry, lw, rh, argb(acc, 0xff)); col = bg }
		else if on { fill_rect(cv, x0, ry, lw, rh, argb(t.selection, 0xff)); col = s.dim ? mix(bg, fg, 0.45) : fgb }
		tx := x0 + 14 * S
		if s.icon != "" do text_in(cv, m.f_body, s.icon, tx, ry, rh, argb(col, 0xff))
		tx += 15 * S + 12 * S
		key := sc ? strings.to_lower(s.key, context.temp_allocator) : s.key
		kbg, kfg := sc ? (strong ? bg : acc) : bg, sc ? (strong ? acc : bg) : (strong ? bg : dim)
		kw := badge(cv, m.f_tiny, key, x0 + lw - 14 * S, ry, rh, S, kbg, kfg, sc)
		text_in(cv, m.f_body, s.name, tx, ry, rh, argb(col, 0xff), x0 + lw - 14 * S - kw - 8 * S)
		ry += rh
	}

	// right: title, Alt+key, description, actions
	pv := m.focus == .Menu ? m.cur : m.open
	if pv < 0 || pv >= len(m.sections) do return
	s := &m.sections[pv]
	px := x0 + lw + S
	py := by + 16 * S
	tf := m.f_title
	draw_text_f(cv, tf, s.name, px + 20 * S, py, argb(m.focus == .Sub ? acc : fgb, 0xff))
	if s.key != "" {
		hint := sc ? fmt.tprintf("press %s", strings.to_lower(s.key, context.temp_allocator)) : fmt.tprintf("Alt+%s", s.key)
		draw_text_f(cv, m.f_tiny, hint, px + 20 * S + tw(tf, s.name) + 12 * S, py + int(tf.ascent - m.f_tiny.ascent), argb(dim, 0xff))
	}
	py += int(tf.line_h) + 4 * S
	desc := section_slow(m, s) ? fmt.tprintf("Still waiting on %s", s.name) : s.desc
	if desc != "" {
		draw_text_f(cv, m.f_small, ellipsize(m.f_small, desc, x1 - 20 * S - (px + 20 * S)), px + 20 * S, py, argb(dim, 0xff))
		py += int(m.f_small.line_h) + 8 * S
	}
	tip_h := m.focus == .Menu && !sc && q_of(a) == "" ? 28 * S : 0
	bottom := fy - 8 * S - tip_h
	draw_actions(a, cv, S, s, px, py, x1, bottom, sc)
	if tip_h > 0 {
		tx := px + 20 * S
		ty := fy - 8 * S - tip_h
		tips := [][2]string{{"g␣", " DuckDuckGo"}, {"=", " Calculator"}, {"Esc", " Shortcuts"}}
		for tip in tips {
			text_in(cv, m.f_small, tip[0], tx, ty, tip_h, argb(acc, 0xff)); tx += tw(m.f_small, tip[0])
			text_in(cv, m.f_small, tip[1], tx, ty, tip_h, argb(dim, 0xff)); tx += tw(m.f_small, tip[1]) + 20 * S
		}
	}
}

// Theme colour for a tone name used by the integration lines.
@(private)
tone_color :: proc(t: logic.Theme, tone: string, def: u32) -> u32 {
	switch tone {
	case "accent": return t.accent
	case "red": return t.red
	case "muted": return t.fg_dim
	case "dim": return mix(t.fg_dim, t.fg, 0.5)
	case "faint": return mix(t.bg, t.fg, 0.3)
	case "fg": return t.fg_bright
	}
	return def
}

// Height of one entry of a section's body.
@(private)
entry_h :: proc(m: ^Menu, act: Action, S: int) -> int {
	switch act.kind {
	case .Row, .Empty: return 30 * S
	case .Heading: return 10 * S + int(m.f_tiny.line_h) + 4 * S
	case .Notice: return 8 * S + 12 * S + int(m.f_bold13.line_h) + 4 * S + int(m.f_small.line_h) + 12 * S + 8 * S
	case .Bars: return act.bars * 30 * S
	case .Card: return 6 * S + 2 * 14 * S + card_inner_h(m, S) + 8 * S
	case .Progress: return 7 * S + int(m.f_body.line_h) + 7 * S + 4 * S + 9 * S
	}
	return 30 * S
}

@(private)
card_inner_h :: proc(m: ^Menu, S: int) -> int {
	text := int(m.f_bold11.line_h) + int(m.f_title.line_h) + int(m.f_small.line_h) + int(m.f_tiny.line_h) + 3 * 3 * S
	return max(64 * S, text)
}

// The rows of a section or page, from y=py down to bottom; px is the left edge of the
// highlight, text starts 20 px in. Headings carry count badges; rows a mark, thumbnail, sub
// text, chip and meta (or a slider / ‹ choice ›); notices, cards, progress and loading bars
// sit between them.
@(private)
draw_actions :: proc(a: ^App, cv: ^Canvas, S: int, s: ^Section, px, py_, x1, bottom: int, sc: bool) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	faint := mix(bg, fg, 0.3)
	py := py_
	ah := 30 * S
	if s.load.state == .Failed && len(s.actions) == 0 {
		text_in(cv, m.f_body, "Could not load this section", px + 20 * S, py, ah, argb(dim, 0xff))
		return
	} else if len(m.shown_actions) == 0 && s.load.state != .Ready {
		text_in(cv, m.f_body, "Loading…", px + 20 * S, py, ah, argb(dim, 0xff))
		return
	} else if len(m.shown_actions) == 0 {
		text_in(cv, m.f_body, len(s.actions) == 0 ? "Nothing here" : "No match", px + 20 * S, py, ah, argb(dim, 0xff))
		return
	}
	// scroll (in entries) keeps the selected row visible
	sel_entry := -1
	if m.focus == .Sub && m.si < len(m.sel_actions) {
		for e, i in m.shown_actions do if e == m.sel_actions[m.si] { sel_entry = i; break }
	}
	if m.focus != .Sub do m.scroll = 0
	m.scroll = clamp(m.scroll, 0, max(len(m.shown_actions) - 1, 0))
	if sel_entry >= 0 {
		if sel_entry < m.scroll do m.scroll = sel_entry
		for m.scroll > 0 && sel_entry == m.scroll && s.actions[m.shown_actions[m.scroll - 1]].heading {
			// keep the heading (and a notice above it) with the first row
			h := 0
			for e in m.scroll - 1 ..= sel_entry do h += entry_h(m, s.actions[m.shown_actions[e]], S)
			if py + h > bottom do break
			m.scroll -= 1
		}
		for {
			h := 0
			for e in m.scroll ..= sel_entry do h += entry_h(m, s.actions[m.shown_actions[e]], S)
			if py + h <= bottom || m.scroll >= sel_entry do break
			m.scroll += 1
		}
	}
	mx := px + 20 * S
	row := 0
	for e in 0 ..< len(m.shown_actions) {
		act := s.actions[m.shown_actions[e]]
		if !act.heading do row += 1
		if e < m.scroll do continue
		h := entry_h(m, act, S)
		if py + h > bottom do break
		switch act.kind {
		case .Heading:
			label := strings.to_upper(act.label, context.temp_allocator)
			draw_text_f(cv, m.f_tiny, label, mx, py + 10 * S, argb(dim, 0xff), nil, 0, x1 - 20 * S)
			if act.count != "" {
				bx := mx + tw(m.f_tiny, label) + 8 * S
				bw := tw(m.f_tiny, act.count) + 10 * S
				bh := 16 * S
				by := py + 10 * S + (int(m.f_tiny.line_h) - bh) / 2
				zero := act.count == "0"
				fill_rect(cv, bx, by, bw, bh, argb(zero ? t.selection : acc, 0xff))
				text_in(cv, m.f_tiny, act.count, bx + 5 * S, by, bh, argb(zero ? dim : bg, 0xff))
			}
		case .Empty:
			text_in(cv, m.f_body, "–", mx + 4 * S, py, ah, argb(faint, 0xff))
			text_in(cv, m.f_body, act.label, mx + 28 * S, py, ah, argb(dim, 0xff), x1 - 20 * S)
		case .Notice:
			tc := tone_color(t, act.tone, acc)
			nx, ny, nw := mx, py + 8 * S, x1 - 20 * S - mx
			nh := h - 16 * S
			rounded_rect(cv, nx, ny, nw, nh, 0, argb(mix(bg, fg, 0.05), 0xff), f32(S), argb(tc, 0xff))
			ty := ny + 12 * S
			draw_text_f(cv, m.f_bold13, "!", nx + 14 * S, ty, argb(tc, 0xff))
			draw_text_f(cv, m.f_bold13, ellipsize(m.f_bold13, act.label, nw - 46 * S), nx + 32 * S, ty, argb(fgb, 0xff))
			ty += int(m.f_bold13.line_h) + 4 * S
			draw_text_f(cv, m.f_small, ellipsize(m.f_small, act.meta, nw - 46 * S), nx + 32 * S, ty, argb(mix(dim, fg, 0.5), 0xff))
		case .Bars:
			inner := x1 - 20 * S - (mx + 28 * S) - 90 * S - 12 * S
			widths := [3]int{62, 44, 70}
			for i in 0 ..< act.bars {
				y := py + i * ah + (ah - 10 * S) / 2
				fill_rect(cv, mx + 2 * S, y, 14 * S, 10 * S, argb(mix(bg, fg, 0.08), 0xff))
				fill_rect(cv, mx + 28 * S, y, inner * widths[i % 3] / 100, 10 * S, argb(mix(bg, fg, 0.08), 0xff))
				fill_rect(cv, x1 - 20 * S - 90 * S, y, 90 * S, 10 * S, argb(mix(bg, fg, 0.05), 0xff))
			}
		case .Card:
			cx, cy, cw := mx, py + 6 * S, x1 - 20 * S - mx
			ch := h - 14 * S
			rounded_rect(cv, cx, cy, cw, ch, 0, argb(mix(bg, fg, 0.05), 0xff), f32(S), argb(mix(bg, fg, 0.18), 0xff))
			g := 64 * S
			gx, gy := cx + 14 * S, cy + (ch - g) / 2
			fill_rect(cv, gx, gy, g, g, argb(act.active ? mix(bg, acc, 0.15) : t.selection, 0xff))
			text_in(cv, m.f_glyph, act.glyph, gx + (g - tw(m.f_glyph, act.glyph)) / 2, gy, g, argb(act.active ? acc : dim, 0xff))
			tx := gx + g + 14 * S
			tw_ := cx + cw - 14 * S - tx
			inner := card_inner_h(m, S)
			text_h := int(m.f_bold11.line_h) + int(m.f_title.line_h) + int(m.f_small.line_h) + int(m.f_tiny.line_h) + 9 * S
			ty := cy + 14 * S + (inner - text_h) / 2
			draw_text_f(cv, m.f_bold11, act.state, tx, ty, argb(act.active ? acc : dim, 0xff))
			ty += int(m.f_bold11.line_h) + 3 * S
			draw_text_f(cv, m.f_title, ellipsize(m.f_title, act.label, tw_), tx, ty, argb(fgb, 0xff))
			ty += int(m.f_title.line_h) + 3 * S
			draw_text_f(cv, m.f_small, ellipsize(m.f_small, act.meta, tw_), tx, ty, argb(mix(dim, fg, 0.5), 0xff))
			ty += int(m.f_small.line_h) + 3 * S
			draw_text_f(cv, m.f_tiny, act.line2, tx, ty, argb(dim, 0xff), nil, 0, tx + tw_)
		case .Progress:
			ty := py + 7 * S
			lh := int(m.f_body.line_h)
			text_in(cv, m.f_body, "↓", mx + 4 * S, ty, lh, argb(acc, 0xff))
			mw := tw(m.f_small, act.meta)
			text_in(cv, m.f_small, act.meta, x1 - 20 * S - mw, ty, lh, argb(dim, 0xff))
			text_in(cv, m.f_body, ellipsize(m.f_body, act.label, x1 - 20 * S - mw - 12 * S - (mx + 26 * S)), mx + 26 * S, ty, lh, argb(fgb, 0xff))
			bx, by := mx + 26 * S, ty + lh + 7 * S
			bw := x1 - 20 * S - bx
			fill_rect(cv, bx, by, bw, 4 * S, argb(mix(bg, fg, 0.18), 0xff))
			if act.pct > 0 do fill_rect(cv, bx, by, max(bw * act.pct / 100, S), 4 * S, argb(acc, 0xff))
		case .Row:
			j := row - 1
			on := m.focus == .Sub && e == sel_entry
			lc := m.focus == .Sub ? fgb : fg
			if act.dim do lc = faint
			mc := tone_color(t, act.metac, dim)
			markc := tone_color(t, act.markc, act.mark != "" ? faint : mix(bg, fg, 0.35))
			subc, chipc := dim, tone_color(t, act.chipc, dim)
			if on {
				fill_rect(cv, px, py, x1 - px, ah, argb(acc, 0xff))
				lc, mc, markc, subc, chipc = bg, bg, bg, bg, bg
			}
			// mark column: shortcut letter or number, a status glyph, or › / »
			badge_label := ""
			if sc && m.focus == .Sub {
				if act.key != "" do badge_label = strings.to_lower(act.key, context.temp_allocator)
				else if j < 9 do badge_label = fmt.tprintf("%d", j + 1)
			}
			if badge_label != "" do badge(cv, m.f_tiny, badge_label, mx + 16 * S, py, ah, S, on ? bg : acc, on ? acc : bg, true)
			else {
				mark := act.mark != "" ? act.mark : (act.view != "" || act.jump != "" ? "»" : "›")
				text_in(cv, m.f_body, mark, mx + (16 * S - tw(m.f_body, mark)) / 2, py, ah, argb(markc, 0xff))
			}
			lx := mx + 16 * S + 12 * S
			right := x1 - 20 * S
			if act.slider {
				sw := draw_slider(a, cv, S, act.value, right, py, ah, on)
				text_in(cv, m.f_body, act.label, lx, py, ah, argb(lc, 0xff), right - sw - 12 * S)
				break
			}
			meta := act.meta
			if len(act.choices) > 0 do meta = fmt.tprintf("‹ %s ›", act.meta)
			if meta == "" && act.confirm_title != "" do meta = "asks first"
			if meta == "" && act.jump != "" do meta = "→"
			if meta != "" {
				meta = ellipsize(m.f_small, meta, (right - lx) * 60 / 100)
				mw := tw(m.f_small, meta)
				text_in(cv, m.f_small, meta, right - mw, py, ah, argb(mc, 0xff))
				right -= mw + 10 * S
			}
			if act.chip != "" {
				cw := tw(m.f_bold10, act.chip) + 10 * S
				chh := 16 * S + 2 * S
				rounded_rect(cv, right - cw, py + (ah - chh) / 2, cw, chh, 0, 0, f32(S), argb(chipc, 0xff))
				text_in(cv, m.f_bold10, act.chip, right - cw + 5 * S, py + (ah - chh) / 2, chh, argb(chipc, 0xff))
				right -= cw + 10 * S
			}
			if act.thumb != "" {
				ts := 22 * S
				ty := py + (ah - ts) / 2
				fill_rect(cv, lx, ty, ts, ts, argb(mix(bg, fg, 0.08), 0xff))
				img := image_cover(a, act.thumb, ts, ts)
				if img.ok do blit_image(cv, img.px, img.w, img.h, lx, ty)
				rounded_rect(cv, lx, ty, ts, ts, 0, 0, f32(S), argb(on ? mix(acc, bg, 0.5) : mix(bg, fg, 0.25), 0xff))
				lx += ts + 10 * S
			}
			label := ellipsize(m.f_body, act.label, right - lx)
			text_in(cv, m.f_body, label, lx, py, ah, argb(lc, 0xff))
			if act.sub != "" && label == act.label {
				sx := lx + tw(m.f_body, label)
				if sx < right do text_in(cv, m.f_body, act.sub, sx, py, ah, argb(subc, 0xff), right)
			}
		}
		py += h
	}
}

// The design's slider: a 120 px track with the accent fill, then the value (36 px, right-aligned).
// Right-aligned at x_right; returns its width.
@(private)
draw_slider :: proc(a: ^App, cv: ^Canvas, S, value, x_right, y, h: int, on: bool) -> int {
	m := a.menu
	t := a.theme
	tw_, th := 120 * S, 4 * S
	vw := 36 * S
	w := tw_ + 10 * S + vw
	x := x_right - w
	cy := y + (h - th) / 2
	track, fill, txt := argb(mix(t.bg, t.fg, 0.18), 0xff), argb(t.accent, 0xff), argb(t.fg, 0xff)
	if on do track, fill, txt = argb(mix(t.accent, t.bg, 0.45), 0xff), argb(t.bg, 0xff), argb(t.bg, 0xff)
	rounded_rect(cv, x, cy, tw_, th, f32(2 * S), track)
	if value > 0 do rounded_rect(cv, x, cy, max(tw_ * value / 100, th), th, f32(2 * S), fill)
	pct := fmt.tprintf("%d%%", value)
	text_in(cv, m.f_small, pct, x_right - tw(m.f_small, pct), y, h, txt)
	return w
}

@(private)
draw_results :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fgb, dim, acc := t.bg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	x1, fy := x0 + bw, by + bh
	py := by + 8 * S
	rh := 34 * S
	if len(m.results) == 0 {
		text_in(cv, m.f_body, "Nothing found. Try g␣ to search the web.", x0 + 20 * S, py, rh, argb(dim, 0xff))
		return
	}
	visible := max((fy - 8 * S - py) / rh, 1)
	if m.si < m.scroll do m.scroll = m.si
	if m.si >= m.scroll + visible do m.scroll = m.si - visible + 1
	for n in m.scroll ..< min(m.scroll + visible, len(m.results)) {
		r := m.results[n]
		sec := m.sections[r.sec]
		on := n == m.si
		lc, mc, tc := fgb, dim, acc
		if on { fill_rect(cv, x0, py, bw, rh, argb(acc, 0xff)); lc, mc, tc = bg, bg, bg }
		label, meta, tag := sec.name, "", "section"
		if r.act >= 0 {
			act := sec.actions[r.act]
			label, meta, tag = act.label, act.meta, sec.name
			if meta == "" && act.confirm_title != "" do meta = "asks first"
		}
		x := x0 + 20 * S
		if sec.icon != "" do text_in(cv, m.f_row, sec.icon, x, py, rh, argb(lc, 0xff))
		x += 15 * S + 12 * S
		tag_x := x1 - 20 * S - 90 * S
		text_in(cv, m.f_tiny, tag, x1 - 20 * S - tw(m.f_tiny, tag), py, rh, argb(tc, 0xff))
		if r.act >= 0 && sec.actions[r.act].slider {
			meta = ""
			sw := draw_slider(a, cv, S, sec.actions[r.act].value, tag_x - 12 * S, py, rh, on)
			text_in(cv, m.f_row, label, x, py, rh, argb(lc, 0xff), tag_x - 24 * S - sw)
			py += rh
			continue
		}
		mw := meta != "" ? tw(m.f_small, meta) : 0
		if mw > 0 do text_in(cv, m.f_small, meta, tag_x - 12 * S - mw, py, rh, argb(mc, 0xff))
		text_in(cv, m.f_row, label, x, py, rh, argb(lc, 0xff), tag_x - 12 * S - mw - (mw > 0 ? 12 * S : 0))
		py += rh
	}
}

@(private)
draw_confirm :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, acc := t.bg, t.fg, t.fg_bright, t.accent
	act := m.sections[m.pending.sec].actions[m.pending.act]
	title_f := m.f_confirm
	w := 380 * S
	pad_x, pad_y, gap := 28 * S, 26 * S, 18 * S
	bh_ := 40 * S
	h := 2 * pad_y + int(title_f.line_h) + gap + int(m.f_body.line_h) + gap + bh_
	x := body[0] + (body[2] - w) / 2
	y := body[1] + (body[3] - h) / 2
	rounded_rect(cv, x, y, w, h, 0, argb(mix(bg, fg, 0.05), 0xff), f32(2 * S), argb(acc, 0xff))
	yy := y + pad_y
	draw_text_f(cv, title_f, act.confirm_title, x + pad_x, yy, argb(fgb, 0xff), nil, 0, x + w - pad_x)
	yy += int(title_f.line_h) + gap
	draw_text_f(cv, m.f_body, act.confirm_body, x + pad_x, yy, argb(fg, 0xff), nil, 0, x + w - pad_x)
	yy += int(m.f_body.line_h) + gap
	bw := (w - 2 * pad_x - 12 * S) / 2
	yes_x, no_x := x + pad_x, x + pad_x + bw + 12 * S
	yes_bg, yes_fg := m.cf == 0 ? argb(acc, 0xff) : 0, m.cf == 0 ? bg : acc
	no_bg, no_fg := m.cf == 1 ? argb(fgb, 0xff) : 0, m.cf == 1 ? bg : fgb
	rounded_rect(cv, yes_x, yy, bw, bh_, 0, yes_bg, f32(S), argb(acc, 0xff))
	rounded_rect(cv, no_x, yy, bw, bh_, 0, no_bg, f32(S), argb(mix(bg, fg, 0.35), 0xff))
	text_in(cv, m.f_bold13, "y  Yes", yes_x + (bw - tw(m.f_bold13, "y  Yes")) / 2, yy, bh_, argb(yes_fg, 0xff))
	text_in(cv, m.f_bold13, "n  No", no_x + (bw - tw(m.f_bold13, "n  No")) / 2, yy, bh_, argb(no_fg, 0xff))
}

@(private)
draw_view :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	x1, fy := x0 + bw, by + bh
	v := &m.views[m.view]
	grid := v.grid
	pad := 20 * S
	py := by + 16 * S
	draw_text_f(cv, m.f_title, v.title, x0 + pad, py, argb(acc, 0xff))
	draw_text_f(cv, m.f_small, v.subtitle, x0 + pad + tw(m.f_title, v.title) + 12 * S, py + int(m.f_title.ascent - m.f_small.ascent), argb(dim, 0xff), nil, 0, x1 - pad)
	py += int(m.f_title.line_h) + (grid ? 12 : 14) * S
	if v.load.state != .Ready {
		text_in(cv, m.f_body, v.load.state == .Failed ? "Could not load" : "Loading…", x0 + pad, py, 34 * S, argb(dim, 0xff))
		return
	}
	if len(m.shown_items) == 0 {
		text_in(cv, m.f_body, "No match", x0 + pad, py, 34 * S, argb(dim, 0xff))
		return
	}
	if grid {
		cols, gx, gy := 4, 14 * S, 18 * S
		tile_w := (bw - 2 * pad - (cols - 1) * gx) / cols
		wide, subs := false, false
		for it in v.items { wide ||= it.wide; subs ||= it.sub != "" }
		tile_h := wide ? tile_w * 215 / 460 : 100 * S // Steam headers are 460×215
		cell_h := tile_h + 8 * S + int(m.f_small.line_h) + (subs ? int(m.f_tiny.line_h) + 2 * S : 0) + gy
		rows_vis := max((fy - 8 * S - py + gy) / cell_h, 1)
		row := m.si / cols
		if row < m.scroll do m.scroll = row
		if row >= m.scroll + rows_vis do m.scroll = row - rows_vis + 1
		for j in m.scroll * cols ..< min((m.scroll + rows_vis) * cols, len(m.shown_items)) {
			it := v.items[m.shown_items[j]]
			c, r := j % cols, j / cols - m.scroll
			tx := x0 + pad + c * (tile_w + gx)
			ty := py + r * cell_h
			on := j == m.si
			if on do rounded_rect(cv, tx - 4 * S, ty - 4 * S, tile_w + 8 * S, tile_h + 8 * S, 0, 0, f32(2 * S), argb(acc, 0xff))
			fill_rect(cv, tx, ty, tile_w, tile_h, argb(mix(bg, fg, 0.08), 0xff))
			if it.image != "" {
				img := image_cover(a, it.image, tile_w, tile_h)
				if img.ok do blit_image(cv, img.px, img.w, img.h, tx, ty)
			}
			ly := ty + tile_h + 8 * S
			tag_w := it.current ? tw(m.f_small, "current") : 0
			draw_text_f(cv, m.f_small, it.label, tx, ly, argb(on ? fgb : fg, 0xff), nil, 0, tx + tile_w - tag_w - 6 * S)
			if it.current do draw_text_f(cv, m.f_small, "current", tx + tile_w - tag_w, ly, argb(acc, 0xff))
			if it.sub != "" do draw_text_f(cv, m.f_tiny, it.sub, tx, ly + int(m.f_small.line_h) + 2 * S, argb(dim, 0xff), nil, 0, tx + tile_w)
		}
		return
	}
	swatches := false
	for it in v.items do if it.has_palette { swatches = true; break }
	rh := (swatches ? 40 : 34) * S
	visible := max((fy - 8 * S - py) / rh, 1)
	if m.si < m.scroll do m.scroll = m.si
	if m.si >= m.scroll + visible do m.scroll = m.si - visible + 1
	for j in m.scroll ..< min(m.scroll + visible, len(m.shown_items)) {
		it := v.items[m.shown_items[j]]
		on := j == m.si
		lc, mc := fgb, dim
		if on { fill_rect(cv, x0, py, bw, rh, argb(acc, 0xff)); lc, mc = bg, bg }
		if swatches {
			// the design's theme row: name · "Aa" in the theme's colours · six swatches · tag (56 px)
			tag_x := x1 - pad - 56 * S
			if it.current do text_in(cv, m.f_small, "current", x1 - pad - tw(m.f_small, "current"), py, rh, argb(mc, 0xff))
			sh := 22 * S
			sy := py + (rh - sh) / 2
			edge := argb(on ? mix(acc, bg, 0.5) : mix(bg, fg, 0.25), 0xff)
			sx := tag_x - 16 * S - 6 * (16 * S + 4 * S) + 4 * S
			if it.has_palette {
				for c in 0 ..< 6 {
					x := sx + c * (16 * S + 4 * S)
					rounded_rect(cv, x, sy, 16 * S, sh, 0, argb(it.palette[2 + c], 0xff), f32(S), edge)
				}
				chip_w := tw(m.f_bold12, "Aa") + 14 * S
				cx := sx - 4 * S - chip_w
				rounded_rect(cv, cx, sy, chip_w, sh, 0, argb(it.palette[0], 0xff), f32(S), edge)
				text_in(cv, m.f_bold12, "Aa", cx + 7 * S, sy, sh, argb(it.palette[1], 0xff))
				sx = cx
			}
			text_in(cv, m.f_row, it.label, x0 + pad, py, rh, argb(lc, 0xff), sx - 16 * S)
			py += rh
			continue
		}
		tag_w := it.current ? tw(m.f_small, "current") : 0
		text_in(cv, m.f_row, it.label, x0 + pad, py, rh, argb(lc, 0xff), x1 - pad - tag_w - 12 * S)
		if it.current do text_in(cv, m.f_small, "current", x1 - pad - tag_w, py, rh, argb(mc, 0xff))
		py += rh
	}
}

// The selected view item's Tab action label ("Store page"), if it has one.
@(private)
view_alt_label :: proc(m: ^Menu) -> string {
	if m.focus != .View || m.si >= len(m.shown_items) do return ""
	return m.views[m.view].items[m.shown_items[m.si]].alt_label
}

// What a page's rows are called in its filter and count: "Wi-Fi networks" → networks,
// "Packages" → packages, anything else → options.
@(private)
page_noun :: proc(pg: Section, n := 2) -> string {
	noun := "options"
	words := strings.fields(strings.to_lower(pg.name, context.temp_allocator), context.temp_allocator)
	if pg.kind == .Font do noun = "fonts"
	else if len(words) > 0 && !strings.contains(pg.name, "&") && strings.has_suffix(words[len(words) - 1], "s") do noun = words[len(words) - 1]
	return n == 1 ? noun[:len(noun) - 1] : noun
}

// A page: title and subtitle like a view, then its rows across the whole width.
@(private)
draw_page :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int, sc: bool) {
	m := a.menu
	t := a.theme
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	x1, fy := x0 + bw, by + bh
	pg := &m.sections[m.open]
	pad := 20 * S
	py := by + 16 * S
	draw_text_f(cv, m.f_title, pg.name, x0 + pad, py, argb(t.accent, 0xff))
	sub := pg.desc
	if section_slow(m, pg) do sub = fmt.tprintf("Still waiting on %s", pg.name)
	else if pg.load.state == .Loading && len(pg.actions) > 0 && pg.load.refresh do sub = "Refreshing…"
	draw_text_f(cv, m.f_small, sub, x0 + pad + tw(m.f_title, pg.name) + 12 * S, py + int(m.f_title.ascent - m.f_small.ascent), argb(t.fg_dim, 0xff), nil, 0, x1 - pad)
	py += int(m.f_title.line_h) + 10 * S
	draw_actions(a, cv, S, pg, x0, py, x1, fy - 8 * S, sc)
}

// The text step: a card with the prompt and its hint; the text goes in the header field.
@(private)
draw_input :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	w := 420 * S
	pad_x, pad_y, gap := 28 * S, 26 * S, 12 * S
	hint := m.input_hint != "" ? m.input_hint : (m.input_password ? "Typed characters are hidden." : "Type in the field above, then press Enter.")
	h := 2 * pad_y + int(m.f_confirm.line_h) + gap + int(m.f_body.line_h)
	x := body[0] + (body[2] - w) / 2
	y := body[1] + (body[3] - h) / 2
	rounded_rect(cv, x, y, w, h, 0, argb(mix(t.bg, t.fg, 0.05), 0xff), f32(2 * S), argb(t.accent, 0xff))
	yy := y + pad_y
	draw_text_f(cv, m.f_confirm, m.input_prompt, x + pad_x, yy, argb(t.fg_bright, 0xff), nil, 0, x + w - pad_x)
	yy += int(m.f_confirm.line_h) + gap
	draw_text_f(cv, m.f_body, hint, x + pad_x, yy, argb(t.fg_dim, 0xff), nil, 0, x + w - pad_x)
}

@(private)
draw_web :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fgb, dim, acc := t.bg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw := body[0], body[1], body[2]
	x1 := x0 + bw
	py := by + 12 * S
	rows := web_rows(a)
	if len(rows) == 0 {
		text_in(cv, m.f_body, "Type a query. Prefix a !bang to search a site directly.", x0 + 20 * S, py, 34 * S, argb(dim, 0xff))
		return
	}
	for r, j in rows {
		h := (j == 0 ? 48 : 36) * S
		on := j == m.si
		lc, tc, mc := fgb, acc, dim
		if on { fill_rect(cv, x0, py, bw, h, argb(acc, 0xff)); lc, tc, mc = bg, bg, bg }
		text_in(cv, m.f_small, r.tag, x0 + 20 * S, py, h, argb(tc, 0xff))
		mw := tw(m.f_small, r.meta)
		text_in(cv, m.f_row, r.label, x0 + 20 * S + 40 * S + 14 * S, py, h, argb(lc, 0xff), x1 - 20 * S - mw - 14 * S)
		text_in(cv, m.f_small, r.meta, x1 - 20 * S - mw, py, h, argb(mc, 0xff))
		py += h
	}
}

@(private)
draw_calc :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	pad := 20 * S
	x, y, w := x0 + pad, by + pad, bw - 2 * pad
	q := q_of(a)
	out, ok := logic.calc_eval(q)
	if !ok do out = q != "" ? "…" : "0"
	box_h := 22 * S * 2 + int(m.f_small.line_h) + 8 * S + int(m.f_huge.line_h)
	rounded_rect(cv, x, y, w, box_h, 0, argb(mix(bg, fg, 0.05), 0xff), f32(S), argb(mix(bg, fg, 0.18), 0xff))
	draw_text_f(cv, m.f_small, q != "" ? q : "Type an expression", x + 24 * S, y + 22 * S, argb(dim, 0xff), nil, 0, x + w - 24 * S)
	draw_text_f(cv, m.f_huge, out, x + 24 * S, y + 22 * S + int(m.f_small.line_h) + 8 * S, argb(ok ? acc : mix(bg, fg, 0.3), 0xff), nil, 0, x + w - 24 * S)
	y += box_h + 14 * S + 6 * S
	draw_text_f(cv, m.f_tiny, "HISTORY", x, y, argb(dim, 0xff))
	y += int(m.f_tiny.line_h) + 14 * S
	if len(m.history) == 0 {
		draw_text_f(cv, m.f_body, "Press Enter to copy a result; it lands here.", x, y, argb(dim, 0xff))
	}
	for h in m.history {
		r := fmt.tprintf("= %s", h[1])
		text_in(cv, m.f_row, h[0], x, y, 26 * S, argb(fg, 0xff), x + w - tw(m.f_row, r) - 12 * S)
		text_in(cv, m.f_row, r, x + w - tw(m.f_row, r), y, 26 * S, argb(fgb, 0xff))
		y += 26 * S
	}
	note := "Supports + − × / ^ % ( ), 0x hex, pi, e, sqrt sin cos tan log ln abs round"
	draw_text_f(cv, m.f_small, note, x, by + bh - pad - int(m.f_small.line_h), argb(dim, 0xff), nil, 0, x + w)
}

// s cut to fit w pixels, with "…" when it had to be cut.
@(private)
ellipsize :: proc(f: ^Font, s: string, w: int) -> string {
	if tw(f, s) <= w do return s
	r := utf8.string_to_runes(s, context.temp_allocator)
	for n := len(r) - 1; n > 0; n -= 1 {
		c := strings.concatenate({strings.trim_right_space(utf8.runes_to_string(r[:n], context.temp_allocator)), "…"}, context.temp_allocator)
		if tw(f, c) <= w do return c
	}
	return "…"
}

// A family's faces for the font page, loaded on first use (bold only for the preview).
@(private)
family_fonts :: proc(a: ^App, family: string, bold: bool) -> ^Family_Fonts {
	m := a.menu
	ff, found := &m.families[family]
	if !found {
		m.families[strings.clone(family)] = {}
		ff = &m.families[family]
		base := new(Font)
		if !font_load(base, family, 16, true) do return ff
		base.fallback = a.font.fallback
		ff.ok = true
		ff.name, ff.sample, ff.line = base, font_sized(base, 12), font_sized(base, 15)
	}
	if bold && ff.ok && ff.title == nil {
		b := new(Font)
		if font_load(b, strings.concatenate({family, ":weight=bold"}, context.temp_allocator), 30, true) {
			b.fallback = a.font.fallback
			ff.title, ff.bold = b, font_sized(b, 15)
		} else {
			ff.title, ff.bold = font_sized(ff.name, 30), ff.line
		}
	}
	return ff
}

// Fonts outside a.fonts follow the buffer scale when they are drawn.
@(private)
at_scale :: proc(f: ^Font, S: int) -> ^Font {
	if f != nil && f.px != f.base_px * f32(S) do font_resize(f, f.base_px * f32(S))
	return f
}

// Design 07b: the families on the left (54 px rows: the name and "0O 1lI {} => != ~/" in
// that font), a preview of the highlighted one on the right.
@(private)
draw_font :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	bg, fg, fgb, dim, acc := t.bg, t.fg, t.fg_bright, t.fg_dim, t.accent
	x0, by, bw, bh := body[0], body[1], body[2], body[3]
	x1, fy := x0 + bw, by + bh
	pg := &m.sections[m.open]
	lw := 330 * S
	fill_rect(cv, x0 + lw, by, S, bh, argb(mix(bg, fg, 0.12), 0xff))
	pad := 20 * S
	if pg.load.state == .Failed || len(m.sel_actions) == 0 {
		msg := pg.load.state == .Failed ? "Could not list the fonts" : (pg.load.state != .Ready ? "Loading…" : (len(pg.actions) == 0 ? "No fonts installed" : "No font matches"))
		text_in(cv, m.f_body, msg, x0 + pad, by + 8 * S, 34 * S, argb(dim, 0xff))
		return
	}
	rh := 54 * S
	py := by + 8 * S
	visible := max((fy - 8 * S - py) / rh, 1)
	if m.si < m.scroll do m.scroll = m.si
	if m.si >= m.scroll + visible do m.scroll = m.si - visible + 1
	m.scroll = clamp(m.scroll, 0, max(len(m.sel_actions) - visible, 0))
	for j in m.scroll ..< min(m.scroll + visible, len(m.sel_actions)) {
		act := pg.actions[m.sel_actions[j]]
		on := j == m.si
		lc, mc := fgb, dim
		if on { fill_rect(cv, x0, py, lw, rh, argb(acc, 0xff)); lc, mc = bg, bg }
		ff := family_fonts(a, act.label, false)
		nf, sf := m.f_row, m.f_small
		if ff.ok do nf, sf = at_scale(ff.name, S), at_scale(ff.sample, S)
		tag := act.current ? "current" : act.meta
		tag_w := tag != "" ? tw(m.f_tiny, tag) : 0
		gap := 3 * S
		top := py + (rh - int(nf.line_h) - gap - int(sf.line_h)) / 2
		draw_text_f(cv, nf, ellipsize(nf, act.label, lw - 2 * pad - (tag_w > 0 ? tag_w + 10 * S : 0)), x0 + pad, top, argb(lc, 0xff))
		if tag_w > 0 do draw_text_f(cv, m.f_tiny, tag, x0 + lw - pad - tag_w, top + int(nf.ascent - m.f_tiny.ascent), argb(mc, 0xff))
		draw_text_f(cv, sf, "0O 1lI {} => != ~/", x0 + pad, top + int(nf.line_h) + gap, argb(mc, 0xff), nil, 0, x0 + lw - pad)
		py += rh
	}

	// preview
	if m.si >= len(m.sel_actions) do return
	name := pg.actions[m.sel_actions[m.si]].label
	ff := family_fonts(a, name, true)
	if !ff.ok {
		text_in(cv, m.f_body, "Cannot load this font", x0 + lw + S + 24 * S, by + 20 * S, 34 * S, argb(dim, 0xff))
		return
	}
	title, line, bold := at_scale(ff.title, S), at_scale(ff.line, S), at_scale(ff.bold, S)
	px, right := x0 + lw + S + 24 * S, x1 - 24 * S
	y := by + 20 * S
	draw_text_f(cv, m.f_tiny, "PREVIEW", px, y, argb(dim, 0xff))
	y += int(m.f_tiny.line_h) + 14 * S
	draw_text_f(cv, title, ellipsize(title, name, right - px), px, y, argb(acc, 0xff), nil, 0, right)
	y += int(title.line_h) + 14 * S
	lh := int(line.line_h * 1.5 / 1.25) // the design's line-height 1.5 at 15 px
	for s in ([]string{"ABCDEFGHIJKLM NOPQRSTUVWXYZ", "abcdefghijklm nopqrstuvwxyz", "0123456789 åäö ÅÄÖ"}) {
		draw_text_f(cv, line, s, px, y, argb(fg, 0xff), nil, 0, right)
		y += lh
	}
	draw_text_f(cv, line, "Regular · ", px, y, argb(mix(fg, bg, 0.2), 0xff), nil, 0, right)
	draw_text_f(cv, bold, "Bold", px + tw(line, "Regular · "), y, argb(fgb, 0xff), nil, 0, right)
	y += lh + 14 * S
	// the sway config it ends up in
	code := at_scale(ff.sample, S)
	cl := int(code.line_h * 1.45)
	box_h := 4 * cl + 28 * S
	if y + box_h > fy - 8 * S do return
	rounded_rect(cv, px, y, right - px, box_h, 0, argb(mix(bg, fg, 0.05), 0xff), f32(S), argb(mix(bg, fg, 0.18), 0xff))
	cx, cy := px + 16 * S, y + 14 * S
	draw_text_f(cv, code, "# ~/.config/sway/config", cx, cy, argb(dim, 0xff), nil, 0, right - 16 * S)
	cy += cl
	draw_text_f(cv, code, "set $mod Mod4", cx, cy, argb(fg, 0xff), nil, 0, right - 16 * S)
	cy += cl
	draw_text_f(cv, code, "font", cx, cy, argb(acc, 0xff))
	draw_text_f(cv, code, fmt.tprintf(" pango:%s 11", name), cx + tw(code, "font"), cy, argb(fg, 0xff), nil, 0, right - 16 * S)
	cy += cl
	draw_text_f(cv, code, "bindsym $mod+Alt+space exec sway-menu", cx, cy, argb(fg, 0xff), nil, 0, right - 16 * S)
}

// ---------- setup ----------

// The menu's sizes of the current font (again after a font change).
menu_fonts :: proc(a: ^App) {
	m := a.menu
	base := &a.font
	clear(&a.fonts)
	m.f_body = font_sized(base, 13)
	m.f_small = font_sized(base, 12)
	m.f_tiny = font_sized(base, 11)
	m.f_big = font_sized(base, 17)
	m.f_row = font_sized(base, 14)
	m.f_huge = font_sized(base, 44)
	m.f_title = font_sized(base, 18)
	m.f_confirm = font_sized(base, 20)
	m.f_glyph = font_sized(base, 26)
	m.f_bold13, m.f_bold12, m.f_bold11, m.f_bold10 = m.f_body, m.f_small, m.f_tiny, font_sized(base, 10)
	if bold, ok := bold_font(a, 18); ok {
		m.f_title = bold
		m.f_confirm = font_sized(bold, 20)
		m.f_bold13 = font_sized(bold, 13)
		m.f_bold12 = font_sized(bold, 12)
		m.f_bold11 = font_sized(bold, 11)
		m.f_bold10 = font_sized(bold, 10)
	}
	append(&a.fonts, m.f_body, m.f_small, m.f_tiny, m.f_big, m.f_row, m.f_huge, m.f_title, m.f_confirm, m.f_bold13, m.f_bold12, m.f_bold11, m.f_bold10, m.f_glyph)
	if a.scale > 1 do for f in a.fonts do font_resize(f, f.base_px * f32(a.scale))
}

menu_setup :: proc(a: ^App, data: string) {
	m := new(Menu)
	a.menu = m
	menu_parse(m, data)
	menu_fonts(a)
	a.width, a.height = MENU_W, MENU_H
	menu_refilter(a)
	menu_start_loaders(m)
}

@(private)
bold_font :: proc(a: ^App, px: f32) -> (^Font, bool) {
	f := new(Font)
	if !font_load(f, strings.concatenate({a.family, ":weight=bold"}, context.temp_allocator), px, true) do return nil, false
	f.fallback = a.font.fallback
	return f, true
}

// ---------- --dump: the state as text, for tests ----------

// What the menu shows, line by line: header, footer, then the body's entries ("*" marks the
// selection). Fonts and pixels play no part, so the tests run the same on every machine.
menu_dump :: proc(a: ^App) -> string {
	m := a.menu
	b := strings.builder_make(context.temp_allocator)
	sc := m.shortcut && (m.focus == .Menu || m.focus == .Sub)
	crumb, ph, count := menu_header(a, sc)
	q := string(a.query[:])
	if m.focus == .Input && m.input_password do q = strings.repeat("•", utf8.rune_count_in_string(q), context.temp_allocator)
	fmt.sbprintfln(&b, "focus %v%s", m.focus, sc ? " shortcuts" : "")
	fmt.sbprintfln(&b, "crumb %s", crumb)
	fmt.sbprintfln(&b, "query %s", q != "" ? q : fmt.tprintf("(%s)", ph))
	fmt.sbprintfln(&b, "count %s", count)
	if m.toast != "" do fmt.sbprintfln(&b, "toast %s", m.toast)
	else {
		hs := make([dynamic]string, 0, 8, context.temp_allocator)
		for h in menu_hints(a, sc) do append(&hs, fmt.tprintf("%s %s", h[0], h[1]))
		fmt.sbprintfln(&b, "hints %s", strings.join(hs[:], " · ", context.temp_allocator))
	}
	switch m.focus {
	case .Menu:
		if searching(m, a) {
			for r, i in m.results {
				sec := m.sections[r.sec]
				label := r.act >= 0 ? sec.actions[r.act].label : sec.name
				fmt.sbprintfln(&b, "%s %s | %s", i == m.si ? "*" : " ", label, r.act >= 0 ? sec.name : "section")
			}
		} else {
			group := ""
			for i in m.shown_sections {
				s := m.sections[i]
				if s.group != group { group = s.group; if group != "" do fmt.sbprintfln(&b, "== %s", strings.to_upper(group, context.temp_allocator)) }
				fmt.sbprintfln(&b, "%s [%s] %s%s", i == m.cur ? "*" : " ", s.key, s.name, s.dim ? " (dim)" : "")
			}
		}
	case .Sub:
		s := &m.sections[m.open]
		desc := section_slow(m, s) ? fmt.tprintf("Still waiting on %s", s.name) : s.desc
		fmt.sbprintfln(&b, "title %s · %s%s", s.name, desc, is_page(m, m.open) ? (s.pane ? " (pane)" : " (full width)") : "")
		for e in m.shown_actions {
			act := s.actions[e]
			sel := m.si < len(m.sel_actions) && m.sel_actions[m.si] == e
			switch act.kind {
			case .Heading: fmt.sbprintfln(&b, "== %s%s", strings.to_upper(act.label, context.temp_allocator), act.count != "" ? fmt.tprintf(" [%s]", act.count) : "")
			case .Empty: fmt.sbprintfln(&b, "-- %s", act.label)
			case .Notice: fmt.sbprintfln(&b, "!! %s: %s · %s", act.tone, act.label, act.meta)
			case .Bars: fmt.sbprintfln(&b, "~~ %d loading bars", act.bars)
			case .Card: fmt.sbprintfln(&b, "[] %s %s · %s · %s", act.state, act.label, act.meta, act.line2)
			case .Progress: fmt.sbprintfln(&b, "↓ %s %d%% · %s", act.label, act.pct, act.meta)
			case .Row:
				meta := act.meta
				if len(act.choices) > 0 do meta = fmt.tprintf("‹ %s ›", act.meta)
				if act.slider do meta = fmt.tprintf("%d%%", act.value)
				extra := make([dynamic]string, 0, 4, context.temp_allocator)
				if act.mark != "" do append(&extra, fmt.tprintf("mark %s", act.mark))
				if act.sub != "" do append(&extra, fmt.tprintf("sub%s", act.sub))
				if act.chip != "" do append(&extra, fmt.tprintf("chip %s", act.chip))
				if act.key != "" do append(&extra, fmt.tprintf("key %s", act.key))
				if act.dim do append(&extra, "dim")
				fmt.sbprintf(&b, "%s %s", sel ? "*" : " ", act.label)
				if meta != "" do fmt.sbprintf(&b, " | %s", meta)
				if len(extra) > 0 do fmt.sbprintf(&b, " (%s)", strings.join(extra[:], ", ", context.temp_allocator))
				fmt.sbprintln(&b)
			}
		}
	case .View:
		for j, i in m.shown_items {
			it := m.views[m.view].items[j]
			fmt.sbprintfln(&b, "%s %s%s%s", i == m.si ? "*" : " ", it.label, it.current ? " (current)" : "", it.sub != "" ? fmt.tprintf(" · %s", it.sub) : "")
		}
	case .Input:
		fmt.sbprintfln(&b, "ask %s · %s%s", m.input_prompt, m.input_hint, m.input_password ? " (password)" : "")
	case .Confirm:
		act := m.sections[m.pending.sec].actions[m.pending.act]
		fmt.sbprintfln(&b, "confirm %s · %s · %s", act.confirm_title, act.confirm_body, m.cf == 0 ? "Yes" : "No")
	case .Web:
		for r, i in web_rows(a) do fmt.sbprintfln(&b, "%s %s %s | %s", i == m.si ? "*" : " ", r.tag, r.label, r.meta)
	case .Calc:
		out, ok := logic.calc_eval(q_of(a))
		fmt.sbprintfln(&b, "= %s", ok ? out : "…")
	}
	return strings.to_string(b)
}
