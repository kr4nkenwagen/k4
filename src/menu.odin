package k4

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
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
// Enter prints the chosen action's or item's id; a web search prints "url:<url>".

Action :: struct {
	id, label, meta, view: string,
	heading: bool,
	stay, app: bool,
	slider: bool,
	value, step: int,
	jump: string,
	confirm_title, confirm_body: string,
}
Item :: struct { id, label, image: string, current: bool }

Load_State :: enum { Ready, Lazy, Loading, Failed }

Loader :: struct {
	cmd:   string,
	refresh: bool, // reloading: keep the old rows until the new ones are in
	state: Load_State,
	pipe:  ^os.File,
	proc_: os.Process,
	buf:   [dynamic]u8,
}

Section :: struct {
	id, name, key, desc, icon: string,
	actions: [dynamic]Action,
	load:    Loader,
}

View :: struct {
	name, title, subtitle: string,
	grid: bool,
	items: [dynamic]Item,
	load:  Loader,
}

Focus :: enum { Menu, Sub, View, Web, Calc, Confirm }

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
	f_body, f_small, f_tiny, f_big, f_title, f_row, f_huge, f_confirm, f_bold13: ^Font,
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
			append(&m.sections, Section{id = get(f, 1), name = get(f, 2), key = strings.to_upper(get(f, 3)), desc = get(f, 4), icon = get(f, 5)})
		case "A", "H":
			if len(m.sections) > 0 do append(&m.sections[len(m.sections) - 1].actions, action_from(f))
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

@(private)
action_from :: proc(f: []string) -> Action {
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
	if f[0] == "H" do return Action{label = get(f, 1), heading = true}
	a := Action{id = get(f, 1), label = get(f, 2), meta = get(f, 3), view = get(f, 4)}
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
	m.loading += 1
}

menu_start_loaders :: proc(m: ^Menu) {
	if m.cur < len(m.sections) do loader_start(m, &m.sections[m.cur].load)
	for &s in m.sections do loader_start(m, &s.load)
	for &v in m.views do loader_start(m, &v.load)
}

