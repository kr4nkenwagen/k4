package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --claude: Claude (the Kestrel design's Claude window, 760×600; with --popup the Sessions page
// alone, 420×560, under the bar's Claude module). Three pages, Tab or Alt+1–3:
//   Ask: a question typed in the head goes to Claude through the Claude Code CLI with your own
//   login, tools off; the answer streams in as Markdown (headings, lists, inline code, code
//   blocks), the next question follows up. ← → the model (when the field is empty, Alt any time),
//   ^Y copies the answer, ^K its last code block, ^T continues it in a terminal, ^N starts over,
//   Esc stops an answer, then clears the field, then the conversation, then closes.
//   Sessions: the running Claude Code sessions in groups (needs you, working, idle); the picked
//   one opens its buttons: ↵ jumps to its terminal, x stops a background one (y / n), n starts a
//   new one in a recent project.
//   Usage: a card per plan window (5-hour, weekly…) with % used, yellow over 80, red over 95,
//   striped when reached, and when it resets.
// The data comes from k4-claude (panel lines R and L, panel.odin), again every 5 s while open:
//   S <logged in 1|0> <model> <models a|b|c> <limits updated, unix>
//   A <pid> <name> <cwd> <interactive|background> <busy|waiting|idle> <waiting for> <since unix> <background id>
//   U <key> <label> <used 0–1> <when it resets, e.g. "resets 15:30 · in 1 h 44 min">
//   P <folder> <what it is>   (recent projects, for a new session)
// The runner's verbs: ask MODEL TEXT and follow SESSION MODEL TEXT (streamed: k4:sid ID,
// k4:meta HH:MM, k4:delta TEXT with \n for new lines, k4:limit KEY USED RESETS, k4:err TEXT),
// copy ($K4_INPUT), term SESSION, jump PID, new FOLDER, stop ID, model NAME.

CLAUDE_W, CLAUDE_H :: 760, 600
CLAUDE_PW, CLAUDE_PH :: 420, 560

Cl_Session :: struct { pid, name, cwd, kind, status, waiting, bgid: string, since: i64 }
Cl_Use :: struct { key, label, text: string, used: f32 }
Cl_Turn :: struct { q, model, meta: string, a: [dynamic]u8, err: string }
Cl_Proj :: struct { dir, sub: string }

Claude :: struct {
	using pn: Panel,
	logged_in: bool,
	model: string,
	models: [dynamic]string,
	limits_at: i64,
	sessions: [dynamic]Cl_Session,
	uses: [dynamic]Cl_Use,
	projects: [dynamic]Cl_Proj,
	page: int, // 0 Ask, 1 Sessions, 2 Usage
	cur: int,
	picking: bool,   // Sessions: a folder for a new session
	ask_stop: string, // Sessions: the background session asked about (y / n)
	q: [dynamic]u8,
	turns: [dynamic]Cl_Turn,
	sid: string,
	waiting: bool, // asked, no word yet
	limit_msg: string, // the last answer stopped on a usage limit: the notice
	scroll: int, // Ask: lines up from the bottom
}

claude_setup :: proc(a: ^App, data: string) {
	c := new(Claude)
	c.mode = {draw = cl_draw, key = cl_key, click = cl_click, scroll = cl_scroll, loaded = cl_loaded, ran = cl_ran, stream = cl_stream, tick = cl_tick, dump = cl_dump}
	panel_init(a, &c.pn, "claude", data)
	c.refresh_ms = 5000
	if a.opts.open == "sessions" || c.popup do c.page = 1
	if a.opts.open == "usage" do c.page = 2
	a.width, a.height = c.popup ? CLAUDE_PW : CLAUDE_W, c.popup ? CLAUDE_PH : CLAUDE_H
}

@(private = "file")
C :: proc(a: ^App) -> ^Claude { return (^Claude)(a.pn) }

@(private = "file")
cl_now :: proc() -> i64 {
	if v, ok := strconv.parse_i64(os.get_env("K4_CLAUDE_NOW", context.temp_allocator)); ok do return v
	return time.to_unix_seconds(time.now())
}

@(private = "file")
cl_rank :: proc(s: string) -> int { return s == "waiting" ? 0 : (s == "busy" ? 1 : 2) }

@(private = "file")
cl_loaded :: proc(a: ^App, data: string) {
	c := C(a)
	for &s in c.sessions { delete(s.pid); delete(s.name); delete(s.cwd); delete(s.kind); delete(s.status); delete(s.waiting); delete(s.bgid) }
	clear(&c.sessions)
	for &u in c.uses { delete(u.key); delete(u.label); delete(u.text) }
	clear(&c.uses)
	for &p in c.projects { delete(p.dir); delete(p.sub) }
	clear(&c.projects)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			c.logged_in = fget(f, 1) == "1"
			if c.model == "" do c.model = strings.clone(fget(f, 2))
			for &m in c.models do delete(m)
			clear(&c.models)
			for m in strings.split(fget(f, 3), "|", context.temp_allocator) do if m != "" do append(&c.models, strings.clone(m))
			c.limits_at, _ = strconv.parse_i64(fget(f, 4))
		case "A":
			s := Cl_Session{strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5)), strings.clone(fget(f, 6)), strings.clone(fget(f, 8)), 0}
			s.since, _ = strconv.parse_i64(fget(f, 7))
			append(&c.sessions, s)
		case "U":
			u := Cl_Use{key = strings.clone(fget(f, 1)), label = strings.clone(fget(f, 2)), text = strings.clone(fget(f, 4))}
			u.used, _ = strconv.parse_f32(fget(f, 3))
			append(&c.uses, u)
		case "P": append(&c.projects, Cl_Proj{strings.clone(fget(f, 1)), strings.clone(fget(f, 2))})
		}
	}
	for i in 1 ..< len(c.sessions) { // needs you first, then working, then idle; the longest in each first
		for j := i; j > 0; j -= 1 {
			x, y := c.sessions[j - 1], c.sessions[j]
			if cl_rank(y.status) < cl_rank(x.status) || (cl_rank(y.status) == cl_rank(x.status) && y.since < x.since) do c.sessions[j - 1], c.sessions[j] = y, x
			else do break
		}
	}
	if c.model == "" && len(c.models) > 0 do c.model = strings.clone(c.models[0])
	c.cur = clamp(c.cur, 0, max(cl_n(c) - 1, 0))
}

