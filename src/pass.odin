package k4

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --pass: Passwords (the Kestrel design's Passwords, Super+Ctrl+P): the pass store in the
// launcher's 760×600 frame. Typing filters the entries (grouped by folder), ↵ opens one: copy the
// password (↵) or the username (⇧↵; the other way round when the entry says "order: user"),
// open its URL (^O), copy its one-time code (^T), edit (^E), show it in a terminal (^S), delete
// (^D, y / n). Tab shows a password for 5 s. ^N makes an entry (its name, then its password:
// empty generates one), ^G generates a password and copies it, ^L locks or unlocks gpg-agent.
// What is copied clears after 45 s (the footer's bar drains). gpg's own passphrase window can't
// take keys under k4, so a locked store asks for the passphrase here (loopback) and goes on with
// what was asked. The data comes from pass-menu (k4 --pass's panel lines R and L, panel.odin):
//   S <ok|missing|empty> <locked 1|0> <git: "" none | ok | "AHEAD BEHIND"> <origin> <install command>
//   E <path> <changed, e.g. "3 w ago">
// The runner's verbs: fields NAME (prints k4:field user|url|otp|len|order|changed|code VALUE
// [SECS]), copy NAME password|user|otp, reveal NAME, generate, insert NAME [USER] ($K4_INPUT:
// the password; empty generates), unlock ($K4_INPUT), lock, delete NAME, open NAME, edit NAME,
// term NAME, pull, push, install, learn, init. Its directives: k4:locked (ask the passphrase,
// then run it again), k4:copied WHAT, k4:secret TEXT (Tab shows it), k4:unlocked, k4:list.

PASS_W, PASS_H :: 760, 600

Pass_View :: enum { List, Entry, New, Unlock }

Pass_Entry :: struct { path, changed: string }

@(private = "file")
Prow :: struct {
	head:  bool,
	id:    string, // what ↵ does
	label, hit_pre, hit, hit_post: string,
	count: string, // a heading's count
	sub:   string,
	sub_spaced: bool, // a masked password or a code: letter-spaced
	meta:  string,
	mtone: u32,
	key:   string,
	glyph: string,
	danger: bool,
	ring:  f32, // the one-time code's time left, 0–1; < 0 none
}

Pass :: struct {
	using pn: Panel,
	state, git, origin, install: string,
	locked: bool,
	entries: [dynamic]Pass_Entry,
	view: Pass_View,
	q: [dynamic]u8, // the filter, or the new entry's name
	cur: int,
	sel: string, // the list's picked row, by id (the list changes as it loads)
	scroll: int,
	ent: string, // the entry open
	user, url, changed, code: string,
	otp, user_first: bool,
	pwlen: int,
	code_until: time.Tick,
	secret: [dynamic]u8, // a revealed or generated password, wiped when it hides
	secret_until: time.Tick,
	gen: bool, // the notice of a generated password
	copied: string,
	copied_at: time.Tick,
	step: int, // new: 0 the name, 1 the password
	field: int, // new, password step: 0 the password, 1 the username
	newuser: [dynamic]u8,
	ask_del: bool,
	pending: [3]string, // what to run once unlocked
	back: Pass_View, // where Unlock goes back to
}

pass_setup :: proc(a: ^App, data: string) {
	p := new(Pass)
	p.mode = {draw = pass_draw, key = pass_key, click = pass_click, scroll = pass_scroll, loaded = pass_loaded, ran = pass_ran, tick = pass_tick, dump = pass_dump}
	panel_init(a, &p.pn, "pass", data)
	a.width, a.height = PASS_W, PASS_H
}

@(private = "file")
P :: proc(a: ^App) -> ^Pass { return (^Pass)(a.pn) }

@(private = "file")
pass_loaded :: proc(a: ^App, data: string) {
	p := P(a)
	for &e in p.entries { delete(e.path); delete(e.changed) }
	clear(&p.entries)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			delete(p.state); delete(p.git); delete(p.origin); delete(p.install)
			p.state, p.git, p.origin, p.install = strings.clone(fget(f, 1)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5))
			p.locked = fget(f, 2) == "1"
		case "E": append(&p.entries, Pass_Entry{strings.clone(fget(f, 1)), strings.clone(fget(f, 2))})
		}
	}
	if p.state == "" do p.state = "ok"
}