// After a "stay" action: load every section and view again, keeping what is shown until
// the new rows arrive.
menu_reload :: proc(m: ^Menu) {
	for &s in m.sections do if s.load.cmd != "" && s.load.state == .Ready { s.load.state = .Lazy; clear(&s.load.buf); s.load.refresh = true }
	for &v in m.views do if v.load.state == .Ready { v.load.state = .Lazy; clear(&v.load.buf); v.load.refresh = true }
	menu_start_loaders(m)
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
		text := string(m.runner.buf[:])
		for line in strings.split_lines_iterator(&text) do if strings.trim_space(line) != "" do last = line
		if last != "" do m.toast = strings.clone(last)
		m.runner = {}
		if m.slide_pending {
			m.slide_pending = false
			execute(a, m.slide_sec, m.slide_act)
			return true
		}
		menu_reload(m)
		return true
	}
	for &s in m.sections {
		if s.load.state != .Loading || linux.Fd(os.fd(s.load.pipe)) != fd do continue
		if !loader_read(m, &s.load) do return false
		if s.load.refresh do clear(&s.actions)
		s.load.refresh = false
		text := string(s.load.buf[:])
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t")
			if len(f) > 0 && (f[0] == "A" || f[0] == "H") do append(&s.actions, action_from(f))
		}
		menu_start_loaders(m)
		menu_refilter(a)
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
			it := Item{id = f[1], label = f[2]}
			if len(f) > 3 do it.image = f[3]
			if len(f) > 4 do it.current = f[4] == "current"
			append(&v.items, it)
		}
		menu_start_loaders(m)
		if m.focus == .View && &m.views[m.view] == &v do menu_select_current(m)
		menu_refilter(a)
		return true
	}
	return false
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
	for _, i in m.sections do append(&m.shown_sections, i)
	sec := m.focus == .Menu ? m.cur : m.open
	if sec >= 0 && sec < len(m.sections) {
		filter := m.focus == .Sub && !m.shortcut && q != ""
		for act, i in m.sections[sec].actions {
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
	for s, i in m.sections do if all_in(strings.to_lower(s.name, context.temp_allocator), toks) do append(&m.results, Result{i, -1})
	Scored :: struct { r: Result, score: int }
	items := make([dynamic]Scored, 0, 64, context.temp_allocator)
	ql := strings.to_lower(q, context.temp_allocator)
	for s, si in m.sections {
		hdr := ""
		for act, ai in s.actions {
			if act.heading { hdr = act.label; if bar := strings.index(hdr, " · "); bar >= 0 do hdr = hdr[:bar]; continue }
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
	case .Calc, .Confirm: return 0
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

menu_enter :: proc(a: ^App, idx: int) {
	m := a.menu
	if idx < 0 || idx >= len(m.sections) do return
	m.focus, m.open, m.cur, m.si, m.scroll, m.toast, m.shortcut = .Sub, idx, idx, 0, 0, "", m.shortcut
	loader_start(m, &m.sections[idx].load)
	clear_query(a)
	menu_refilter(a)
}

menu_open_view :: proc(a: ^App, name: string, from: int) {
	m := a.menu
	for &v, i in m.views {
		if v.name != name do continue
		m.focus, m.view, m.view_from, m.scroll, m.toast = .View, i, from, 0, ""
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
	case .View:
		m.focus, m.si, m.scroll = .Sub, max(m.view_from, 0), 0
		clear_query(a)
	case .Sub:
		m.focus, m.cur, m.si = .Menu, m.open, 0
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
		n := len(m.sections)
		if n == 0 do return
		m.cur = ((m.cur + d) % n + n) % n
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
		if m.si < len(m.sel_actions) do run_action(a, m.open, m.sel_actions[m.si])
	case .View:
		if m.si < len(m.shown_items) do finish(a, m.views[m.view].items[m.shown_items[m.si]].id)
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
		m.open, m.cur = sec, sec
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
	if !act.stay || m.run_cmd == "" { finish(a, act.id); return }
	if m.runner.state == .Loading do return
	cmd := strings.concatenate({m.run_cmd, " '", act.id, "'"})
	if act.slider do cmd = fmt.aprintf("K4_VALUE=%d %s", act.value, cmd)
	m.runner = Loader{cmd = cmd, state = .Lazy}
	saved := m.loading // the runner skips the section-loader cap, but counts while it runs
	m.loading = 0
	loader_start(m, &m.runner)
	m.loading = saved + (m.runner.state == .Loading ? 1 : 0)
	m.toast = act.slider ? fmt.aprintf("%s  %d%%", act.label, act.value) : strings.concatenate({act.label, "  …"})
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
	if !act.slider do return false
	step := act.step > 0 ? act.step : 5
	nv := clamp(act.value + d * step, 0, 100)
	if nv == act.value do return true
	act.value = nv
	if m.runner.state == .Loading {
		m.slide_pending, m.slide_sec, m.slide_act = true, sec, idx
		m.toast = fmt.aprintf("%s  %d%%", act.label, nv)
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
		m.focus, m.open, m.cur = .Sub, p.sec, p.sec
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
	if alt && ch != 0 {
		up := strings.to_upper(utf8.runes_to_string({ch}, context.temp_allocator), context.temp_allocator)
		for s, i in m.sections do if s.key == up { menu_enter(a, i); return true }
		return false
	}
	// shortcut mode: one keystroke per step, the query is not used
	if m.shortcut && (m.focus == .Menu || m.focus == .Sub) {
		switch {
		case k == .Escape:
			if m.focus == .Sub { m.focus, m.cur = .Menu, m.open; menu_refilter(a) } else { a.exit = 1; a.done = true }
		case k == .Tab || text == "/":
			m.shortcut = false; menu_refilter(a)
		case (k == .Left || k == .Right) && m.focus == .Sub && slide(a, k == .Left ? -1 : 1):
		case k == .Backspace || k == .Left:
			if m.focus == .Sub { m.focus, m.cur = .Menu, m.open; menu_refilter(a) }
		case k == .Down || text == "j": menu_move(a, 1)
		case k == .Up || text == "k": menu_move(a, -1)
		case k == .Enter || k == .Right: menu_run(a)
		case m.focus == .Sub && len(text) == 1 && text[0] >= '1' && text[0] <= '9':
			n := int(text[0] - '1')
			if n < len(m.sel_actions) { m.si = n; menu_run(a) }
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
	crumb, ph, count: string
	srch := searching(m, a)
	switch m.focus {
	case .Menu:
		crumb = sc ? "SHORTCUTS" : (srch ? "SEARCH" : "MENU")
		ph = sc ? "Press a letter   / to search" : "Search apps and actions…"
		count = sc ? "" : (srch ? fmt.tprintf("%d results", len(m.results)) : fmt.tprintf("%d sections", len(m.sections)))
	case .Confirm:
		crumb = "CONFIRM"
	case .Sub:
		crumb = fmt.tprintf("%s › %s", sc ? "SHORTCUTS" : "MENU", strings.to_upper(pv_name, context.temp_allocator))
		ph = sc ? "Press a number   / to search" : fmt.tprintf("Search %s…", pv_name)
		count = sc ? "" : fmt.tprintf("%d actions", len(m.sel_actions))
	case .View:
		v := m.views[m.view]
		crumb = strings.to_upper(fmt.tprintf("%s › %s", pv_name, v.title), context.temp_allocator)
		plural := strings.to_lower(v.title, context.temp_allocator)
		if !strings.has_suffix(plural, "s") do plural = strings.concatenate({plural, "s"}, context.temp_allocator)
		ph = fmt.tprintf("Filter %s…", plural)
		count = fmt.tprintf("%d %s", len(m.shown_items), plural)
	case .Web:
		crumb, ph = "g DUCKDUCKGO", "Search the web…"
		count = q_of(a) != "" ? "Enter to open" : ""
	case .Calc:
		crumb, ph = "= CALC", "sqrt(2) * 15"
	}
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
		hints: [][2]string
		switch {
		case sc && m.focus == .Menu: hints = {{"a–z", "Open"}, {"j k", "Move"}, {"/", "Search"}, {"Esc", "Close"}}
		case sc: hints = {{"1–9", "Run"}, {"j k", "Move"}, {"⌫", "Back"}, {"/", "Search"}}
		case m.focus == .Confirm: hints = {{"y", "Yes"}, {"n Esc", "No"}, {"← →", "Choose"}}
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
		if srch do draw_results(a, cv, S, body)
		else do draw_panes(a, cv, S, body, sc)
	case .Confirm: draw_confirm(a, cv, S, body)
	case .View: draw_view(a, cv, S, body)
	case .Web: draw_web(a, cv, S, body)
	case .Calc: draw_calc(a, cv, S, body)
	}
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

	// left: sections
	ry, rh := by + 6 * S, 28 * S
	if len(m.shown_sections) == 0 do text_in(cv, m.f_body, "No match", x0 + 14 * S, ry + 4 * S, rh, argb(dim, 0xff))
	for i in m.shown_sections {
		if ry + rh > fy do break
		s := m.sections[i]
		on := i == (m.focus == .Menu ? m.cur : m.open)
		strong := on && m.focus == .Menu
		col := fg
		if strong { fill_rect(cv, x0, ry, lw, rh, argb(acc, 0xff)); col = bg }
		else if on { fill_rect(cv, x0, ry, lw, rh, argb(t.selection, 0xff)); col = fgb }
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
	if s.desc != "" {
		draw_text_f(cv, m.f_small, s.desc, px + 20 * S, py, argb(dim, 0xff), nil, 0, x1 - 20 * S)
		py += int(m.f_small.line_h) + 8 * S
	}
	ah := 30 * S
	hh_ := 10 * S + int(m.f_tiny.line_h) + 4 * S
	tip_h := m.focus == .Menu && !sc && q_of(a) == "" ? 28 * S : 0
	bottom := fy - 8 * S - tip_h
	if s.load.state == .Failed {
		text_in(cv, m.f_body, "Could not load this section", px + 20 * S, py, ah, argb(dim, 0xff))
	} else if len(s.actions) == 0 && s.load.state != .Ready {
		text_in(cv, m.f_body, "Loading…", px + 20 * S, py, ah, argb(dim, 0xff))
	} else if len(m.sel_actions) == 0 {
		text_in(cv, m.f_body, len(s.actions) == 0 ? "Nothing here" : "No match", px + 20 * S, py, ah, argb(dim, 0xff))
	} else {
		// entries: headings and rows; scroll (in entries) keeps the selected row visible
		sel_entry := -1
		if m.focus == .Sub && m.si < len(m.sel_actions) {
			for e, i in m.shown_actions do if e == m.sel_actions[m.si] { sel_entry = i; break }
		}
		height :: proc(act: Action, ah, hh: int) -> int { return act.heading ? hh : ah }
		if m.focus != .Sub do m.scroll = 0
		if sel_entry >= 0 {
			if sel_entry < m.scroll do m.scroll = sel_entry
			if m.scroll > 0 && sel_entry == m.scroll && s.actions[m.shown_actions[m.scroll - 1]].heading do m.scroll -= 1
			for {
				h := 0
				for e in m.scroll ..= sel_entry do h += height(s.actions[m.shown_actions[e]], ah, hh_)
				if py + h <= bottom || m.scroll >= sel_entry do break
				m.scroll += 1
			}
		}
		row := 0
		for e in 0 ..< len(m.shown_actions) {
			act := s.actions[m.shown_actions[e]]
			if !act.heading do row += 1
			if e < m.scroll do continue
			h := height(act, ah, hh_)
			if py + h > bottom do break
			if act.heading {
				draw_text_f(cv, m.f_tiny, strings.to_upper(act.label, context.temp_allocator), px + 20 * S, py + 10 * S, argb(dim, 0xff), nil, 0, x1 - 20 * S)
				py += h
				continue
			}
			j := row - 1
			on := m.focus == .Sub && e == sel_entry
			lc, mc, arrow := m.focus == .Sub ? fgb : fg, dim, mix(bg, fg, 0.35)
			if on { fill_rect(cv, px, py, x1 - px, ah, argb(acc, 0xff)); lc, mc, arrow = bg, bg, bg }
			num := sc && m.focus == .Sub && j < 9
			mark := num ? fmt.tprintf("%d", j + 1) : (act.view != "" || act.jump != "" ? "»" : "›")
			mx := px + 20 * S
			if num do badge(cv, m.f_tiny, mark, mx + 16 * S, py, ah, S, on ? bg : acc, on ? acc : bg, true)
			else do text_in(cv, m.f_body, mark, mx + 4 * S, py, ah, argb(arrow, 0xff))
			meta := act.meta
			if meta == "" && act.confirm_title != "" do meta = "asks first"
			if meta == "" && act.jump != "" do meta = "→"
			lx := mx + 16 * S + 12 * S
			if act.slider {
				sw := draw_slider(a, cv, S, act.value, x1 - 20 * S, py, ah, on)
				text_in(cv, m.f_body, act.label, lx, py, ah, argb(lc, 0xff), x1 - 20 * S - sw - 12 * S)
				py += ah
				continue
			}
			mw := meta != "" ? tw(m.f_small, meta) : 0
			text_in(cv, m.f_body, act.label, lx, py, ah, argb(lc, 0xff), x1 - 20 * S - mw - 12 * S)
			if mw > 0 do text_in(cv, m.f_small, meta, x1 - 20 * S - mw, py, ah, argb(mc, 0xff))
			py += ah
		}
	}
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
		tile_h := 100 * S
		cell_h := tile_h + 8 * S + int(m.f_small.line_h) + gy
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
		}
		return
	}
	rh := 34 * S
	visible := max((fy - 8 * S - py) / rh, 1)
	if m.si < m.scroll do m.scroll = m.si
	if m.si >= m.scroll + visible do m.scroll = m.si - visible + 1
	for j in m.scroll ..< min(m.scroll + visible, len(m.shown_items)) {
		it := v.items[m.shown_items[j]]
		on := j == m.si
		lc, mc := fgb, dim
		if on { fill_rect(cv, x0, py, bw, rh, argb(acc, 0xff)); lc, mc = bg, bg }
		tag_w := it.current ? tw(m.f_small, "current") : 0
		text_in(cv, m.f_row, it.label, x0 + pad, py, rh, argb(lc, 0xff), x1 - pad - tag_w - 12 * S)
		if it.current do text_in(cv, m.f_small, "current", x1 - pad - tag_w, py, rh, argb(mc, 0xff))
		py += rh
	}
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

// ---------- setup ----------

menu_setup :: proc(a: ^App, data: string) {
	m := new(Menu)
	a.menu = m
	menu_parse(m, data)
	base := &a.font
	m.f_body = font_sized(base, 13)
	m.f_small = font_sized(base, 12)
	m.f_tiny = font_sized(base, 11)
	m.f_big = font_sized(base, 17)
	m.f_row = font_sized(base, 14)
	m.f_huge = font_sized(base, 44)
	m.f_title = font_sized(base, 18)
	m.f_confirm = font_sized(base, 20)
	m.f_bold13 = m.f_body
	if bold, ok := bold_font(a, 18); ok {
		m.f_title = bold
		m.f_confirm = font_sized(bold, 20)
		m.f_bold13 = font_sized(bold, 13)
	}
	append(&a.fonts, m.f_body, m.f_small, m.f_tiny, m.f_big, m.f_row, m.f_huge, m.f_title, m.f_confirm, m.f_bold13)
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