@(private = "file")
cl_n :: proc(c: ^Claude) -> int {
	if c.page == 1 do return c.picking ? len(c.projects) : len(c.sessions)
	return 0
}

@(private = "file")
cl_ran :: proc(a: ^App, verb, line: string) -> bool {
	c := C(a)
	if strings.has_prefix(line, "k4:limit ") { cl_limit(c, line[9:]); return true }
	return false
}

// "five_hour 0.25 1793187000": a window as Claude Code just reported it (the text comes on reload).
@(private = "file")
cl_limit :: proc(c: ^Claude, s: string) {
	f := strings.fields(s, context.temp_allocator)
	if len(f) < 2 do return
	used, _ := strconv.parse_f32(f[1])
	for &u in c.uses do if u.key == f[0] { u.used = used; return }
	label := f[0] == "five_hour" ? "5-hour window" : (f[0] == "seven_day" ? "Weekly · all models" : f[0])
	append(&c.uses, Cl_Use{key = strings.clone(f[0]), label = strings.clone(label), text = strings.clone(""), used = used})
}

@(private = "file")
cl_stream :: proc(a: ^App, line: string) {
	c := C(a)
	if len(c.turns) == 0 do return
	t := &c.turns[len(c.turns) - 1]
	switch {
	case line == "k4:end":
		c.waiting = false
		if t.err != "" && strings.contains(strings.to_lower(t.err, context.temp_allocator), "limit") && len(t.a) == 0 {
			// stopped on a usage limit: the notice says so and the question goes back in the field
			delete(c.limit_msg); c.limit_msg = strings.clone(t.err)
			clear(&c.q); append(&c.q, ..transmute([]u8)t.q)
			delete(t.q); delete(t.model); delete(t.meta); delete(t.a); delete(t.err)
			pop(&c.turns)
		}
	case strings.has_prefix(line, "k4:sid "): delete(c.sid); c.sid = strings.clone(strings.trim_space(line[7:]))
	case strings.has_prefix(line, "k4:meta "): delete(t.meta); t.meta = strings.clone(fmt.tprintf("%s · %s", strings.trim_space(line[8:]), t.model))
	case strings.has_prefix(line, "k4:delta "):
		c.waiting = false
		d, _ := strings.replace_all(line[9:], "\\n", "\n", context.temp_allocator)
		append(&t.a, ..transmute([]u8)d)
		c.scroll = 0
	case strings.has_prefix(line, "k4:limit "): cl_limit(c, line[9:])
	case strings.has_prefix(line, "k4:err "): c.waiting = false; delete(t.err); t.err = strings.clone(line[7:])
	}
}

@(private = "file")
cl_tick :: proc(a: ^App) -> int {
	c := C(a)
	return c.waiting || panel_streaming(&c.pn) ? 300 : -1 // the working dots, the caret
}

@(private = "file")
cl_ask :: proc(a: ^App) {
	c := C(a)
	q := strings.trim_space(string(c.q[:]))
	if q == "" { panel_say(&c.pn, "Type a question first"); return }
	if !c.logged_in { panel_say(&c.pn, "Log in first: run claude once in a terminal (^T)", a.theme.yellow); return }
	if panel_streaming(&c.pn) do return
	delete(c.limit_msg); c.limit_msg = ""
	append(&c.turns, Cl_Turn{q = strings.clone(q), model = strings.clone(c.model), meta = strings.clone(fmt.tprintf("now · %s", c.model))})
	clear(&c.q)
	c.waiting, c.scroll = true, 0
	panel_say(&c.pn, "")
	if c.sid != "" do panel_stream(a, "follow", c.sid, c.model, q)
	else do panel_stream(a, "ask", c.model, q)
}

@(private = "file")
cl_answer :: proc(c: ^Claude) -> string { return len(c.turns) > 0 ? string(c.turns[len(c.turns) - 1].a[:]) : "" }

@(private = "file")
cl_last_code :: proc(s: string) -> (body, lang: string) {
	end := strings.last_index(s, "```")
	if end < 0 do return
	start := strings.last_index(s[:end], "```")
	if start < 0 do return
	b := s[start + 3:end]
	if nl := strings.index_byte(b, '\n'); nl >= 0 { lang = strings.trim_space(b[:nl]); b = b[nl + 1:] }
	return strings.trim_right(b, "\n"), lang
}

@(private = "file")
cl_model_step :: proc(a: ^App, d: int) {
	c := C(a)
	if len(c.models) == 0 do return
	i := 0
	for m, j in c.models do if m == c.model do i = j
	i = (i + d + len(c.models)) % len(c.models)
	delete(c.model)
	c.model = strings.clone(c.models[i])
	panel_run(a, "model", c.model)
}

@(private = "file")
cl_set_page :: proc(c: ^Claude, p: int) {
	if c.popup do return
	c.page, c.cur, c.picking = p, 0, false
	delete(c.ask_stop); c.ask_stop = ""
	panel_say(&c.pn, "")
}

@(private = "file")
cl_jump :: proc(a: ^App) {
	c := C(a)
	if c.picking { if c.cur < len(c.projects) { panel_run(a, "new", c.projects[c.cur].dir); c.picking = false }; return }
	if c.cur < len(c.sessions) do panel_run(a, "jump", c.sessions[c.cur].pid)
}