@(private = "file")
pass_ran :: proc(a: ^App, verb, line: string) -> bool {
	p := P(a)
	f := strings.split_n(line, " ", 3, context.temp_allocator)
	switch f[0] {
	case "k4:locked": // run it again once the passphrase is in
		for &x in p.pending do delete(x)
		p.pending = {strings.clone(verb), "", ""}
		if verb == "copy" || verb == "reveal" || verb == "fields" do p.pending[1] = strings.clone(p.ent)
		if verb == "copy" do p.pending[2] = strings.clone(p.copied)
		pass_unlock_view(a)
		p.locked = true
	case "k4:unlocked":
		p.locked = false
		if p.view == .Unlock do p.view = p.back
		if pv := p.pending[0]; pv != "" {
			args := make([dynamic]string, 0, 2, context.temp_allocator)
			if p.pending[1] != "" do append(&args, strings.clone(p.pending[1], context.temp_allocator))
			if p.pending[2] != "" do append(&args, strings.clone(p.pending[2], context.temp_allocator))
			verb2 := strings.clone(pv, context.temp_allocator)
			for &x in p.pending { delete(x); x = "" }
			pass_go(a, verb2, ..args[:])
		}
	case "k4:copied":
		delete(p.copied)
		p.copied = strings.clone(len(f) > 1 ? strings.join(f[1:], " ", context.temp_allocator) : "password")
		p.copied_at = time.tick_now()
		if p.copied == "new password" do p.gen = true
	case "k4:secret":
		pass_wipe(p)
		append(&p.secret, ..transmute([]u8)line[10:])
		p.secret_until = time.tick_add(time.tick_now(), 5 * time.Second)
		if verb == "generate" do p.secret_until = time.tick_add(time.tick_now(), 45 * time.Second) // ^N can still save it
	case "k4:list": p.view = .List; p.ask_del = false; clear(&p.q); p.scroll = 0
	case "k4:field":
		if len(f) < 2 do return false
		kv := strings.split_n(f[1], " ", 2, context.temp_allocator)
		_ = kv
		rest := line[len("k4:field "):]
		sp := strings.index_byte(rest, ' ')
		k, v := rest, ""
		if sp >= 0 do k, v = rest[:sp], rest[sp + 1:]
		switch k {
		case "user": delete(p.user); p.user = strings.clone(v)
		case "url": delete(p.url); p.url = strings.clone(v)
		case "otp": p.otp = v == "1"
		case "len": p.pwlen, _ = strconv.parse_int(v)
		case "order": p.user_first = v == "user"
		case "changed": delete(p.changed); p.changed = strings.clone(v)
		case "code":
			cs := strings.split_n(v, " ", 2, context.temp_allocator)
			delete(p.code); p.code = strings.clone(cs[0])
			left := 30
			if len(cs) > 1 do left, _ = strconv.parse_int(cs[1])
			p.code_until = time.tick_add(time.tick_now(), time.Duration(left) * time.Second)
		}
	case: return false
	}
	return true
}

@(private = "file")
pass_wipe :: proc(p: ^Pass) {
	for &b in p.secret do b = 0
	clear(&p.secret)
}

@(private = "file")
pass_tick :: proc(a: ^App) -> int {
	p := P(a)
	t := -1
	now := time.tick_now()
	if len(p.secret) > 0 {
		if time.tick_diff(now, p.secret_until) <= 0 { pass_wipe(p); p.pn.reveal = false }
		else do t = 200
	}
	if p.copied != "" {
		if time.tick_since(p.copied_at) >= 45 * time.Second {
			delete(p.copied); p.copied = ""
			p.gen = false
			panel_say(&p.pn, "Clipboard cleared", a.theme.fg_dim)
		} else do t = t < 0 ? 250 : min(t, 250)
	}
	if p.view == .Entry && p.otp && p.code != "" {
		if time.tick_diff(now, p.code_until) <= 0 { delete(p.code); p.code = ""; panel_run(a, "fields", p.ent) }
		t = t < 0 ? 500 : min(t, 500)
	}
	return t
}

// Runs a verb, and remembers it for after an unlock.
@(private = "file")
pass_go :: proc(a: ^App, verb: string, args: ..string) {
	p := P(a)
	if verb == "copy" && len(args) > 1 { delete(p.copied); p.copied = strings.clone(args[1]) }
	panel_run(a, verb, ..args)
}

@(private = "file")
pass_unlock_view :: proc(a: ^App) {
	p := P(a)
	if p.view != .Unlock do p.back = p.view
	p.view = .Unlock
	panel_clear(&p.pn)
}

// ---------- the rows ----------

@(private = "file")
pass_q :: proc(p: ^Pass) -> string { return string(p.q[:]) }