@(private = "file")
cl_stop :: proc(a: ^App) {
	c := C(a)
	if c.picking || c.cur >= len(c.sessions) do return
	s := c.sessions[c.cur]
	if s.kind != "background" || s.bgid == "" { panel_say(&c.pn, "Only background sessions can be stopped from here · this one runs in a terminal"); return }
	if c.ask_stop == s.bgid { panel_run(a, "stop", s.bgid); delete(c.ask_stop); c.ask_stop = ""; return }
	delete(c.ask_stop); c.ask_stop = strings.clone(s.bgid)
}

cl_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	c := C(a)
	if ctrl && ch == 'c' { panel_stop(a); panel_close(a); return true }
	if k == .Tab || k == .Back_Tab { cl_set_page(c, (c.page + (k == .Tab ? 1 : 2)) % 3); return true }
	if alt && ch >= '1' && ch <= '3' { cl_set_page(c, int(ch - '1')); return true }
	switch c.page {
	case 0:
		switch {
		case ctrl && ch == 'y':
			if s := cl_answer(c); s != "" do panel_run(a, "copy", secret = strings.clone(s, context.temp_allocator))
			else do panel_say(&c.pn, "Nothing to copy yet")
		case ctrl && ch == 'k':
			if s, _ := cl_last_code(cl_answer(c)); s != "" do panel_run(a, "copy", secret = strings.clone(s, context.temp_allocator))
			else do panel_say(&c.pn, "No code block in the answer")
		case ctrl && ch == 't': panel_run(a, "term", c.sid)
		case ctrl && ch == 'n':
			panel_stop(a)
			for &t in c.turns { delete(t.q); delete(t.model); delete(t.meta); delete(t.a); delete(t.err) }
			clear(&c.turns)
			delete(c.sid); c.sid = ""
			panel_say(&c.pn, "New conversation")
		case ctrl: return false
		case k == .Enter: cl_ask(a)
		case (k == .Left || k == .Right) && (alt || len(c.q) == 0): cl_model_step(a, k == .Left ? -1 : 1)
		case k == .Page_Up || k == .Up: c.scroll += k == .Up ? 1 : 10
		case k == .Page_Down || k == .Down: c.scroll = max(c.scroll - (k == .Down ? 1 : 10), 0)
		case k == .Backspace: if len(c.q) > 0 { _, n := utf8.decode_last_rune(c.q[:]); resize(&c.q, len(c.q) - n) }
		case k == .Escape:
			switch {
			case panel_streaming(&c.pn): panel_stop(a); panel_say(&c.pn, "Stopped", a.theme.red)
			case len(c.q) > 0: clear(&c.q)
			case len(c.turns) > 0:
				for &t in c.turns { delete(t.q); delete(t.model); delete(t.meta); delete(t.a); delete(t.err) }
				clear(&c.turns)
				delete(c.sid); c.sid = ""
				panel_say(&c.pn, "Cleared")
			case: panel_close(a)
			}
		case text != "" && k == .None: append(&c.q, ..transmute([]u8)text)
		case: return false
		}
	case 1:
		if c.ask_stop != "" {
			switch {
			case text == "y": cl_stop(a)
			case text == "n" || k == .Escape: delete(c.ask_stop); c.ask_stop = ""
			case: return false
			}
			return true
		}
		switch {
		case k == .Down: c.cur = min(c.cur + 1, max(cl_n(c) - 1, 0))
		case k == .Up: c.cur = max(c.cur - 1, 0)
		case k == .Enter: cl_jump(a)
		case text == "n": c.picking, c.cur = !c.picking, 0
		case text == "x": cl_stop(a)
		case k == .Escape: if c.picking do c.picking = false; else do panel_close(a)
		case: return false
		}
	case 2:
		switch {
		case k == .Escape: panel_close(a)
		case: return false
		}
	}
	return true
}

cl_scroll :: proc(a: ^App, n: int) -> bool {
	c := C(a)
	if c.page == 0 { c.scroll = max(c.scroll - n * 3, 0); return true }
	c.cur = clamp(c.cur + n, 0, max(cl_n(c) - 1, 0))
	return true
}

cl_click :: proc(a: ^App, x, y, button: int) -> bool {
	c := C(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Tab: cl_set_page(c, h.a)
	case .Row: if h.a == c.cur do cl_jump(a); else { c.cur = h.a; delete(c.ask_stop); c.ask_stop = "" }
	case .Chip:
		switch h.a {
		case 0: cl_model_step(a, -1)
		case 1: cl_model_step(a, 1)
		case 10: cl_jump(a) // a row's buttons
		case 11: cl_stop(a)
		case 12: delete(c.ask_stop); c.ask_stop = ""
		}
	}
	return true
}

@(private = "file")
cl_ago :: proc(t, now: i64) -> string {
	d := now - t
	switch {
	case t <= 0: return ""
	case d < 60: return fmt.tprintf("%d s", max(d, 0))
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 86400: return fmt.tprintf("%d h", d / 3600)
	}
	return fmt.tprintf("%d d", d / 86400)
}

@(private = "file")
cl_home :: proc(p: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(p, home) do return strings.concatenate({"~", p[len(home):]}, context.temp_allocator)
	return p
}