@(private = "file")
pass_rows :: proc(a: ^App) -> [dynamic]Prow {
	p := P(a)
	th := a.theme
	rows := make([dynamic]Prow, 0, len(p.entries) + 16, context.temp_allocator)
	R :: proc(rows: ^[dynamic]Prow, r: Prow) { x := r; if x.ring == 0 do x.ring = -1; append(rows, x) }
	Hd :: proc(rows: ^[dynamic]Prow, h, n: string) { append(rows, Prow{head = true, label = h, count = n, ring = -1}) }
	switch {
	case p.state == "missing":
		R(&rows, {id = "install", label = "Install pass", meta = p.install, glyph = "↓", key = "↵"})
		R(&rows, {id = "learn", label = "How pass works", meta = "passwordstore.org ↗", glyph = "?"})
		return rows
	case p.state == "empty":
		R(&rows, {id = "init", label = "Set up the store in a terminal", meta = "pass init <gpg key>", glyph = "+", key = "↵"})
		R(&rows, {id = "learn", label = "How pass works", meta = "passwordstore.org ↗", glyph = "?"})
		return rows
	}
	switch p.view {
	case .List:
		q := strings.to_lower(strings.trim_space(pass_q(p)), context.temp_allocator)
		if q == "" {
			R(&rows, {id = "new", label = "New entry", meta = "name, then password", glyph = "+", key = "^N"})
			R(&rows, {id = "gen", label = "Generate a password", meta = p.gen ? "copied · hidden · Tab shows" : "24 chars, symbols", glyph = "✱", key = "^G"})
			if p.locked do R(&rows, {id = "unlock", label = "Unlock", meta = "asks for the gpg passphrase", glyph = "○", key = "^L"})
			if p.git != "" {
				ahead, behind := 0, 0
				if p.git != "ok" {
					ab := strings.fields(p.git, context.temp_allocator)
					if len(ab) > 0 do ahead, _ = strconv.parse_int(ab[0])
					if len(ab) > 1 do behind, _ = strconv.parse_int(ab[1])
				}
				st := ahead > 0 || behind > 0 ? fmt.tprintf("%d ahead · %d behind", ahead, behind) : "up to date"
				Hd(&rows, "GIT", p.origin != "" ? fmt.tprintf("%s · origin %s", st, p.origin) : st)
				R(&rows, {id = "pull", label = "Pull", meta = behind > 0 ? fmt.tprintf("%d behind", behind) : "up to date", mtone = behind > 0 ? th.yellow : 0, glyph = "↓"})
				R(&rows, {id = "push", label = "Push", meta = ahead > 0 ? fmt.tprintf("%d ahead", ahead) : "nothing to push", mtone = ahead > 0 ? th.yellow : 0, glyph = "↑"})
			}
		}
		folder := "\x00"
		shown := 0
		for e, i in p.entries {
			lp := strings.to_lower(e.path, context.temp_allocator)
			at := q == "" ? 0 : strings.index(lp, q)
			if at < 0 do continue
			sl := strings.index_byte(e.path, '/')
			f := sl >= 0 ? e.path[:sl] : ""
			name := sl >= 0 ? e.path[sl + 1:] : e.path
			if f != folder {
				folder = f
				n := 0
				for e2 in p.entries[i:] {
					s2 := strings.index_byte(e2.path, '/')
					if (s2 >= 0 ? e2.path[:s2] : "") != f do continue
					if q != "" && !strings.contains(strings.to_lower(e2.path, context.temp_allocator), q) do continue
					n += 1
				}
				Hd(&rows, f != "" ? fmt.tprintf("%s/", strings.to_upper(f, context.temp_allocator)) : "TOP", fmt.tprintf("%d %s", n, n == 1 ? "entry" : "entries"))
			}
			r := Prow{id = e.path, label = name, meta = e.changed, glyph = "›"}
			if q != "" { // the match within the name, marked
				nat := strings.index(strings.to_lower(name, context.temp_allocator), q)
				if nat >= 0 do r.hit_pre, r.hit, r.hit_post = name[:nat], name[nat:nat + len(q)], name[nat + len(q):]
			}
			R(&rows, r)
			shown += 1
		}
		if shown == 0 && q != "" do Hd(&rows, fmt.tprintf("NO ENTRY MATCHES “%s”", pass_q(p)), "^N makes one with this name")
	case .Entry:
		mask := strings.repeat("•", min(p.pwlen > 0 ? p.pwlen : 16, 32), context.temp_allocator)
		pw := Prow{id = "pw", label = "Copy password", sub = len(p.secret) > 0 ? strings.clone(string(p.secret[:]), context.temp_allocator) : mask, sub_spaced = true, meta = p.pwlen > 0 ? fmt.tprintf("%d chars", p.pwlen) : "", glyph = "✱", key = p.user_first ? "⇧↵" : "↵"}
		us := Prow{id = "user", label = "Copy username", sub = p.user != "" ? p.user : "no login: line in the entry", glyph = "@", key = p.user_first ? "↵" : "⇧↵"}
		if p.user_first { R(&rows, us); R(&rows, pw) } else { R(&rows, pw); R(&rows, us) }
		if p.url != "" do R(&rows, {id = "url", label = "Open URL", sub = p.url, meta = "↗", glyph = "↗", key = "^O"})
		if p.otp {
			left := p.code != "" ? int(time.duration_seconds(time.tick_diff(time.tick_now(), p.code_until)) + 0.999) : 0
			code := p.code
			if len(code) == 6 do code = fmt.tprintf("%s %s", code[:3], code[3:])
			R(&rows, {id = "otp", label = "One-time code", sub = code != "" ? code : "pass otp", sub_spaced = true, meta = p.code != "" ? fmt.tprintf("%d s", left) : "", ring = p.code != "" ? f32(left) / 30 : -1, mtone = left <= 5 && p.code != "" ? th.red : 0, glyph = "◷", key = "^T"})
		}
		Hd(&rows, "MORE", strings.concatenate({p.changed != "" ? fmt.tprintf("changed %s", p.changed) : "", p.user_first ? " · username first: the entry says order: user" : ""}, context.temp_allocator))
		R(&rows, {id = "edit", label = "Edit", meta = "pass edit · $EDITOR", glyph = "✎", key = "^E"})
		R(&rows, {id = "term", label = "Show in terminal", meta = "pass show", glyph = "›_", key = "^S"})
		R(&rows, {id = "del", label = p.ask_del ? fmt.tprintf("Delete %s? y / n", p.ent) : "Delete", meta = p.ask_del ? "removes it and commits" : "", glyph = "×", danger = true, key = "^D"})
	case .New:
		if p.step == 0 {
			R(&rows, {id = "next", label = "Use this name", meta = len(p.q) > 0 ? pass_q(p) : "type folder/name above", glyph = "›", key = "↵"})
			folders := make([dynamic]string, 0, 8, context.temp_allocator)
			for e in p.entries {
				sl := strings.index_byte(e.path, '/')
				if sl < 0 do continue
				f := e.path[:sl + 1]
				seen := false
				for x in folders do if x == f do seen = true
				if !seen do append(&folders, f)
			}
			if len(folders) > 0 do Hd(&rows, "FOLDERS", "pick one to put it there")
			for f in folders {
				n := 0
				for e in p.entries do if strings.has_prefix(e.path, f) do n += 1
				R(&rows, {id = strings.concatenate({"folder:", f}, context.temp_allocator), label = f, meta = fmt.tprintf("%d entries", n), glyph = "/"})
			}
		} else {
			pwl := panel_masked(&p.pn)
			if len(p.input) == 0 do pwl = p.field == 0 ? "" : "(empty: generated)"
			R(&rows, {id = "pwf", label = pwl, sub = "Leave empty to generate", meta = "Tab shows", glyph = "✱", key = "↵"})
			R(&rows, {id = "userf", label = len(p.newuser) > 0 ? string(p.newuser[:]) : "Username (optional)", sub = "stored as login: in the entry", glyph = "@"})
			R(&rows, {id = "gen2", label = "Generate instead", meta = "24 chars, symbols", glyph = "✱", key = "^G"})
		}
	case .Unlock:
		R(&rows, {id = "unlockf", label = len(p.input) > 0 ? panel_masked(&p.pn) : "", sub = "the passphrase of your gpg key", meta = "Tab shows", glyph = "✱", key = "↵"})
	}
	return rows
}

@(private = "file")
pass_acts :: proc(rows: []Prow) -> [dynamic]int { // the rows ↑↓ move between
	out := make([dynamic]int, 0, len(rows), context.temp_allocator)
	for r, i in rows do if !r.head do append(&out, i)
	return out
}

@(private = "file")
pass_cur :: proc(a: ^App, rows: []Prow, acts: []int) -> int {
	p := P(a)
	if len(acts) == 0 do return -1
	if p.view == .List && p.state == "ok" {
		for ai, k in acts do if rows[ai].id == p.sel do return k
		q := strings.trim_space(pass_q(p))
		if q != "" do for ai, k in acts do if strings.contains(rows[ai].id, "/") || rows[ai].hit != "" do return k
		return 0
	}
	return clamp(p.cur, 0, len(acts) - 1)
}

@(private = "file")
pass_move :: proc(a: ^App, d: int) {
	p := P(a)
	rows := pass_rows(a)
	acts := pass_acts(rows[:])
	if len(acts) == 0 do return
	k := clamp(pass_cur(a, rows[:], acts[:]) + d, 0, len(acts) - 1)
	p.cur = k
	delete(p.sel)
	p.sel = strings.clone(rows[acts[k]].id)
	p.ask_del = false
	if p.view == .New && p.step == 1 do p.field = rows[acts[k]].id == "userf" ? 1 : 0
	panel_say(&p.pn, "")
}

@(private = "file")
pass_open :: proc(a: ^App, path: string) {
	p := P(a)
	delete(p.ent)
	p.ent = strings.clone(path)
	delete(p.user); delete(p.url); delete(p.changed); delete(p.code)
	p.user, p.url, p.changed, p.code = "", "", "", ""
	p.otp, p.user_first, p.pwlen = false, false, 0
	for e in p.entries do if e.path == path do p.changed = strings.clone(e.changed)
	p.view, p.cur, p.ask_del = .Entry, 0, false
	pass_wipe(p)
	panel_say(&p.pn, "")
	panel_run(a, "fields", path)
}

@(private = "file")
pass_back :: proc(a: ^App) {
	p := P(a)
	if p.view == .Unlock { p.view = p.back; panel_clear(&p.pn); for &x in p.pending { delete(x); x = "" }; return }
	if p.view == .New { panel_clear(&p.pn); clear(&p.newuser); clear(&p.q) }
	p.view, p.ask_del = .List, false
	pass_wipe(p)
	p.pn.reveal = false
	panel_say(&p.pn, "")
}

@(private = "file")
pass_new :: proc(a: ^App) {
	p := P(a)
	if p.view != .List do clear(&p.q)
	p.view, p.step, p.cur, p.field = .New, 0, 0, 0
	panel_clear(&p.pn)
	clear(&p.newuser)
	panel_say(&p.pn, "")
}