cl_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	c := C(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	now := cl_now()
	pop := c.popup
	pages := [3]string{"ASK", "SESSIONS", "USAGE"}
	nw, nb := 0, 0
	for s in c.sessions { if s.status == "waiting" do nw += 1; if s.status == "busy" do nb += 1 }
	crumb := pop ? "CLAUDE" : fmt.tprintf("CLAUDE › %s", pages[c.page])
	// the head: 52 px (40 in the popup)
	px := (pop ? 12 : 16) * S
	hh := (pop ? 40 : 52) * S
	cf := pop ? c.f11b : c.f12b
	cw := tw(cf, crumb) + (pop ? 12 : 16) * S
	ch := (pop ? 20 : 24) * S
	fill_rect(cv, px, (hh - ch) / 2, cw, ch, argb(H.acc, 0xff))
	text_in(cv, cf, crumb, px + (cw - tw(cf, crumb)) / 2, (hh - ch) / 2, ch, argb(H.bg, 0xff))
	tx := px + cw + 10 * S
	if c.page == 0 {
		text_in(cv, c.f15b, "›", tx, 0, hh, argb(H.acc, 0xff))
		tx += tw(c.f15b, "›") + 10 * S
		// the model stepper, boxed
		mname := c.model
		if len(mname) > 0 do mname = strings.concatenate({strings.to_upper(mname[:1], context.temp_allocator), mname[1:]}, context.temp_allocator)
		mw := 20 * S + max(58 * S, tw(c.f11b, mname) + 8 * S) + 20 * S
		mx := w - px - mw
		my := (hh - 26 * S) / 2
		rounded_rect(cv, mx, my, mw, 26 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, c.f11b, "‹", mx + (20 * S - tw(c.f11b, "‹")) / 2, my, 26 * S, argb(H.dim, 0xff))
		text_in(cv, c.f11b, mname, mx + 20 * S + (mw - 40 * S - tw(c.f11b, mname)) / 2, my, 26 * S, argb(H.fg, 0xff))
		text_in(cv, c.f11b, "›", mx + mw - 20 * S + (20 * S - tw(c.f11b, "›")) / 2, my, 26 * S, argb(H.dim, 0xff))
		hit_add(a, mx, my, 20 * S, 26 * S, .Chip, 0, 0)
		hit_add(a, mx + mw - 20 * S, my, 20 * S, 26 * S, .Chip, 1, 0)
		q := string(c.q[:])
		fw := mx - 12 * S - tx
		if q == "" do text_in(cv, c.f13, len(c.turns) > 0 ? "Follow up…" : "Ask Claude…", tx + 4 * S, 0, hh, argb(H.faint, 0xff))
		qs := ellipsize(c.f13, q, fw - 10 * S)
		if q != "" do text_in(cv, c.f13, qs, tx, 0, hh, argb(H.fg, 0xff))
		fill_rect(cv, tx + (q != "" ? tw(c.f13, qs) + S : 0), (hh - 18 * S) / 2, 2 * S, 18 * S, argb(H.acc, 0xff))
	} else {
		title, right := "", ""
		rc := H.dim
		if c.page == 1 {
			title = len(c.sessions) > 0 ? fmt.tprintf("%d sessions", len(c.sessions)) : "Sessions"
			right = nw > 0 ? fmt.tprintf("%d need%s you · %d working", nw, nw == 1 ? "s" : "", nb) : (nb > 0 ? fmt.tprintf("%d working", nb) : "none running")
			if nw > 0 do rc = H.hot
		} else { title = "Usage"; right = len(c.uses) > 0 ? "as Claude Code reports it" : "" }
		text_in(cv, c.f10, right, w - px - tw(c.f10, right), 0, hh, argb(rc, 0xff))
		text_in(cv, c.f13b, ellipsize(c.f13b, title, w - px - tw(c.f10, right) - 12 * S - tx), tx, 0, hh, argb(H.fg, 0xff))
	}
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	y := hh + S
	// the tabs (not in the popup)
	if !pop {
		tbh := 32 * S
		tbx := px
		over := false
		for u in c.uses do if u.used >= 0.95 do over = true
		keys := [3]string{"Alt 1", "Alt 2", "Alt 3"}
		for l, i in pages {
			on := i == c.page
			bw := 12 * S + spaced_w(c.f10b, l, S) + 6 * S + tw(c.f10, keys[i]) + 12 * S
			badge := i == 1 && nw > 0
			bang := i == 2 && over
			if badge do bw += count_tag_w(c.f9b, nw, S) + 6 * S
			if bang do bw += count_tag_w(c.f9b, 1, S) + 6 * S
			spaced(cv, c.f10b, l, tbx + 12 * S, y, tbh, on ? H.fg : H.dim, S)
			kx := tbx + 12 * S + spaced_w(c.f10b, l, S) + 6 * S
			text_in(cv, c.f10, keys[i], kx, y, tbh, argb(H.faint, 0xff))
			bx := kx + tw(c.f10, keys[i]) + 6 * S
			if badge do count_tag(cv, c.f9b, bx, y + (tbh - 11 * S) / 2, nw, S, H.hot, H.bg, H.bg)
			if bang { // "!" in the same tag
				fill_rect(cv, bx, y + (tbh - 11 * S) / 2, 11 * S, 11 * S, argb(H.hot, 0xff))
				text_in(cv, c.f9b, "!", bx + (11 * S - tw(c.f9b, "!")) / 2, y + (tbh - 11 * S) / 2, 11 * S, argb(H.bg, 0xff))
			}
			if on do fill_rect(cv, tbx, y + tbh - 2 * S, bw, 2 * S, argb(H.acc, 0xff))
			hit_add(a, tbx, y, bw, tbh, .Tab, i, 0)
			tbx += bw
		}
		note := ""
		switch c.page {
		case 0: note = len(c.turns) > 0 ? fmt.tprintf("%d turn%s · ^N new", len(c.turns), len(c.turns) == 1 ? "" : "s") : "new conversation"
		case 1: note = "from claude agents · every 5 s"
		case 2: note = c.limits_at > 0 ? fmt.tprintf("updated %s ago", cl_ago(c.limits_at, now)) : ""
		}
		text_in(cv, c.f10, note, w - px - tw(c.f10, note), y, tbh, argb(H.dim, 0xff))
		fill_rect(cv, 0, y + tbh, w, S, argb(H.line, 0xff))
		y += tbh + S
	}
	fh := (pop ? 30 : 34) * S
	fy := h - fh
	switch c.page {
	case 0: cl_draw_ask(a, cv, S, H, y, fy, px)
	case 1: cl_draw_sessions(a, cv, S, H, y, fy, px, now)
	case 2: cl_draw_usage(a, cv, S, H, y, fy, px)
	}
	// the footer: keys at the left, the message at the right
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	hints: [][2]string
	switch c.page {
	case 0: hints = panel_streaming(&c.pn) || c.waiting ? {{"Esc", "Stop"}} : {{"↵", "Ask"}, {"← →", "Model"}, {"^Y", "Copy"}, {"^K", "Code"}, {"^T", "Terminal"}}
	case 1:
		switch {
		case c.ask_stop != "": hints = {{"y", "Stop"}, {"n", "Keep"}}
		case pop: hints = {{"↑↓", "Move"}, {"↵", "Jump"}, {"n", "New"}, {"x", "Stop"}}
		case: hints = {{"↑↓", "Move"}, {"↵", "Jump"}, {"n", "New"}, {"x", "Stop"}, {"Tab", "Page"}}
		}
	case 2: hints = {{"Tab", "Page"}, {"Esc", "Close"}}
	}
	kx := px
	for k in hints {
		kw := tw(c.f10, k[0]) + 8 * S
		fill_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, argb(th.fg, 0x0d))
		rounded_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, c.f10, k[0], kx + 4 * S, fy, fh, argb(mix(H.fg, H.bg, 0.2), 0xff))
		kx += kw + 5 * S
		text_in(cv, c.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(c.f10, k[1]) + 12 * S
	}
	if c.pn.toast != "" {
		ts := ellipsize(c.f10, c.pn.toast, w - px - kx - 8 * S)
		text_in(cv, c.f10, ts, w - px - tw(c.f10, ts), fy, fh, argb(c.pn.tone != 0 ? c.pn.tone : H.acc, 0xff))
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 24)
}

// A line of an answer as drawn: what it is, its text (a list item's marker apart).
@(private = "file")
Cl_Ln :: struct { kind: int, s, mark: string, op: bool, code_on: bool }
// kinds: 0 paragraph, 1 heading, 2 list item, 3 code line, 4 code head, 5 question, 6 gap, 7 error, 8 working, 9 code foot

@(private = "file")
cl_lines :: proc(a: ^App, tw_: int) -> [dynamic]Cl_Ln {
	c := C(a)
	out := make([dynamic]Cl_Ln, 0, 64, context.temp_allocator)
	for t, ti in c.turns {
		latest := ti == len(c.turns) - 1
		old := !latest
		if ti > 0 do append(&out, Cl_Ln{kind = 6})
		qs := wrap_hard(c.f12b, t.q, tw_ - 120 * S_unit(a))
		for x, i in qs do append(&out, Cl_Ln{kind = 5, s = x, mark = i == 0 ? t.meta : "", op = old})
		if latest && c.waiting { append(&out, Cl_Ln{kind = 8, s = fmt.tprintf("Thinking… with %s", t.model)}); continue }
		code := false
		inline_on := false // a backtick span open across wrapped lines
		for l in strings.split_lines(string(t.a[:]), context.temp_allocator) {
			tl := strings.trim_left_space(l)
			if strings.has_prefix(tl, "```") {
				if !code { append(&out, Cl_Ln{kind = 4, s = strings.trim_space(tl[3:]), op = old}) } else do append(&out, Cl_Ln{kind = 9, op = old})
				code = !code
				continue
			}
			if code { append(&out, Cl_Ln{kind = 3, s = l, op = old}); continue }
			switch {
			case l == "": append(&out, Cl_Ln{kind = 6, op = old})
			case strings.has_prefix(tl, "#"):
				hs := strings.trim_left(tl, "#")
				append(&out, Cl_Ln{kind = 1, s = strings.trim_space(hs), op = old})
			case strings.has_prefix(tl, "- ") || strings.has_prefix(tl, "* ") || cl_ordered(tl) > 0:
				mark, body := "·", tl[2:]
				if n := cl_ordered(tl); n > 0 { mark = tl[:n]; body = strings.trim_left_space(tl[n:]) }
				for x, i in wrap_hard(c.f12, body, tw_ - 24 * S_unit(a)) { append(&out, Cl_Ln{kind = 2, s = x, mark = i == 0 ? mark : "", op = old, code_on = inline_on}); inline_on = inline_on ~ (strings.count(x, "`") % 2 == 1) }
			case:
				for x in wrap_hard(c.f12, l, tw_) { append(&out, Cl_Ln{kind = 0, s = x, op = old, code_on = inline_on}); inline_on = inline_on ~ (strings.count(x, "`") % 2 == 1) }
			}
		}
		if code do append(&out, Cl_Ln{kind = 9, op = old})
		if t.err != "" do for x in wrap_hard(c.f11, t.err, tw_) do append(&out, Cl_Ln{kind = 7, s = x, op = old})
	}
	return out
}

@(private = "file")
S_unit :: proc(a: ^App) -> int { return max(a.scale, 1) }

// "12. " → 4 (the marker's length with its dot), else 0.
@(private = "file")
cl_ordered :: proc(s: string) -> int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	if i > 0 && i + 1 < len(s) && s[i] == '.' && s[i + 1] == ' ' do return i + 1
	return 0
}

// A line with `code` spans: the spans in the accent on a tint, the rest in fg.
@(private = "file")
cl_inline :: proc(cv: ^Canvas, f: ^Font, s: string, x, y, h: int, fg, acc, tint: u32, code_on: bool) -> int {
	xx := x
	on := code_on
	rest := s
	for len(rest) > 0 {
		i := strings.index_byte(rest, '`')
		part := i < 0 ? rest : rest[:i]
		if part != "" {
			pw := tw(f, part)
			if on do fill_rect(cv, xx - 2, y + 2, pw + 4, h - 4, tint)
			text_in(cv, f, part, xx, y, h, argb(on ? acc : fg, 0xff))
			xx += pw
		}
		if i < 0 do break
		on = !on
		rest = rest[i + 1:]
	}
	return xx
}