// ↵ on a row.
@(private = "file")
pass_do :: proc(a: ^App, id: string) {
	p := P(a)
	switch {
	case id == "install" || id == "learn" || id == "init" || id == "pull" || id == "push" || id == "lock": panel_run(a, id)
	case id == "new": pass_new(a)
	case id == "gen" || id == "gen2":
		if p.view == .New && p.step == 1 { panel_clear(&p.pn); pass_save(a); return }
		panel_run(a, "generate")
	case id == "unlock": pass_unlock_view(a)
	case id == "unlockf":
		if len(p.input) == 0 { panel_say(&p.pn, "Type the passphrase first", a.theme.yellow); return }
		panel_run(a, "unlock", secret = strings.clone(panel_text(&p.pn), context.temp_allocator))
		panel_clear(&p.pn)
	case id == "pw": pass_go(a, "copy", p.ent, "password")
	case id == "user": if p.user != "" do pass_go(a, "copy", p.ent, "user")
	case id == "otp": pass_go(a, "copy", p.ent, "otp")
	case id == "url": panel_run(a, "open", p.ent)
	case id == "edit": panel_run(a, "edit", p.ent)
	case id == "term": panel_run(a, "term", p.ent)
	case id == "del":
		if p.ask_del { p.ask_del = false; panel_run(a, "delete", p.ent); return }
		p.ask_del = true
		rows := pass_rows(a) // the question is on the Delete row: picked, so ↵ answers it too
		for ai, k in pass_acts(rows[:]) do if rows[ai].id == "del" do p.cur = k
	case id == "next":
		if len(p.q) == 0 || strings.has_suffix(pass_q(p), "/") { panel_say(&p.pn, "Type a name: folder/name", a.theme.yellow); return }
		p.step, p.cur, p.field = 1, 0, 0
		panel_clear(&p.pn)
	case strings.has_prefix(id, "folder:"): clear(&p.q); append(&p.q, ..transmute([]u8)id[7:])
	case id == "pwf" || id == "userf": pass_save(a)
	case strings.contains(id, "/") || p.view == .List: pass_open(a, id)
	}
}

@(private = "file")
pass_save :: proc(a: ^App) {
	p := P(a)
	args := make([dynamic]string, 0, 2, context.temp_allocator)
	append(&args, strings.clone(pass_q(p), context.temp_allocator))
	if len(p.newuser) > 0 do append(&args, strings.clone(string(p.newuser[:]), context.temp_allocator))
	pw := strings.clone(panel_text(&p.pn), context.temp_allocator)
	panel_clear(&p.pn)
	if p.pn.runner == "" { panel_say(&p.pn, fmt.tprintf("(insert %s)", args[0])); return }
	panel_run(a, "insert", ..args[:], secret = pw == "" ? "-" : pw)
}