@(private = "file")
cl_draw_ask :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, top, bottom, px: int) {
	c := C(a)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	w := cv.w
	y := top
	// the notice: not logged in, or a usage limit
	if !c.logged_in do y += 10 * S + panel_notice(a, cv, S, px, y + 10 * S, w - 2 * px, H, "Not logged in to Claude Code", "Run claude once in a terminal and log in there. k4 uses that same login; it never sees your password. ^T opens a terminal with claude.", th.yellow)
	else if c.limit_msg != "" do y += 10 * S + panel_notice(a, cv, S, px, y + 10 * S, w - 2 * px, H, "Claude Code stopped: usage limit reached", fmt.tprintf("“%s” Your question is still in the field. Another model may still have room (← →); Usage (Alt 3) shows each window.", c.limit_msg), H.hot)
	if len(c.turns) == 0 {
		if c.logged_in && c.limit_msg == "" {
			yy := y + 30 * S
			text_in(cv, c.f13b, "Ask anything", px + 6 * S, yy, 20 * S, argb(H.fg, 0xff))
			yy += 26 * S
			for l in wrap_text(c.f11, "Your own Claude Code login, the model in the stepper. Follow-ups stay in the same conversation; ^N starts a new one. Tools are off: nothing on this machine is touched.", w - 2 * px - 12 * S) { text_in(cv, c.f11, l, px + 6 * S, yy, 17 * S, argb(H.dim, 0xff)); yy += 17 * S }
		}
		return
	}
	// the answer column sits 16 px in, behind a rule
	ax := px + 19 * S
	tw_ := w - ax - px
	lines := cl_lines(a, tw_)
	lh := 19 * S
	y += 14 * S
	avail := max((bottom - 14 * S - y) / lh, 1)
	c.scroll = clamp(c.scroll, 0, max(len(lines) - avail, 0))
	first := max(len(lines) - avail - c.scroll, 0)
	yy := y
	last_y, last_x := -1, 0
	tint := argb(H.acc, 0x26)
	for i in first ..< min(first + avail, len(lines)) {
		l := lines[i]
		fade :: proc(col, bg: u32, op: bool) -> u32 { return op ? mix(col, bg, 0.45) : col }
		rule := l.op ? H.line : mix(H.bg, H.acc, 0.5)
		if l.kind != 5 && l.kind != 6 do fill_rect(cv, px + 3 * S, yy, S, lh, argb(rule, 0xff))
		switch l.kind {
		case 5: // the question, its time and model at the right
			text_in(cv, c.f12b, l.mark != "" ? "›" : "", px, yy, lh, argb(fade(H.fg, H.bg, l.op), 0xff))
			qf := l.op ? c.f12b : c.f13b
			text_in(cv, qf, l.s, px + 16 * S, yy, lh, argb(fade(H.fg, H.bg, l.op), 0xff))
			if l.mark != "" do text_in(cv, c.f9, l.mark, w - px - tw(c.f9, l.mark), yy, lh, argb(H.faint, 0xff))
		case 8: // working: three dots and the model
			ph := int(time.duration_milliseconds(time.tick_since(c.pn.loaded_at)) / 400) % 3
			for d in 0 ..< 3 do fill_rect(cv, ax + d * 9 * S, yy + (lh - 6 * S) / 2, 6 * S, 6 * S, argb(H.acc, d == ph ? 0xff : 0x50))
			text_in(cv, c.f11, l.s, ax + 34 * S, yy, lh, argb(H.dim, 0xff))
		case 1:
			text_in(cv, c.f12b, l.s, ax, yy, lh, argb(fade(H.fg, H.bg, l.op), 0xff))
			hx := ax + tw(c.f12b, l.s) + 8 * S
			fill_rect(cv, hx, yy + lh / 2, w - px - hx, S, argb(H.line, 0xff))
		case 2:
			mw := 16 * S
			if l.mark != "" do text_in(cv, c.f12, l.mark, ax + mw - tw(c.f12, l.mark), yy, lh, argb(fade(H.acc, H.bg, l.op), 0xff))
			last_x = cl_inline(cv, c.f12, l.s, ax + mw + 8 * S, yy, lh, fade(soft, H.bg, l.op), fade(H.acc, H.bg, l.op), tint, l.code_on)
			last_y = yy
		case 0:
			last_x = cl_inline(cv, c.f12, l.s, ax, yy, lh, fade(soft, H.bg, l.op), fade(H.acc, H.bg, l.op), tint, l.code_on)
			last_y = yy
		case 4: // the code block's head: its language, and ^K
			fill_rect(cv, ax, yy, tw_, lh, argb(H.acc, 0x10))
			rounded_rect(cv, ax, yy, tw_, lh + S, 0, 0, f32(S), argb(H.line, 0xff))
			spaced(cv, c.f9b, strings.to_upper(l.s != "" ? l.s : "code", context.temp_allocator), ax + 10 * S, yy, lh, soft, S)
			if !l.op do text_in(cv, c.f9, "^K copies the last block", ax + tw_ - 10 * S - tw(c.f9, "^K copies the last block"), yy, lh, argb(H.dim, 0xff))
		case 3:
			fill_rect(cv, ax, yy, tw_, lh, argb(H.acc, 0x10))
			fill_rect(cv, ax, yy, S, lh, argb(H.line, 0xff)); fill_rect(cv, ax + tw_ - S, yy, S, lh, argb(H.line, 0xff))
			cc := strings.has_prefix(strings.trim_space(l.s), "[") ? H.acc : (strings.contains(l.s, "=") ? H.fg : soft)
			text_in(cv, c.f11, ellipsize(c.f11, l.s, tw_ - 20 * S), ax + 10 * S, yy, lh, argb(fade(cc, H.bg, l.op), 0xff))
			last_y, last_x = yy, ax + 10 * S + tw(c.f11, ellipsize(c.f11, l.s, tw_ - 20 * S))
		case 9: fill_rect(cv, ax, yy, tw_, S, argb(H.line, 0xff))
		case 7: text_in(cv, c.f11, l.s, ax, yy, lh, argb(H.hot, 0xff))
		}
		yy += lh
	}
	if panel_streaming(&c.pn) && !c.waiting && c.scroll == 0 && last_y >= 0 { // the caret at the end, blinking
		if int(time.duration_milliseconds(time.tick_since(c.pn.loaded_at)) / 500) % 2 == 0 do fill_rect(cv, last_x + 2 * S, last_y + 4 * S, 7 * S, lh - 8 * S, argb(H.acc, 0xff))
	}
	if c.scroll > 0 {
		s := fmt.tprintf("↓ %d more lines", c.scroll)
		text_in(cv, c.f10, s, w - px - tw(c.f10, s), bottom - 18 * S, 14 * S, argb(H.acc, 0xff))
	}
}

@(private = "file")
cl_draw_sessions :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, top, bottom, px: int, now: i64) {
	c := C(a)
	w := cv.w
	x0, x1 := 8 * S, w - 8 * S
	y := top + 8 * S
	hy :: proc(c: ^Claude, S: int) -> int { return 8 * S + int(c.f10b.line_h) + 4 * S }
	row_frame :: proc(a: ^App, cv: ^Canvas, S, x0, x1, y, rh: int, H: HUD, on, hot: bool) {
		if !on && !hot do return
		edge := hot ? H.hot : H.acc
		fill_rect(cv, x0, y, x1 - x0, rh, argb(edge, 0x12))
		rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(edge, 0xff))
		fill_rect(cv, x0, y, 3 * S, rh, argb(edge, 0xff))
		mark_sel(a, x0, y, x1 - x0, rh)
	}
	if c.picking {
		panel_group(a, cv, S, px, y + 8 * S, int(c.f10b.line_h), H, "NEW SESSION IN…", "recent projects · ↵ starts claude there")
		y += hy(c, S)
		for p, i in c.projects {
			rh := 44 * S
			if y + rh > bottom - 4 * S do break
			on := i == c.cur
			row_frame(a, cv, S, x0, x1, y, rh, H, on, false)
			panel_tag(cv, c.f9b, x0 + 10 * S, y + (rh - 15 * S) / 2, 58 * S, 15 * S, S, "NEW", H.acc)
			lx := x0 + 10 * S + 58 * S + 10 * S
			ly := y + (rh - int(c.f12b.line_h) - 3 * S - int(c.f10.line_h)) / 2
			text_in(cv, c.f12b, ellipsize(c.f12b, cl_home(p.dir), x1 - 10 * S - lx), lx, ly, int(c.f12b.line_h), argb(H.fg, 0xff))
			text_in(cv, c.f10, ellipsize(c.f10, p.sub, x1 - 10 * S - lx), lx, ly + int(c.f12b.line_h) + 3 * S, int(c.f10.line_h), argb(H.dim, 0xff))
			hit_add(a, x0, y, x1 - x0, rh, .Row, i, 0)
			y += rh + 2 * S
		}
		return
	}
	if len(c.sessions) == 0 {
		text_in(cv, c.f12b, "No Claude Code sessions running", px, y + 8 * S, 18 * S, argb(H.fg, 0xff))
		text_in(cv, c.f11, "n starts one in a recent project. The bar module hides until one runs.", px, y + 30 * S, 16 * S, argb(H.dim, 0xff))
		return
	}
	group := -1
	for s, i in c.sessions {
		g := cl_rank(s.status)
		if g != group {
			group = g
			n := 0
			for x in c.sessions do if cl_rank(x.status) == g do n += 1
			heads := [3]string{"NEEDS YOU", "WORKING", "IDLE"}
			if y + hy(c, S) > bottom - 4 * S do break
			spaced(cv, c.f10b, heads[g], px, y + 8 * S, int(c.f10b.line_h), g == 0 ? H.hot : H.dim, S)
			text_in(cv, c.f10, fmt.tprint(n), px + spaced_w(c.f10b, heads[g], S) + 8 * S, y + 8 * S, int(c.f10b.line_h), argb(H.faint, 0xff))
			y += hy(c, S)
		}
		on := i == c.cur
		waiting := s.status == "waiting"
		asking := c.ask_stop != "" && c.ask_stop == s.bgid
		head_h := int(c.f12b.line_h) + 3 * S + int(c.f10.line_h)
		rh := 8 * S + head_h + 8 * S
		if on do rh += 7 * S + 22 * S
		if y + rh > bottom - 4 * S do break
		row_frame(a, cv, S, x0, x1, y, rh, H, on, asking || (on && waiting))
		tag, tc := "IDLE", H.dim
		if s.status == "busy" do tag, tc = "WORKING", H.acc
		if waiting do tag, tc = "WAITS", H.hot
		panel_tag(cv, c.f9b, x0 + 10 * S, y + 8 * S + (head_h - 15 * S) / 2, 58 * S, 15 * S, S, tag, tc, waiting ? argb(H.hot, 0x14) : 0)
		lx := x0 + 10 * S + 58 * S + 10 * S
		ago := cl_ago(s.since, now)
		rx := x1 - 10 * S - tw(c.f10, ago)
		text_in(cv, c.f10, ago, rx, y + 8 * S, head_h, argb(waiting ? H.hot : H.dim, 0xff))
		nm := s.name != "" ? s.name : cl_home(s.cwd)
		text_in(cv, c.f12b, ellipsize(c.f12b, nm, rx - 10 * S - lx), lx, y + 8 * S, int(c.f12b.line_h), argb(H.fg, 0xff))
		what := waiting ? (s.waiting != "" ? s.waiting : "input needed") : (s.status == "busy" ? "working" : "idle")
		if s.kind == "background" do what = strings.concatenate({"background · ", what}, context.temp_allocator)
		sub := fmt.tprintf("%s · %s", cl_home(s.cwd), what)
		if asking do sub = "Stop this background session? y / n · its unsaved edits stay on disk"
		text_in(cv, c.f10, ellipsize(c.f10, sub, rx - 10 * S - lx), lx, y + 8 * S + int(c.f12b.line_h) + 3 * S, int(c.f10.line_h), argb(asking ? H.hot : (waiting ? mix(H.fg, H.bg, 0.2) : H.dim), 0xff))
		hit_add(a, x0, y, x1 - x0, on ? 8 * S + head_h : rh, .Row, i, 0)
		if on { // the picked row's buttons
			by := y + 8 * S + head_h + 7 * S
			bx := lx
			if asking {
				bx += panel_btn(a, cv, S, bx, by, 22 * S, H, "Stop", "y", .Hot, 11) + 6 * S
				panel_btn(a, cv, S, bx, by, 22 * S, H, "Keep", "n", .Plain, 12)
			} else {
				bx += panel_btn(a, cv, S, bx, by, 22 * S, H, waiting ? "Answer in terminal" : "Open", "↵", .Prime, 10) + 6 * S
				if s.kind == "background" do panel_btn(a, cv, S, bx, by, 22 * S, H, "Stop", "x", .Plain, 11)
			}
		}
		y += rh + 2 * S
	}
}