pass_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	p := P(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	rows := pass_rows(a)
	acts := pass_acts(rows[:])
	ci := pass_cur(a, rows[:], acts[:])
	cur_id := ci >= 0 ? rows[acts[ci]].id : ""
	if p.state != "ok" {
		switch {
		case k == .Down: pass_move(a, 1)
		case k == .Up: pass_move(a, -1)
		case k == .Enter: if cur_id != "" do pass_do(a, cur_id)
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	if p.ask_del && (text == "y" || text == "n") { if text == "y" do pass_do(a, "del"); else do p.ask_del = false; return true }
	switch {
	case k == .Down || (ctrl && ch == 'j'): pass_move(a, 1); return true
	case k == .Up || (ctrl && ch == 'k'): pass_move(a, -1); return true
	case k == .Tab:
		p.pn.reveal = !p.pn.reveal
		if p.view == .Entry && len(p.secret) == 0 && p.pn.reveal { panel_run(a, "reveal", p.ent); p.pn.reveal = false }
		else if len(p.secret) > 0 && p.view != .New && p.view != .Unlock { pass_wipe(p); p.pn.reveal = false }
		return true
	}
	if ctrl {
		switch ch {
		case 'n':
			name := strings.clone(pass_q(p), context.temp_allocator)
			if p.view == .List && p.gen && len(p.secret) > 0 { // save the generated one
				pass_new(a)
				append(&p.input, ..p.secret[:])
				return true
			}
			pass_new(a)
			append(&p.q, ..transmute([]u8)name)
		case 'g':
			if p.view == .New && p.step == 1 { pass_do(a, "gen2") } else if p.view == .List do panel_run(a, "generate")
		case 'l': if p.view != .Unlock { if p.locked do pass_unlock_view(a); else do panel_run(a, "lock") }
		case 'o': if p.view == .Entry && p.url != "" do pass_do(a, "url")
		case 't': if p.view == .Entry && p.otp do pass_do(a, "otp")
		case 'e': if p.view == .Entry do pass_do(a, "edit")
		case 's': if p.view == .Entry do pass_do(a, "term")
		case 'd': if p.view == .Entry do pass_do(a, "del")
		case 'u': clear(&p.q)
		case: return false
		}
		return true
	}
	switch p.view {
	case .List:
		switch {
		case k == .Enter: if cur_id != "" do pass_do(a, cur_id)
		case k == .Backspace:
			if len(p.q) > 0 { _, n := utf8.decode_last_rune(p.q[:]); resize(&p.q, len(p.q) - n); delete(p.sel); p.sel = "" }
		case k == .Escape:
			if len(p.q) > 0 { clear(&p.q); delete(p.sel); p.sel = "" } else do panel_close(a)
		case text != "" && k == .None:
			append(&p.q, ..transmute([]u8)text)
			delete(p.sel); p.sel = ""
			panel_say(&p.pn, "")
		case: return false
		}
	case .Entry:
		switch {
		case k == .Enter:
			if a.shift { if len(acts) > 1 do pass_do(a, rows[acts[1]].id) } else if !p.ask_del || cur_id == "del" do pass_do(a, ci >= 0 ? cur_id : "pw")
		case k == .Backspace || k == .Escape: if p.ask_del do p.ask_del = false; else do pass_back(a)
		case: return false
		}
	case .New:
		if p.step == 0 {
			switch {
			case k == .Enter: pass_do(a, cur_id == "" || cur_id == "next" ? "next" : cur_id)
			case k == .Backspace:
				if len(p.q) == 0 do pass_back(a)
				else { _, n := utf8.decode_last_rune(p.q[:]); resize(&p.q, len(p.q) - n) }
			case k == .Escape: pass_back(a)
			case text != "" && k == .None: append(&p.q, ..transmute([]u8)text)
			case: return false
			}
		} else {
			switch {
			case k == .Enter: if cur_id == "gen2" do pass_do(a, "gen2"); else do pass_save(a)
			case k == .Backspace:
				if p.field == 1 { if len(p.newuser) > 0 { _, n := utf8.decode_last_rune(p.newuser[:]); resize(&p.newuser, len(p.newuser) - n) } }
				else if !panel_bs(&p.pn) { p.step = 0; p.cur = 0 }
			case k == .Escape: pass_back(a)
			case text != "" && k == .None:
				if p.field == 1 do append(&p.newuser, ..transmute([]u8)text)
				else do panel_type(&p.pn, text)
			case: return false
			}
		}
	case .Unlock:
		switch {
		case k == .Enter: pass_do(a, "unlockf")
		case k == .Backspace: if !panel_bs(&p.pn) do pass_back(a)
		case k == .Escape: pass_back(a)
		case text != "" && k == .None: panel_type(&p.pn, text)
		case: return false
		}
	}
	return true
}

pass_click :: proc(a: ^App, x, y, button: int) -> bool {
	p := P(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row:
		rows := pass_rows(a)
		acts := pass_acts(rows[:])
		ci := pass_cur(a, rows[:], acts[:])
		for ai, k in acts do if ai == h.a {
			if k == ci { pass_do(a, rows[ai].id) } else { p.cur = k; delete(p.sel); p.sel = strings.clone(rows[ai].id); if p.view == .New && p.step == 1 do p.field = rows[ai].id == "userf" ? 1 : 0 }
		}
	case .Confirm: if p.locked do pass_unlock_view(a); else do panel_run(a, "lock")
	}
	return true
}

pass_scroll :: proc(a: ^App, n: int) -> bool { pass_move(a, n); return true }

// ---------- drawing ----------

pass_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	p := P(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	// the head: crumb, the field, the lock
	crumb := "APPS › PASSWORDS"
	switch p.view {
	case .Entry:
		sl := strings.index_byte(p.ent, '/')
		crumb = sl >= 0 ? fmt.tprintf("PASSWORDS › %s", strings.to_upper(p.ent[:sl], context.temp_allocator)) : "PASSWORDS"
	case .New: crumb = "PASSWORDS › NEW"
	case .Unlock: crumb = "PASSWORDS › UNLOCK"
	case .List:
	}
	lock_l, lock_c, lock_on := p.locked ? "LOCKED" : "UNLOCKED", p.locked ? th.yellow : th.green, !p.locked
	if p.state != "ok" do lock_l, lock_c, lock_on = "NO STORE", H.dim, false
	lw := tw(p.f10b, lock_l) + 6 * S + 5 * S + 16 * S
	hh, px, fx := panel_head(a, cv, S, H, crumb, "", true, lw)
	lx := panel_state(a, cv, S, w - px, hh, lock_l, lock_c, lock_on, true)
	hit_add(a, lx, (hh - 24 * S) / 2, w - px - lx, 24 * S, .Confirm, 0, 0)
	field, ph := pass_q(p), ""
	switch p.view {
	case .List: ph = p.state == "ok" ? fmt.tprintf("Filter %d entries…", len(p.entries)) : ""
	case .Entry:
		sl := strings.index_byte(p.ent, '/')
		field = sl >= 0 ? p.ent[sl + 1:] : p.ent
	case .New: ph = "folder/name, e.g. shopping/ikea"; if p.step == 1 do ph = ""
	case .Unlock: field = ""; ph = "gpg passphrase below"
	}
	fw := lx - 12 * S - fx
	if field != "" {
		s := ellipsize(p.f15, field, fw - 10 * S)
		text_in(cv, p.f15, s, fx, 0, hh, argb(p.view == .Entry ? H.fg : H.fg, 0xff))
		if (p.view == .List || (p.view == .New && p.step == 0)) do fill_rect(cv, fx + tw(p.f15, s) + S, (hh - 18 * S) / 2, 2 * S, 18 * S, argb(H.acc, 0xff))
	} else {
		if p.view == .List || (p.view == .New && p.step == 0) do fill_rect(cv, fx, (hh - 18 * S) / 2, 2 * S, 18 * S, argb(H.acc, 0xff))
		text_in(cv, p.f15, ellipsize(p.f15, ph, fw), fx + 6 * S, 0, hh, argb(H.faint, 0xff))
	}
	// the notice
	y := hh + S
	nt, nb: string
	nc := H.acc
	switch {
	case p.state == "missing": nt, nb, nc = "pass is not installed", "The Passwords page reads ~/.password-store with pass and gpg. Install it, then run pass init with your gpg key.", th.yellow
	case p.state == "empty": nt, nb, nc = "The store is not set up", "There is no ~/.password-store/.gpg-id yet. pass init with your gpg key makes one; then entries show up here.", th.yellow
	case p.view == .List && p.gen && p.copied == "new password":
		nt = "New password copied"
		nb = len(p.secret) > 0 && p.pn.reveal ? fmt.tprintf("%s   (hidden again in 5 s)", string(p.secret[:])) : "Hidden: ••••••••••••••••••••••••   Tab shows it for 5 s · ^N saves it as an entry"
	case p.view == .Entry && p.locked: nt, nb, nc = "Locked", "The first copy asks for your gpg passphrase here; then copies are instant for 10 min.", th.yellow
	case p.view == .New && p.step == 1: nt, nb = fmt.tprintf("Password for %s", pass_q(p)), "Type it below, or leave it empty and press ↵ to generate 24 characters. Tab shows what you typed."
	case p.view == .Unlock: nt, nb, nc = "Unlock the password store", "Type the passphrase of your gpg key. gpg-agent keeps it for 10 min; then k4 goes on with what you asked.", th.yellow
	}
	if nt != "" do y += 10 * S + panel_notice(a, cv, S, px, y + 10 * S, w - 2 * px, H, nt, nb, nc)
	// the rows, scrolled to keep the picked one in view
	fh := 40 * S
	fy := h - fh
	ly := y + 6 * S
	lh := fy - 8 * S - ly
	rows := pass_rows(a)
	acts := pass_acts(rows[:])
	ci := pass_cur(a, rows[:], acts[:])
	cur_row := ci >= 0 ? acts[ci] : -1
	ys := make([dynamic]int, 0, len(rows), context.temp_allocator)
	yy := 0
	for r in rows {
		append(&ys, yy)
		yy += r.head ? 7 * S + int(p.f10b.line_h) + 3 * S : (r.sub != "" ? 42 * S : 30 * S)
	}
	if cur_row >= 0 {
		rh := rows[cur_row].sub != "" ? 42 * S : 30 * S
		top := ys[cur_row]
		if cur_row > 0 && rows[cur_row - 1].head do top = ys[cur_row - 1] // its heading too
		if top < p.scroll do p.scroll = top
		if ys[cur_row] + rh > p.scroll + lh do p.scroll = ys[cur_row] + rh - lh
	}
	p.scroll = clamp(p.scroll, 0, max(yy - lh, 0))
	list := Canvas{cv.px[ly * w:], w, lh}
	nh := len(a.hits)
	for r, i in rows {
		ry := ys[i] - p.scroll
		if ry > lh do break
		if r.head {
			if ry + 20 * S < 0 do continue
			hy := ry + 7 * S
			spaced(&list, p.f10b, r.label, 22 * S, hy, int(p.f10b.line_h), r.count == "^N makes one with this name" ? H.dim : H.dim, S)
			text_in(&list, p.f10, ellipsize(p.f10, r.count, w - 44 * S - spaced_w(p.f10b, r.label, S)), 22 * S + spaced_w(p.f10b, r.label, S) + 8 * S, hy, int(p.f10b.line_h), argb(H.faint, 0xff))
			continue
		}
		rh := r.sub != "" ? 42 * S : 30 * S
		if ry + rh < 0 do continue
		on := i == cur_row
		tone := r.danger ? H.hot : H.acc
		x0, x1 := 10 * S, w - 10 * S
		if on { fill_rect(&list, x0, ry, x1 - x0, rh, argb(tone, 0xff)); mark_sel(a, x0, ry + ly, x1 - x0, rh) }
		fg := on ? H.bg : (r.danger ? H.hot : H.fg)
		gx := x0 + 12 * S
		text_in(&list, p.f11b, r.glyph, gx, ry, rh, argb(on ? H.bg : (r.danger ? H.hot : H.acc), 0xff))
		tx := gx + 14 * S + 12 * S
		// the right-hand side: key chip, meta, ring
		rx := x1 - 12 * S
		if r.key != "" {
			kw := max(22 * S, tw(p.f10b, r.key) + 8 * S)
			rx -= kw
			fill_rect(&list, rx, ry + (rh - 16 * S) / 2, kw, 16 * S, on ? argb(H.bg, 0xff) : argb(a.theme.fg, 0x0d))
			text_in(&list, p.f10b, r.key, rx + (kw - tw(p.f10b, r.key)) / 2, ry + (rh - 16 * S) / 2, 16 * S, argb(on ? tone : soft, 0xff))
			rx -= 12 * S
		}
		if r.meta != "" {
			mw := tw(p.f11, r.meta)
			mc := on ? H.bg : (r.mtone != 0 ? r.mtone : H.dim)
			text_in(&list, p.f11, r.meta, rx - mw, ry, rh, argb(mc, 0xff))
			rx -= mw + 12 * S
		}
		if r.ring >= 0 { // the code's time left: a filled square that empties
			rc := on ? H.bg : (r.mtone != 0 ? r.mtone : H.acc)
			rounded_rect(&list, rx - 14 * S, ry + (rh - 14 * S) / 2, 14 * S, 14 * S, 0, 0, f32(S), argb(rc, 0xff))
			fh2 := int(f32(12 * S) * clamp(r.ring, 0, 1))
			fill_rect(&list, rx - 13 * S, ry + (rh - 14 * S) / 2 + S + 12 * S - fh2, 12 * S, fh2, argb(rc, 0xff))
			rx -= 14 * S + 12 * S
		}
		lf := on ? p.f13b : p.f13
		ly2 := r.sub != "" ? ry + (rh - int(lf.line_h) - 2 * S - int(p.f10.line_h)) / 2 : ry + (rh - int(lf.line_h)) / 2
		if r.hit != "" { // the filter's match in the accent
			xx := tx
			text_in(&list, lf, r.hit_pre, xx, ly2, int(lf.line_h), argb(fg, 0xff)); xx += tw(lf, r.hit_pre)
			text_in(&list, p.f13b, r.hit, xx, ly2, int(lf.line_h), argb(on ? H.bg : H.acc, 0xff)); xx += tw(p.f13b, r.hit)
			text_in(&list, lf, ellipsize(lf, r.hit_post, rx - xx), xx, ly2, int(lf.line_h), argb(fg, 0xff))
		} else {
			lab := r.label
			if r.id == "pwf" || r.id == "unlockf" || r.id == "userf" { // a field: the caret when typing goes there
				typing := (r.id == "pwf" && p.field == 0) || (r.id == "userf" && p.field == 1) || r.id == "unlockf"
				text_in(&list, lf, ellipsize(lf, lab, rx - tx - 8 * S), tx, ly2, int(lf.line_h), argb(fg, 0xff))
				if typing && on do fill_rect(&list, tx + tw(lf, ellipsize(lf, lab, rx - tx - 8 * S)) + 2 * S, ly2 + 2 * S, 7 * S, int(lf.line_h) - 4 * S, argb(H.bg, 0xff))
			} else do text_in(&list, lf, ellipsize(lf, lab, rx - tx), tx, ly2, int(lf.line_h), argb(fg, 0xff))
		}
		if r.sub != "" {
			sc := on ? H.bg : H.dim
			sy := ly2 + int(lf.line_h) + 2 * S
			if r.sub_spaced do spaced(&list, p.f10, spaced_fit(p.f10, r.sub, S, rx - tx), tx, sy, int(p.f10.line_h), sc, S)
			else do text_in(&list, p.f10, ellipsize(p.f10, r.sub, rx - tx), tx, sy, int(p.f10.line_h), argb(sc, 0xff))
		}
		hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
	}
	for &hh2 in a.hits[nh:] { // the list's hits in window coordinates, cut to its box
		hh2.y += ly
		y0, y1 := max(hh2.y, ly), min(hh2.y + hh2.h, ly + lh)
		hh2.y, hh2.h = y0, max(y1 - y0, 0)
	}
	// the footer: what is copied (a bar that drains over 45 s), or the keys
	hints: [][2]string
	switch p.view {
	case .List: hints = {{"type", "Filter"}, {"↵", "Open"}, {"^N ^G ^L", "New · Generate · Lock"}, {"Esc", "Close"}}
	case .Entry: hints = {{"↵", p.user_first ? "Copy username" : "Copy password"}, {"⇧↵", p.user_first ? "Password" : "Username"}, {"Tab", "Show"}, {"⌫", "Back"}, {"Esc", "Close"}}
	case .New: hints = {{"↵", p.step == 0 ? "Next" : "Save"}, {"Tab", "Show"}, {"⌫", "Back"}}
	case .Unlock: hints = {{"↵", "Unlock"}, {"Tab", "Show"}, {"Esc", "Back"}}
	}
	keep := p.pn.toast
	if p.copied != "" {
		left := 45 - time.duration_seconds(time.tick_since(p.copied_at))
		p.pn.toast = fmt.tprintf("Copied %s · clears in %d s%s", p.copied, int(max(left, 0) + 0.5), keep != "" && !strings.has_prefix(keep, "Copied") ? fmt.tprintf(" · %s", keep) : "")
	}
	tone := p.pn.tone
	if p.copied != "" do p.pn.tone = 0
	panel_foot(a, cv, S, H, hints, true)
	p.pn.toast, p.pn.tone = keep, tone
	if p.copied != "" {
		frac := 1 - f32(time.duration_seconds(time.tick_since(p.copied_at))) / 45
		fill_rect(cv, 0, fy - S, int(f32(w) * clamp(frac, 0, 1)), 2 * S, argb(H.acc, 0xff))
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 24)
}

pass_dump :: proc(a: ^App) -> string {
	p := P(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "pass %v %s%s · %d entries · %s%s", p.view, p.state, p.locked ? " locked" : "", len(p.entries), p.view == .Entry ? p.ent : fmt.tprintf("“%s”", pass_q(p)), len(p.input) > 0 ? fmt.tprintf(" · field %s", panel_masked(&p.pn)) : "")
	rows := pass_rows(a)
	acts := pass_acts(rows[:])
	ci := pass_cur(a, rows[:], acts[:])
	for r, i in rows {
		if r.head { fmt.sbprintfln(&sb, "  [%s] %s", r.label, r.count); continue }
		on := ci >= 0 && acts[ci] == i
		fmt.sbprintfln(&sb, "%s %s%s%s%s", on ? "*" : " ", r.hit != "" ? fmt.tprintf("%s[%s]%s", r.hit_pre, r.hit, r.hit_post) : r.label, r.sub != "" ? fmt.tprintf(" / %s", r.sub) : "", r.meta != "" ? fmt.tprintf(" · %s", r.meta) : "", r.key != "" ? fmt.tprintf(" (%s)", r.key) : "")
	}
	if p.copied != "" do fmt.sbprintfln(&sb, "copied %s", p.copied)
	panel_dump_toast(&p.pn, &sb)
	return strings.to_string(sb)
}