@(private = "file")
cl_draw_usage :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, top, bottom, px: int) {
	c := C(a)
	th := a.theme
	w := cv.w
	y := top + 14 * S
	if len(c.uses) == 0 {
		for l in wrap_text(c.f11, "Claude Code hasn’t reported plan limits yet. They arrive with the next answer (Ask), or from Claude Code’s status line once k4 runs it.", w - 2 * px) { text_in(cv, c.f11, l, px, y, 16 * S, argb(H.dim, 0xff)); y += 16 * S }
		return
	}
	for u in c.uses {
		ch := 10 * S + 22 * S + 6 * S + 8 * S + 6 * S + 14 * S + 10 * S
		if y + ch > bottom - 4 * S do break
		col := u.used >= 0.95 ? H.hot : (u.used >= 0.8 ? th.yellow : H.fg)
		bd := u.used >= 0.95 ? mix(H.bg, H.hot, 0.55) : H.line
		fill_rect(cv, px, y, w - 2 * px, ch, argb(th.fg, 0x0d))
		rounded_rect(cv, px, y, w - 2 * px, ch, 0, 0, f32(S), argb(bd, 0xff))
		ix, iw := px + 12 * S, w - 2 * px - 24 * S
		yy := y + 10 * S
		pct := fmt.tprintf("%d%%", int(u.used * 100 + 0.5))
		text_in(cv, c.f12b, u.label, ix, yy, 22 * S, argb(H.fg, 0xff))
		text_in(cv, c.f24, pct, ix + iw - tw(c.f24, pct), yy, 22 * S, argb(col, 0xff))
		yy += 22 * S + 6 * S
		fill_rect(cv, ix, yy, iw, 8 * S, argb(H.line, 0xff))
		fw := int(f32(iw) * clamp(u.used, 0, 1))
		if u.used >= 1 { // reached: stripes
			for sx := 0; sx < fw; sx += 12 * S do fill_rect(cv, ix + sx, yy, min(6 * S, fw - sx), 8 * S, argb(H.hot, 0xff))
			for sx := 6 * S; sx < fw; sx += 12 * S do fill_rect(cv, ix + sx, yy, min(6 * S, fw - sx), 8 * S, argb(H.hot, 0x88))
		} else do fill_rect(cv, ix, yy, fw, 8 * S, argb(u.used >= 0.95 ? H.hot : (u.used >= 0.8 ? th.yellow : H.acc), 0xff))
		fill_rect(cv, ix + iw * 8 / 10, yy - 2 * S, S, 12 * S, argb(H.dim, 0xff)) // the 80% mark
		yy += 8 * S + 6 * S
		note, nc := "", H.dim
		switch {
		case u.used >= 1: note, nc = "limit reached", H.hot
		case u.used >= 0.95: note, nc = "almost out", H.hot
		case u.used >= 0.8: note, nc = "over 80%: the chip shows it", th.yellow
		}
		text_in(cv, c.f10, note, ix, yy, 14 * S, argb(nc, 0xff))
		text_in(cv, c.f10, u.text, ix + iw - tw(c.f10, u.text), yy, 14 * S, argb(H.dim, 0xff))
		y += ch + 12 * S
	}
}

cl_dump :: proc(a: ^App) -> string {
	c := C(a)
	sb := strings.builder_make(context.temp_allocator)
	pages := [3]string{"ask", "sessions", "usage"}
	fmt.sbprintfln(&sb, "claude %s · %s · %d sessions%s", pages[c.page], c.model, len(c.sessions), c.logged_in ? "" : " · not logged in")
	switch c.page {
	case 0:
		for t in c.turns { fmt.sbprintfln(&sb, "q %s · %s", t.q, t.meta); if len(t.a) > 0 do fmt.sbprintfln(&sb, "a %s", strings.trim_space(string(t.a[:]))); if t.err != "" do fmt.sbprintfln(&sb, "err %s", t.err) }
		if c.limit_msg != "" do fmt.sbprintfln(&sb, "limit %s", c.limit_msg)
		if len(c.q) > 0 do fmt.sbprintfln(&sb, "typing %s", string(c.q[:]))
		if c.sid != "" do fmt.sbprintfln(&sb, "session %s", c.sid)
	case 1:
		if c.picking { for p, i in c.projects do fmt.sbprintfln(&sb, "%s %s", i == c.cur ? "*" : " ", p.dir) }
		else do for s, i in c.sessions do fmt.sbprintfln(&sb, "%s %s %s · %s%s%s", i == c.cur ? "*" : " ", s.status, s.name, s.cwd, s.waiting != "" ? fmt.tprintf(" · %s", s.waiting) : "", c.ask_stop != "" && c.ask_stop == s.bgid ? " · stop? y / n" : "")
	case 2: for u in c.uses do fmt.sbprintfln(&sb, "%s · %d%% · %s", u.label, int(u.used * 100 + 0.5), u.text)
	}
	panel_dump_toast(&c.pn, &sb)
	return strings.to_string(sb)
}
