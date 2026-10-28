package k4

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// --messenger: Facebook Messenger (k4-messenger, over a Matrix bridge on this machine), the Kestrel
// design's KMessenger board, 900×600: the chats on the left (a find field, unread first, then the
// newest; 8, then "Show N older chats"), the open one on the right (its head, runs of messages: a
// name over each in a group, yours on the right in the accent, a line per day; photos and videos
// as pictures) and a line to write under it. With --popup (the bar's module) 420×560, one pane at
// a time: the list, ↵ the chat, Esc back.
// Typing finds a chat (by name or by anyone in it), ↑↓ pick, ↵ opens it (and reads it) and moves
// to the line to write: typing writes, ↵ sends, Esc goes back to the list. PgUp older messages
// (the wheel scrolls them), ^I lists a group's members, ^O opens the newest photo or video (a
// click opens the one clicked), ^R marks it read, ^N starts a chat: type a name, ↵ searches
// Messenger, ↑↓ pick, ↵ opens it (the bridge adds only recent chats on its own; older ones come
// back this way). A dashed note says when encrypted chats still wait for their first message.
// Before it works, a card fills the window (the KMessengerStates board): Not set up (↵ runs
// k4-messengerd setup, its 5 steps as they come; Esc lets it run on; a failed step: ↵ again, l its
// log), Starting (set up, the keyring not open yet after a reboot: ↵ asks to unlock it), Not
// running (↵ starts it again, l the services' log), Log in (paste a messenger.com "Copy as cURL"
// with ^V: it is checked for the session cookies, Tab shows it, ↵ hands it to the bridge, o opens
// messenger.com). Logged out again and Not answering are banners over the chats (read-only, and
// ^R retry).
// The data comes from k4-messenger (panel lines R and L, panel.odin), again every 2 s while open:
//   S <state setup|starting|down|login|relogin|error|ok> <unread> <account> <note>
//   E <n>                       encrypted chats that wait for a message
//   C <room> <name> <unread> <unix time> <sender of the last, in groups> <last line> <group 1|0> <mine 1|0>
//     <titled 1|0> <members>    titled: a name of its own; members: the others, | between
//   O <room>                    the open one; then its messages, oldest first:
//   M <id> <unix time> <sender> <mine 1|0> <text|image|video|audio|file|emote> <text> [preview]
//                               preview: a picture file (a photo's thumbnail, a video's frame), once
//                               made; until then the text ([photo], [video]) shows
// The runner's verbs: open ROOM, close, more, send ROOM ($K4_INPUT), read ROOM, media ID, search QUERY
// (k4:person ID NAME lines), start ID NAME (k4:open ROOM), setup (its steps in $XDG_RUNTIME_DIR/k4-messenger-setup.log),
// login ($K4_INPUT: the cookies), unlock, retry, web, log, journal.

MSG_W, MSG_H :: 900, 600
MSG_PW, MSG_PH :: 420, 560
MSG_LIST_W :: 330
MSG_TOP :: 8 // the chats listed before "Show N older chats"

// Setup's five steps (k4-messengerd setup prints "Step N/5 · …" as each starts), as the card names them.
MSG_STEPS :: [5][2]string{{"Download the Matrix server and the bridge", "about 150 MB"}, {"Start the local server (127.0.0.1 only)", ""}, {"Create your account on it", ""}, {"Connect the Messenger bridge", ""}, {"Start k4's Messenger service", ""}}

Msg_Room :: struct { id, name, who, last: string, unread: int, ts: i64, group, mine, titled: bool, members: []string }
Msg_Line :: struct { id, sender, kind, text, media: string, ts: i64, mine: bool }

// A row of the list: the heading, a chat (r: its index in rooms), or the older chats' fold.
Msg_Row :: struct { kind: enum { Head, Chat, More }, r: int }

Messenger :: struct {
	using pn: Panel,
	state, account, note: string,
	unread, waiting: int,
	rooms: [dynamic]Msg_Room,
	open: string,
	msgs: [dynamic]Msg_Line,
	cur: int,             // the picked row, among the ones that can be picked
	find: [dynamic]u8,    // the find field (the list)
	writing: bool,        // the keys go to the line to write (else to the find field)
	older: bool,          // the older chats are unfolded
	chat: bool,           // the popup: the chat shows (else the list)
	members: bool,        // ^I: the open group's members under its name
	scroll: int,          // lines up from the newest
	steps: [dynamic]string, // setup's lines as they come
	setting_up: bool,     // setup runs (ours, or one still going from before)
	watching: bool,       // (one from before: its log is followed, it is not our job)
	relog: bool,          // logged out: the login card over the chats (↵ on the banner)
	// ^N: a new chat: the name typed, the people found for it, the picked one
	newchat: bool,
	who: [dynamic]u8,
	searched: string, // the name the list is for ("" none yet)
	people: [dynamic][2]string, // id, name
	pcur: int,
}

messenger_setup :: proc(a: ^App, data: string) {
	m := new(Messenger)
	m.mode = {draw = msg_draw, key = msg_key, click = msg_click, scroll = msg_scroll, loaded = msg_loaded, ran = msg_ran, tick = msg_tick, dump = msg_dump}
	panel_init(a, &m.pn, "messenger", data)
	m.refresh_ms = 2000
	a.width, a.height = m.popup ? MSG_PW : MSG_W, m.popup ? MSG_PH : MSG_H
	if m.open != "" { // opened at a chat (a card, the launcher): its line to write
		for r, i in msg_selectable(m) do if r.kind == .Chat && m.rooms[r.r].id == m.open do m.cur = i
		m.chat, m.writing = true, true
	}
	if os.get_env("K4_MESSENGER_NEW", context.temp_allocator) != "" do m.newchat = true // (k4-messenger window --new: the Apps section's New chat)
}

@(private = "file")
M :: proc(a: ^App) -> ^Messenger { return (^Messenger)(a.pn) }

@(private = "file")
msg_now :: proc() -> i64 {
	if v, ok := strconv.parse_i64(os.get_env("K4_MESSENGER_NOW", context.temp_allocator)); ok do return v
	return time.to_unix_seconds(time.now())
}

@(private = "file")
msg_free_room :: proc(r: ^Msg_Room) {
	delete(r.id); delete(r.name); delete(r.who); delete(r.last)
	for x in r.members do delete(x)
	delete(r.members)
}

@(private = "file")
msg_free_msgs :: proc(m: ^Messenger) {
	for &l in m.msgs { delete(l.id); delete(l.sender); delete(l.kind); delete(l.text); delete(l.media) }
	clear(&m.msgs)
}

@(private = "file")
msg_loaded :: proc(a: ^App, data: string) {
	m := M(a)
	for &r in m.rooms do msg_free_room(&r)
	clear(&m.rooms)
	msg_free_msgs(m)
	m.waiting = 0
	open := ""
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			delete(m.state); delete(m.account); delete(m.note)
			m.state, m.account, m.note = strings.clone(fget(f, 1)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4))
			m.unread, _ = strconv.parse_int(fget(f, 2))
		case "E": m.waiting, _ = strconv.parse_int(fget(f, 1))
		case "C":
			r := Msg_Room{id = strings.clone(fget(f, 1)), name = strings.clone(fget(f, 2)), who = strings.clone(fget(f, 5)), last = strings.clone(fget(f, 6)), group = fget(f, 7) == "1", mine = fget(f, 8) == "1", titled = fget(f, 9) == "1"}
			r.unread, _ = strconv.parse_int(fget(f, 3))
			r.ts, _ = strconv.parse_i64(fget(f, 4))
			if ms := fget(f, 10); ms != "" {
				parts := strings.split(ms, "|", context.temp_allocator)
				r.members = make([]string, len(parts))
				for p, i in parts do r.members[i] = strings.clone(p)
			}
			append(&m.rooms, r)
		case "O": open = fget(f, 1)
		case "M":
			l := Msg_Line{id = strings.clone(fget(f, 1)), sender = strings.clone(fget(f, 3)), mine = fget(f, 4) == "1", kind = strings.clone(fget(f, 5)), text = strings.clone(fget(f, 6)), media = strings.clone(fget(f, 7))}
			l.ts, _ = strconv.parse_i64(fget(f, 2))
			append(&m.msgs, l)
		}
	}
	if open != m.open { delete(m.open); m.open = strings.clone(open) }
	if m.state != "relogin" do m.relog = false
	if m.state != "setup" && m.state != "down" { m.setting_up, m.watching = false, false }
	else if !m.setting_up do msg_setup_resume(m)
	m.cur = clamp(m.cur, 0, max(len(msg_selectable(m)) - 1, 0))
}

// ---------- the list ----------

@(private = "file")
msg_lower :: proc(s: string) -> string { return strings.to_lower(s, context.temp_allocator) }

// The chat matches the find field: its name, or anyone in it.
@(private = "file")
msg_match :: proc(r: Msg_Room, q: string) -> bool {
	if q == "" || strings.contains(msg_lower(r.name), q) do return true
	for x in r.members do if strings.contains(msg_lower(x), q) do return true
	return false
}

// The name shown: an unnamed group's, with the member found first ("Anna Berg, Maja Holm +2").
@(private = "file")
msg_label :: proc(r: Msg_Room, q: string) -> string {
	if r.titled || !r.group || q == "" do return r.name
	hit := -1
	for x, i in r.members do if strings.contains(msg_lower(x), q) { hit = i; break }
	if hit < 0 do return r.name
	order := make([dynamic]string, 0, len(r.members), context.temp_allocator)
	append(&order, r.members[hit])
	for x, i in r.members do if i != hit do append(&order, x)
	return msg_short(order[:])
}

@(private = "file")
msg_short :: proc(names: []string) -> string {
	if len(names) <= 3 do return strings.join(names, ", ", context.temp_allocator)
	return fmt.tprintf("%s +%d", strings.join(names[:3], ", ", context.temp_allocator), len(names) - 3)
}

// The list's rows: the heading, the first 8 chats, the fold for the older ones (and, unfolded,
// them); while finding, only the chats found.
@(private = "file")
msg_rows :: proc(m: ^Messenger) -> []Msg_Row {
	q := msg_lower(strings.trim_space(string(m.find[:])))
	out := make([dynamic]Msg_Row, 0, len(m.rooms) + 2, context.temp_allocator)
	if q != "" {
		for r, i in m.rooms do if msg_match(r, q) do append(&out, Msg_Row{.Chat, i})
		return out[:]
	}
	if len(m.rooms) > 0 do append(&out, Msg_Row{.Head, 0})
	for i in 0 ..< min(len(m.rooms), MSG_TOP) do append(&out, Msg_Row{.Chat, i})
	if len(m.rooms) > MSG_TOP {
		append(&out, Msg_Row{.More, 0})
		if m.older do for i in MSG_TOP ..< len(m.rooms) do append(&out, Msg_Row{.Chat, i})
	}
	return out[:]
}

@(private = "file")
msg_selectable :: proc(m: ^Messenger) -> []Msg_Row {
	out := make([dynamic]Msg_Row, 0, len(m.rooms) + 1, context.temp_allocator)
	for r in msg_rows(m) do if r.kind != .Head do append(&out, r)
	return out[:]
}

@(private = "file")
msg_open_room :: proc(m: ^Messenger) -> (Msg_Room, bool) {
	for r in m.rooms do if r.id == m.open do return r, true
	return {}, false
}

// The picked row: a chat opens (the daemon shows and reads it, the loader brings its messages) and
// the keys go to its line; the fold folds or unfolds.
@(private = "file")
msg_activate :: proc(a: ^App) {
	m := M(a)
	rows := msg_selectable(m)
	if m.cur >= len(rows) do return
	row := rows[m.cur]
	if row.kind == .More { m.older = !m.older; return }
	if m.state == "relogin" { panel_say(&m.pn, "Read-only until you log in again", a.theme.yellow); return }
	r := m.rooms[row.r]
	m.writing, m.scroll = true, 0
	if m.popup do m.chat = true
	if r.id == m.open do return
	delete(m.open); m.open = strings.clone(r.id)
	m.members = false
	msg_free_msgs(m) // the old one's messages go at once; the new ones come with the next load
	panel_run(a, "open", r.id)
}

// The photo or video in that message opens in its app (the daemon fetches the file once).
@(private = "file")
msg_open_media :: proc(a: ^App, i: int) {
	m := M(a)
	if i >= 0 && i < len(m.msgs) && (m.msgs[i].kind == "image" || m.msgs[i].kind == "video") do panel_run(a, "media", m.msgs[i].id)
}

// The newest message with a photo or video (-1: none).
@(private = "file")
msg_last_media :: proc(m: ^Messenger) -> int {
	#reverse for l, i in m.msgs do if l.kind == "image" || l.kind == "video" do return i
	return -1
}

@(private = "file")
msg_ready :: proc(m: ^Messenger) -> bool { return m.state == "ok" || m.state == "error" || m.state == "relogin" }

@(private = "file")
msg_send :: proc(a: ^App) {
	m := M(a)
	t := strings.trim_space(panel_text(&m.pn))
	if t == "" || m.open == "" do return
	if m.state == "relogin" { panel_say(&m.pn, "Log in again to send", a.theme.yellow); return }
	text := strings.clone(panel_text(&m.pn), context.temp_allocator)
	// shown at once as sent; the next load has it for real
	append(&m.msgs, Msg_Line{id = strings.clone("…"), sender = strings.clone("you"), kind = strings.clone("text"), text = strings.clone(text), ts = msg_now(), mine = true})
	panel_clear(&m.pn)
	m.scroll = 0
	panel_run(a, "send", m.open, secret = text)
}

// ---------- the cards (a state that fills the window) ----------

Msg_View :: enum { Chats, Not_Set_Up, Setup, Starting, Not_Running, Login }

@(private = "file")
msg_view :: proc(m: ^Messenger) -> Msg_View {
	if m.setting_up do return .Setup
	switch m.state {
	case "setup": return msg_setup_failed(m) ? .Setup : .Not_Set_Up
	case "starting": return .Starting
	case "down": return msg_setup_failed(m) ? .Setup : .Not_Running
	case "login": return .Login
	case "relogin": return m.relog ? .Login : .Chats
	}
	return .Chats
}

// The card's first button (↵) and its second (its own key).
@(private = "file")
msg_primary :: proc(a: ^App) {
	m := M(a)
	switch msg_view(m) {
	case .Not_Set_Up, .Not_Running: msg_setup(a)
	case .Setup: if !m.setting_up do msg_setup(a)
	case .Starting: panel_run(a, "unlock")
	case .Login:
		t := panel_text(&m.pn)
		switch {
		case panel_busy(&m.pn):
		case strings.trim_space(t) == "": panel_say(&m.pn, "Paste the cURL first (^V)", a.theme.yellow)
		case msg_cookie_missing(t) != "": panel_say(&m.pn, "Paste a Messenger cURL first", a.theme.yellow)
		case: panel_run(a, "login", secret = t)
		}
	case .Chats:
	}
}

@(private = "file")
msg_secondary :: proc(a: ^App) {
	m := M(a)
	#partial switch msg_view(m) {
	case .Setup: if !m.setting_up do panel_run(a, "log")
	case .Not_Running: panel_run(a, "journal")
	case .Login: panel_run(a, "web")
	}
}

// What a pasted session lacks ("" nothing): the bridge needs c_user and xs.
@(private = "file")
msg_cookie_missing :: proc(t: string) -> string {
	if !strings.contains(t, "c_user") do return "c_user"
	if !strings.contains(t, "xs=") && !strings.contains(t, "\"xs\"") do return "xs"
	return ""
}

// Setup's progress from its lines: the step it is at (0–4), done, or the step it stopped at
// and why.
@(private = "file")
msg_setup_at :: proc(m: ^Messenger) -> (cur: int, done: bool, fail: string) {
	for s in m.steps {
		if strings.has_prefix(s, "Step ") && len(s) > 6 do cur = clamp(int(s[5] - '1'), 0, 4)
		if strings.has_prefix(s, "Ready") do done = true
		if strings.has_prefix(s, "k4-messengerd: ") do fail = s[15:]
	}
	return
}

@(private = "file")
msg_setup_failed :: proc(m: ^Messenger) -> bool {
	_, _, fail := msg_setup_at(m)
	return fail != ""
}

// Setup runs in the background (a minute or two: downloads, the services' first start); its
// steps come from its log, read while it runs.
@(private = "file")
msg_setup_log :: proc() -> string {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	return fmt.tprintf("%s/k4-messenger-setup.log", run != "" ? run : "/tmp")
}

@(private = "file")
msg_read_log :: proc(m: ^Messenger) -> (fresh: bool) {
	for s in m.steps do delete(s)
	clear(&m.steps)
	data, err := os.read_entire_file(msg_setup_log(), context.temp_allocator)
	if err != nil do return false
	text := string(data)
	for l in strings.split_lines_iterator(&text) do if l != "" do append(&m.steps, strings.clone(l))
	if fi, e := os.stat(msg_setup_log(), context.temp_allocator); e == nil do fresh = time.since(fi.modification_time) < 10 * time.Minute
	return
}

@(private = "file")
msg_setup :: proc(a: ^App) {
	m := M(a)
	m.setting_up, m.watching = true, false
	for s in m.steps do delete(s)
	clear(&m.steps)
	panel_run(a, "setup")
}

// The window opened while not set up: a setup still going (its window closed, "Run in
// background") is followed; one that stopped shows where.
@(private = "file")
msg_setup_resume :: proc(m: ^Messenger) {
	if os.get_env("K4_DRY_NOWAIT", context.temp_allocator) != "" && m.runner == "" do return // (tests: no log)
	fresh := msg_read_log(m)
	_, done, fail := msg_setup_at(m)
	if fresh && !done && fail == "" && len(m.steps) > 0 do m.setting_up, m.watching = true, true
	if done || !fresh { for s in m.steps do delete(s); clear(&m.steps) } // (an old log says nothing now)
}

@(private = "file")
msg_tick :: proc(a: ^App) -> int {
	m := M(a)
	if !m.setting_up do return -1
	fresh := msg_read_log(m)
	_, done, fail := msg_setup_at(m)
	over := m.watching ? (done || fail != "" || !fresh) : !panel_busy(&m.pn)
	if over {
		m.setting_up, m.watching = false, false
		if done { for s in m.steps do delete(s); clear(&m.steps); panel_say(&m.pn, "Set up · now log in to Messenger") }
		panel_reload(a)
		return -1
	}
	return 300
}

// ---------- keys ----------

@(private = "file")
msg_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := M(a)
	if ctrl && (ch == 'c' || ch == 'g') { panel_close(a); return true }
	view := msg_view(m)
	switch view {
	case .Login: // the session is pasted, not typed
		switch {
		case ctrl && ch == 'v': panel_clear(&m.pn); panel_type(&m.pn, msg_clipboard())
		case k == .Enter: msg_primary(a)
		case k == .Tab: m.reveal = !m.reveal
		case k == .Backspace || k == .Delete: panel_clear(&m.pn)
		case text == "o" && !ctrl && !alt: msg_secondary(a)
		case k == .Escape:
			switch {
			case len(m.input) > 0: panel_clear(&m.pn)
			case m.relog: m.relog = false
			case: panel_close(a)
			}
		case: return false
		}
		return true
	case .Not_Set_Up, .Setup, .Starting, .Not_Running:
		switch {
		case k == .Enter: msg_primary(a)
		case text == "l" && !ctrl && !alt: msg_secondary(a)
		case k == .Escape: panel_close(a) // (a setup going on keeps going)
		case: return false
		}
		return true
	case .Chats:
	}
	if m.newchat {
		switch {
		case k == .Escape: msg_newchat_end(m)
		case k == .Down: m.pcur = min(m.pcur + 1, max(len(m.people) - 1, 0))
		case k == .Up: m.pcur = max(m.pcur - 1, 0)
		case k == .Enter:
			q := strings.trim_space(string(m.who[:]))
			if q == "" || panel_busy(&m.pn) do return true
			if q == m.searched && m.pcur < len(m.people) { // the list is for this name: open the picked one
				p := m.people[m.pcur]
				panel_run(a, "start", p[0], p[1])
			} else {
				for &x in m.people { delete(x[0]); delete(x[1]) }
				clear(&m.people)
				m.pcur = 0
				delete(m.searched); m.searched = strings.clone(q)
				panel_run(a, "search", q)
			}
		case k == .Backspace: if len(m.who) > 0 do pop(&m.who)
		case ctrl && ch == 'v': append(&m.who, ..transmute([]u8)msg_clipboard())
		case text != "" && k == .None && !ctrl && !alt: append(&m.who, ..transmute([]u8)text)
		case: return false
		}
		return true
	}
	// both fields
	switch {
	case ctrl && ch == 'n' && msg_ready(m): m.newchat = true; m.writing = false; if m.popup do m.chat = false; return true
	case ctrl && ch == 'i' || k == .Tab && ctrl: m.members = !m.members; return true
	case ctrl && ch == 'o': msg_open_media(a, msg_last_media(m)); return true
	case ctrl && ch == 'r':
		if m.state == "error" do panel_run(a, "retry")
		else if m.open != "" do panel_run(a, "read", m.open)
		return true
	case k == .Page_Up: if m.open != "" { m.scroll += 10; panel_run(a, "more") }; return true
	case k == .Page_Down: m.scroll = max(m.scroll - 10, 0); return true
	}
	if m.writing {
		switch {
		case k == .Enter: msg_send(a)
		case k == .Backspace: panel_bs(&m.pn)
		case k == .Escape || k == .Tab:
			if k == .Escape && len(m.input) > 0 do panel_clear(&m.pn)
			else { m.writing = false; if m.popup do m.chat = false }
		case k == .Up || k == .Down: m.writing = false; if m.popup do m.chat = false
		case ctrl && ch == 'v': panel_type(&m.pn, msg_clipboard())
		case text != "" && k == .None && !ctrl && !alt: panel_type(&m.pn, text)
		case: return false
		}
		return true
	}
	n := len(msg_selectable(m))
	switch {
	case k == .Down: m.cur = min(m.cur + 1, max(n - 1, 0))
	case k == .Up: m.cur = max(m.cur - 1, 0)
	case k == .Enter:
		if m.state == "relogin" && len(m.find) == 0 && (n == 0 || msg_selectable(m)[m.cur].kind != .More) { m.relog = true; return true }
		msg_activate(a)
	case k == .Tab: if m.open != "" { m.writing = true; if m.popup do m.chat = true }
	case k == .Backspace: if len(m.find) > 0 { pop(&m.find); m.cur = 0 }
	case k == .Escape:
		if len(m.find) > 0 { clear(&m.find); m.cur = 0 } else do panel_close(a)
	case ctrl && ch == 'v': append(&m.find, ..transmute([]u8)msg_clipboard()); m.cur = 0
	case text != "" && k == .None && !ctrl && !alt: append(&m.find, ..transmute([]u8)text); m.cur = 0
	case: return false
	}
	return true
}

// What the clipboard holds, as text on one line (a pasted "Copy as cURL" spans several; the field
// is one line). K4_MESSENGER_CLIPBOARD stands in for it in tests.
@(private = "file")
msg_clipboard :: proc() -> string {
	text := os.get_env("K4_MESSENGER_CLIPBOARD", context.temp_allocator)
	if text == "" {
		_, out, _, err := os.process_exec({command = {"wl-paste", "--no-newline", "--type", "text/plain"}}, context.temp_allocator)
		if err != nil do return ""
		text = string(out)
	}
	t, _ := strings.replace_all(text, "\\\n", " ", context.temp_allocator) // a shell line continuation
	t, _ = strings.replace_all(t, "\r", "", context.temp_allocator)
	t, _ = strings.replace_all(t, "\n", " ", context.temp_allocator)
	return t
}

@(private = "file")
msg_scroll :: proc(a: ^App, n: int) -> bool {
	m := M(a)
	m.scroll = max(m.scroll - n * 3, 0)
	return true
}

// Hits: .Row a chat or the fold (a: its index among the ones that can be picked), .Item a
// picture (b 1) or a person found for a new chat, .Chip a button (0 the card's first, 1 its
// second, 2 the banner's).
@(private = "file")
msg_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := M(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: m.cur = h.a; msg_activate(a)
	case .Item:
		if h.b == 1 { msg_open_media(a, h.a); return true }
		if m.newchat && h.a < len(m.people) {
			if h.a == m.pcur do panel_run(a, "start", m.people[h.a][0], m.people[h.a][1])
			else do m.pcur = h.a
		}
	case .Chip:
		switch h.a {
		case 0: msg_primary(a)
		case 1: msg_secondary(a)
		case 2: if m.state == "relogin" do m.relog = true; else do panel_run(a, "retry")
		}
	case: return false
	}
	return true
}

@(private = "file")
msg_newchat_end :: proc(m: ^Messenger) {
	m.newchat = false
	clear(&m.who)
	for &x in m.people { delete(x[0]); delete(x[1]) }
	clear(&m.people)
	delete(m.searched); m.searched = ""
	m.pcur = 0
}

// The search's people (k4:person ID NAME), and the chat to open (k4:open ROOM).
@(private = "file")
msg_ran :: proc(a: ^App, verb, line: string) -> bool {
	m := M(a)
	switch {
	case strings.has_prefix(line, "k4:person\t"):
		f := fields(line[10:])
		append(&m.people, [2]string{strings.clone(fget(f, 0)), strings.clone(fget(f, 1))})
		return true
	case strings.has_prefix(line, "k4:open\t"):
		delete(m.open); m.open = strings.clone(line[8:])
		msg_newchat_end(m)
		clear(&m.find)
		m.cur, m.scroll, m.writing = 0, 0, true
		if m.popup do m.chat = true
		return true
	}
	if verb == "login" do panel_clear(&m.pn)
	return false
}

// ---------- drawing ----------

// The design's colours beyond the HUD: soft text, and the theme's yellow, green and red.
@(private = "file")
Msg_Tones :: struct { soft, yellow, green, red: u32 }

@(private = "file")
msg_tones :: proc(a: ^App, H: HUD) -> Msg_Tones {
	return {soft = mix(H.fg, H.bg, 0.2), yellow = a.theme.yellow, green = a.theme.green, red = a.theme.red}
}

// A day's line: TODAY, YESTERDAY, MON 12 OCT.
@(private = "file")
msg_day :: proc(ts, now: i64) -> string {
	switch now / 86400 - ts / 86400 {
	case 0: return "TODAY"
	case 1: return "YESTERDAY"
	}
	return strings.to_upper(msg_date(ts, true), context.temp_allocator)
}

@(private = "file")
msg_clock :: proc(ts: i64) -> string {
	h, mi, _ := time.clock(time.unix(ts, 0))
	return fmt.tprintf("%02d:%02d", h, mi)
}

// "Mon 12 Oct" (with_day) or "12 Oct".
@(private = "file")
msg_date :: proc(ts: i64, with_day: bool) -> string {
	t := time.unix(ts, 0)
	_, mo, dd := time.date(t)
	days := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	if with_day do return fmt.tprintf("%s %d %s", days[int(time.weekday(t))], dd, months[int(mo) - 1])
	return fmt.tprintf("%d %s", dd, months[int(mo) - 1])
}

// When the last message came: 2 min, 3 h, yesterday, Mon, 12 Oct.
@(private = "file")
msg_ago :: proc(ts, now: i64) -> string {
	d := now - ts
	days := now / 86400 - ts / 86400
	switch {
	case d < 60: return "now"
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case days == 0: return fmt.tprintf("%d h", d / 3600)
	case days == 1: return "yesterday"
	case days < 7: return msg_date(ts, true)[:3]
	}
	return msg_date(ts, false)
}

// Initials: the first letters of the first two words.
@(private = "file")
msg_initials :: proc(name: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	n := 0
	for w in strings.fields(name, context.temp_allocator) {
		for r in w { strings.write_rune(&sb, r); break }
		n += 1
		if n == 2 do break
	}
	return strings.to_upper(strings.to_string(sb), context.temp_allocator)
}

@(private = "file")
msg_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := M(a)
	H := panel_ground(a, cv)
	tn := msg_tones(a, H)
	w, h := cv.w, cv.h
	now := msg_now()
	view := msg_view(m)
	room, has_room := msg_open_room(m)
	popchat := m.popup && m.chat && !m.newchat && view == .Chats

	// the head: the crumb, a title, the state at the right
	hh := (m.popup ? 40 : 48) * S
	px := (m.popup ? 12 : 16) * S
	crumb := popchat ? "MESSENGER ›" : "MESSENGER"
	cf := m.popup ? m.f11b : m.f12b
	cw, ch := tw(cf, crumb) + (m.popup ? 12 : 16) * S, (m.popup ? 20 : 24) * S
	fill_rect(cv, px, (hh - ch) / 2, cw, ch, argb(H.acc, 0xff))
	text_in(cv, cf, crumb, px + (cw - tw(cf, crumb)) / 2, (hh - ch) / 2, ch, argb(H.bg, 0xff))
	st, stc := "connected", tn.green
	switch {
	case m.setting_up: st, stc = "setting up", H.acc
	case m.state == "setup": st, stc = "not set up", H.dim
	case m.state == "starting": st, stc = "starting…", tn.soft
	case m.state == "down": st, stc = "stopped", tn.yellow
	case m.state == "login": st, stc = "not logged in", tn.yellow
	case m.state == "relogin": st, stc = "logged out", tn.yellow
	case m.state == "error": st, stc = "not answering", tn.yellow
	}
	sw := tw(m.f10, st)
	text_in(cv, m.f10, st, w - px - sw, 0, hh, argb(stc, 0xff))
	fill_rect(cv, w - px - sw - 12 * S, (hh - 6 * S) / 2, 6 * S, 6 * S, argb(stc, 0xff))
	title := ""
	switch view {
	case .Login: title = "Log in"
	case .Setup: title = "Setup"
	case .Chats:
		unread := 0
		for r in m.rooms do if r.unread > 0 do unread += 1
		chats := fmt.tprintf("%d chat%s", len(m.rooms), len(m.rooms) == 1 ? "" : "s")
		title = popchat && has_room ? room.name : (unread > 0 ? fmt.tprintf("%d unread · %s", unread, chats) : chats)
	case .Not_Set_Up, .Starting, .Not_Running:
	}
	tx := px + cw + 10 * S
	text_in(cv, m.f13b, ellipsize(m.f13b, title, w - px - sw - 30 * S - tx), tx, 0, hh, argb(H.fg, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))

	// the foot: the keys at the left, the last message at the right
	fh := 30 * S
	fy := h - fh
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	hints := msg_hints(m, view)
	toast_w := m.toast != "" ? min(tw(m.f10, m.toast), w / 2) : 0
	kx := px
	for k in hints {
		kw := tw(m.f10, k[0]) + 8 * S
		if kx + kw + 5 * S + tw(m.f10, k[1]) > w - px - toast_w - 12 * S do break
		fill_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, argb(H.panel, 0xff))
		rounded_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, m.f10, k[0], kx + 4 * S, fy, fh, argb(tn.soft, 0xff))
		kx += kw + 5 * S
		text_in(cv, m.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(m.f10, k[1]) + 12 * S
	}
	if m.toast != "" {
		t := ellipsize(m.f10, m.toast, toast_w)
		text_in(cv, m.f10, t, w - px - tw(m.f10, t), fy, fh, argb(m.tone != 0 ? m.tone : H.acc, 0xff))
	}

	body_y := hh + S
	if view != .Chats { msg_draw_card(a, cv, S, H, view, px, body_y, w - 2 * px, fy - body_y); return }
	// the banners: logged out (read-only), not answering
	if m.state == "relogin" || m.state == "error" {
		relogin := m.state == "relogin"
		bt := relogin ? "Messenger logged you out" : "Messenger is not answering"
		sub := relogin ? "the chats below are read-only until you log in again" : "you can read; it retries every minute"
		if m.note != "" && m.note != bt do sub = relogin ? fmt.tprintf("Meta: “%s” · %s", m.note, sub) : fmt.tprintf("%s · %s", m.note, sub)
		bl, bk := relogin ? "Log in again" : "Retry now", relogin ? "↵" : "^R"
		bh := 38 * S
		fill_rect(cv, 0, body_y, w, bh, argb(tn.yellow, 0x12))
		fill_rect(cv, 0, body_y, 3 * S, bh, argb(tn.yellow, 0xff))
		fill_rect(cv, 0, body_y + bh - S, w, S, argb(tn.yellow, 0xff))
		text_in(cv, m.f11b, bt, px, body_y, bh, argb(tn.yellow, 0xff))
		bw := tw(m.f10b, bl) + 6 * S + tw(m.f10, bk) + 16 * S
		bx := w - px - bw
		fill_rect(cv, bx, body_y + 8 * S, bw, 22 * S, argb(H.acc, 0xff))
		text_in(cv, m.f10b, bl, bx + 8 * S, body_y + 8 * S, 22 * S, argb(H.bg, 0xff))
		text_in(cv, m.f10, bk, bx + 8 * S + tw(m.f10b, bl) + 6 * S, body_y + 8 * S, 22 * S, argb(H.bg, 0xff))
		hit_add(a, bx, body_y + 8 * S, bw, 22 * S, .Chip, 2, 0)
		sx := px + tw(m.f11b, bt) + 10 * S
		text_in(cv, m.f10, ellipsize(m.f10, sub, bx - 10 * S - sx), sx, body_y, bh, argb(tn.soft, 0xff))
		body_y += bh
	}
	bh := fy - body_y
	if m.popup {
		switch {
		case m.newchat: msg_draw_newchat(a, cv, S, H, 0, body_y, w, bh)
		case m.chat && has_room: msg_draw_chat(a, cv, S, H, 0, body_y, w, bh, now)
		case: msg_draw_list(a, cv, S, H, 0, body_y, w, bh, now)
		}
		return
	}
	lw := MSG_LIST_W * S
	if m.newchat do msg_draw_newchat(a, cv, S, H, 0, body_y, lw, bh)
	else do msg_draw_list(a, cv, S, H, 0, body_y, lw, bh, now)
	fill_rect(cv, lw, body_y, S, bh, argb(H.line, 0xff))
	msg_draw_chat(a, cv, S, H, lw + S, body_y, w - lw - S, bh, now)
}

// The keys as a list the caller keeps (a literal would live in this frame).
@(private = "file")
msg_keys :: proc(k: ..[2]string) -> [][2]string { return slice.clone(k, context.temp_allocator) }

@(private = "file")
msg_hints :: proc(m: ^Messenger, view: Msg_View) -> [][2]string {
	_, _, fail := msg_setup_at(m)
	switch view {
	case .Login: return m.relog ? msg_keys({"^V", "Paste"}, {"↵", "Log in"}, {"o", "messenger.com"}, {"Esc", "Back"}) : msg_keys({"^V", "Paste"}, {"↵", "Log in"}, {"o", "messenger.com"}, {"Tab", m.reveal ? "Hide" : "Show"})
	case .Setup: return m.setting_up ? msg_keys({"Esc", "Run in background"}) : (fail != "" ? msg_keys({"↵", "Retry"}, {"l", "Log"}, {"Esc", "Close"}) : msg_keys({"↵", "Set up"}, {"Esc", "Close"}))
	case .Not_Set_Up: return msg_keys({"↵", "Set up"}, {"Esc", "Not now"})
	case .Starting: return msg_keys({"↵", "Unlock keyring"}, {"Esc", "Close"})
	case .Not_Running: return msg_keys({"↵", "Start again"}, {"l", "Log"}, {"Esc", "Close"})
	case .Chats:
	}
	if m.newchat do return msg_keys({"↵", len(m.people) > 0 && strings.trim_space(string(m.who[:])) == m.searched ? "Open chat" : "Search"}, {"↑↓", "Pick"}, {"Esc", "Back"})
	if m.writing {
		if msg_last_media(m) >= 0 do return msg_keys({"↵", "Send"}, {"Esc", "Chats"}, {"^O", "Photo"}, {"PgUp", "Older"})
		return msg_keys({"↵", "Send"}, {"Esc", "Chats"}, {"PgUp", "Older"}, {"^I", "Members"})
	}
	if m.popup do return msg_keys({"type", "Find"}, {"↑↓", "Chat"}, {"↵", "Open"}, {"^N", "New"}, {"Esc", "Close"})
	return msg_keys({"type", "Find"}, {"↑↓", "Chat"}, {"↵", "Open"}, {"^N", "New"}, {"^I", "Members"})
}

// A card that fills the window (the board's not set up, setting up, starting, not running and
// log in), centred: its title, lines, the steps or the numbered list and the field, the buttons.
@(private = "file")
msg_draw_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, view: Msg_View, x, y, w, h: int) {
	m := M(a)
	tn := msg_tones(a, H)
	c, bg := H.acc, argb(H.acc, 0x0d)
	ctitle := ""
	lines: [dynamic][2]string // text, "soft" | "dim"
	lines.allocator = context.temp_allocator
	steps := false
	list: []string
	field := false
	acts: [2][2]string // label, key
	cur, _, fail := msg_setup_at(m)
	switch view {
	case .Not_Set_Up:
		ctitle = "Messenger, on this machine"
		append(&lines, [2]string{"Your Messenger chats in k4, through a small Matrix server and a bridge that run here as user services.", "soft"})
		append(&lines, [2]string{"About 150 MB · 1–2 min · nothing leaves this computer except the bridge talking to Messenger.", "dim"})
		acts = {{"Set up", "↵"}, {"Not now", "Esc"}}
	case .Setup:
		steps = true
		if fail != "" {
			ctitle, c, bg = fmt.tprintf("Setup stopped at step %d", cur + 1), tn.red, argb(tn.red, 0x0d)
			acts = {{fmt.tprintf("Retry from step %d", cur + 1), "↵"}, {"Show log", "l"}}
		} else {
			ctitle = fmt.tprintf("Setting up · step %d of 5", cur + 1)
			acts = {{"Run in background", "Esc"}, {}}
		}
	case .Starting:
		ctitle, c, bg = "Starting Messenger…", tn.soft, argb(H.panel, 0xff)
		append(&lines, [2]string{"Your setup is fine. The local server waits for the keyring after a reboot, because that’s where its password lives.", "soft"})
		append(&lines, [2]string{"Unlock the keyring (log in, or the prompt that appears) and this opens on your chats by itself.", "dim"})
		acts = {{"Unlock keyring", "↵"}, {}}
	case .Not_Running:
		ctitle, c, bg = "Messenger isn’t running", tn.yellow, argb(tn.yellow, 0x0d)
		note := m.note != "" ? m.note : "The local server and the bridge are stopped"
		append(&lines, [2]string{fmt.tprintf("%s. Your chats are safe on disk; Start again starts them (and repairs what is missing).", strings.trim_right(note, ".")), "soft"})
		acts = {{"Start again", "↵"}, {"Show log", "l"}}
	case .Login:
		ctitle = m.relog ? "Log in to Messenger again" : "Log in to Messenger"
		if m.relog && m.note != "" do append(&lines, [2]string{fmt.tprintf("Meta: “%s”", m.note), "dim"})
		append(&lines, [2]string{"The bridge logs in with your browser’s Messenger session. Copy it once:", "soft"})
		list = {"Open messenger.com in your browser and log in.", "Press F12, open Network, then reload the page.", "Right-click the first request › Copy › Copy as cURL.", "Paste it below with ^V and press ↵."}
		field = true
		acts = {{"Log in", "↵"}, {"Open messenger.com", "o"}}
	case .Chats:
	}
	cw := m.popup ? w : min(520 * S, w)
	ix, iw := 20 * S, cw - 40 * S
	// the height first, then centred
	wrapped := make([dynamic][]string, 0, len(lines), context.temp_allocator)
	ch := 18 * S + int(m.f13b.line_h)
	for l in lines { ws := wrap_text(m.f11, l[0], iw); append(&wrapped, ws); ch += 12 * S + len(ws) * 17 * S }
	if steps do ch += 12 * S + 4 * S + 10 * S + 5 * 21 * S - 5 * S
	list_w := make([dynamic][]string, 0, len(list), context.temp_allocator)
	for l in list { ws := wrap_text(m.f11, l, iw - 28 * S); append(&list_w, ws); ch += len(ws) * 17 * S + 6 * S }
	if len(list) > 0 do ch += 12 * S - 6 * S
	pasted := panel_text(&m.pn)
	missing := msg_cookie_missing(pasted)
	note := ""
	if field {
		ch += 12 * S + 34 * S
		if pasted != "" {
			note = missing == "" ? "✓ Messenger session found (c_user, xs). Only the bridge keeps it, on this computer." : fmt.tprintf("That cURL has no Messenger session: no %s cookie. Copy the first request on messenger.com, logged in.", missing)
			ch += 6 * S + len(wrap_text(m.f10, note, iw)) * 15 * S
		}
	}
	ch += 12 * S + 28 * S + 18 * S
	cx := x + (w - cw) / 2
	cy := y + max((h - ch) / 2, 12 * S)
	fill_rect(cv, cx, cy, cw, ch, bg)
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, cx, cy, 3 * S, ch, argb(c, 0xff))
	yy := cy + 18 * S
	text_in(cv, m.f13b, ellipsize(m.f13b, ctitle, iw), cx + ix, yy, int(m.f13b.line_h), argb(c, 0xff))
	yy += int(m.f13b.line_h)
	for ws, i in wrapped {
		yy += 12 * S
		col := lines[i][1] == "soft" ? tn.soft : H.dim
		for l in ws { text_in(cv, m.f11, l, cx + ix, yy, 17 * S, argb(col, 0xff)); yy += 17 * S }
	}
	if steps { // the five segments, then the steps: done, now, failed, to come
		yy += 12 * S
		gap := 4 * S
		segw := (iw - 4 * gap) / 5
		for i in 0 ..< 5 {
			sc := i < cur ? tn.green : (i == cur ? (fail != "" ? tn.red : H.acc) : H.line)
			fill_rect(cv, cx + ix + i * (segw + gap), yy, segw, 4 * S, argb(sc, 0xff))
		}
		yy += 4 * S + 10 * S
		STEPS := MSG_STEPS
		for st, i in STEPS {
			nc, tc, mc := H.faint, H.faint, H.faint
			meta := st[1]
			label := st[0]
			switch {
			case i < cur: nc, tc, mc, meta = tn.green, H.dim, tn.green, "done"
			case i == cur && fail != "": nc, tc, mc, meta = tn.red, tn.red, tn.red, "failed"; label = fmt.tprintf("%s · %s", label, fail)
			case i == cur: nc, tc, mc, meta = H.acc, H.fg, H.acc, "now"
			}
			text_in(cv, m.f11b, fmt.tprintf("%d/5", i + 1), cx + ix, yy, 16 * S, argb(nc, 0xff))
			mw := tw(m.f10, meta)
			text_in(cv, m.f10, meta, cx + ix + iw - mw, yy, 16 * S, argb(mc, 0xff))
			text_in(cv, m.f11, ellipsize(m.f11, label, iw - 40 * S - mw - 10 * S), cx + ix + 40 * S, yy, 16 * S, argb(tc, 0xff))
			yy += 21 * S
		}
		yy -= 5 * S
	}
	if len(list) > 0 { // the numbered list
		yy += 12 * S - 6 * S
		for ws, i in list_w {
			yy += 6 * S
			n := fmt.tprint(i + 1)
			text_in(cv, m.f11b, n, cx + ix + 18 * S - tw(m.f11b, n), yy, 17 * S, argb(H.acc, 0xff))
			for l in ws { text_in(cv, m.f11, l, cx + ix + 28 * S, yy, 17 * S, argb(tn.soft, 0xff)); yy += 17 * S }
		}
	}
	if field { // the pasted session: a short look at it, its size, whether it holds a session
		yy += 12 * S
		fb := pasted == "" ? H.acc : (missing == "" ? H.acc : tn.red)
		fill_rect(cv, cx + ix, yy, iw, 34 * S, argb(H.bg, 0xff))
		rounded_rect(cv, cx + ix, yy, iw, 34 * S, 0, 0, f32(S), argb(fb, 0xff))
		hint := pasted == "" ? "^V · Tab shows" : (len(pasted) >= 1024 ? fmt.tprintf("%.1f KB", f32(len(pasted)) / 1024) : fmt.tprintf("%d B", len(pasted)))
		hw := tw(m.f10, hint)
		text_in(cv, m.f10, hint, cx + ix + iw - 10 * S - hw, yy, 34 * S, argb(H.dim, 0xff))
		shown := pasted == "" ? "paste the copied cURL here" : (m.reveal ? pasted : msg_curl_look(pasted))
		text_in(cv, m.f11, ellipsize(m.f11, shown, iw - 30 * S - hw), cx + ix + 10 * S, yy, 34 * S, argb(pasted == "" ? H.faint : tn.soft, 0xff))
		yy += 34 * S
		if note != "" {
			yy += 6 * S
			for l in wrap_text(m.f10, note, iw) { text_in(cv, m.f10, l, cx + ix, yy, 15 * S, argb(missing == "" ? tn.green : tn.red, 0xff)); yy += 15 * S }
		}
	}
	yy += 12 * S
	if view == .Login && panel_busy(&m.pn) { text_in(cv, m.f11, "Logging in…", cx + ix, yy, 28 * S, argb(H.acc, 0xff)); return }
	bx := cx + ix
	for b, i in acts {
		if b[0] == "" do continue
		prime := i == 0 && !(view == .Setup && m.setting_up)
		bw := tw(m.f11b, b[0]) + 7 * S + tw(m.f11, b[1]) + 24 * S
		if prime do fill_rect(cv, bx, yy, bw, 28 * S, argb(H.acc, 0xff))
		rounded_rect(cv, bx, yy, bw, 28 * S, 0, 0, f32(S), argb(prime ? H.acc : H.line, 0xff))
		text_in(cv, m.f11b, b[0], bx + 12 * S, yy, 28 * S, argb(prime ? H.bg : tn.soft, 0xff))
		text_in(cv, m.f11, b[1], bx + 12 * S + tw(m.f11b, b[0]) + 7 * S, yy, 28 * S, argb(prime ? H.bg : H.dim, 0xff))
		if !(view == .Setup && m.setting_up) do hit_add(a, bx, yy, bw, 28 * S, .Chip, i, 0)
		bx += bw + 6 * S
	}
}

// A pasted "Copy as cURL", its cookies hidden: curl 'https://www.messenger.com/' -H 'cookie: ••••' …
@(private = "file")
msg_curl_look :: proc(t: string) -> string {
	s := strings.trim_space(t)
	if !strings.has_prefix(s, "curl ") do return strings.repeat("•", min(strings.rune_count(s), 24), context.temp_allocator)
	url := strings.fields(s, context.temp_allocator)[1] if len(strings.fields(s, context.temp_allocator)) > 1 else "''"
	return fmt.tprintf("curl %s -H 'cookie: ••••••••••••••••' …", url)
}

@(private = "file")
msg_draw_list :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := M(a)
	tn := msg_tones(a, H)
	// the find field
	fx, fw, fh := x + 10 * S, w - 20 * S, 34 * S
	yy := y + 8 * S
	fill_rect(cv, fx, yy, fw, fh, argb(H.panel, 0xff))
	rounded_rect(cv, fx, yy, fw, fh, 0, 0, f32(S), argb(!m.writing && !m.newchat ? H.acc : H.line, 0xff))
	fill_rect(cv, fx, yy, 3 * S, fh, argb(H.acc, 0xff))
	text_in(cv, m.f13b, "›", fx + 12 * S, yy, fh, argb(H.acc, 0xff))
	q := string(m.find[:])
	qx := fx + 12 * S + tw(m.f13b, "›") + 8 * S
	if q == "" do text_in(cv, m.f12, "Find a chat…   ^N new", qx, yy, fh, argb(H.faint, 0xff))
	shown := q
	for tw(m.f12, shown) > fw - (qx - fx) - 10 * S && len(shown) > 0 do shown = shown[1:]
	text_in(cv, m.f12, shown, qx, yy, fh, argb(H.fg, 0xff))
	if !m.writing do fill_rect(cv, qx + (q != "" ? tw(m.f12, shown) + S : 0), yy + 9 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
	yy += fh + 4 * S
	ql := msg_lower(strings.trim_space(q))
	// the encrypted chats that wait for their first message
	if m.waiting > 0 && ql == "" {
		nx, nw := x + 10 * S, w - 20 * S
		ls := wrap_text(m.f10, "Some encrypted chats appear when they get a new message. Messenger gives a newly linked device no history for them.", nw - 38 * S)
		nh := 14 * S + len(ls) * 15 * S
		yy += 2 * S
		panel_dashed(cv, nx, yy, nw, nh, S, argb(H.faint, 0xff))
		text_in(cv, m.f11, "⚿", nx + 10 * S, yy + 7 * S, 15 * S, argb(tn.soft, 0xff))
		ly := yy + 7 * S
		for l in ls { text_in(cv, m.f10, l, nx + 28 * S, ly, 15 * S, argb(H.dim, 0xff)); ly += 15 * S }
		yy += nh + 4 * S
	}
	rows := msg_rows(m)
	if len(rows) == 0 {
		l := len(m.rooms) == 0 ? "No chats yet" : "No chat matches · ^N finds people on Messenger"
		text_in(cv, m.f11, ellipsize(m.f11, l, w - 20 * S), x + (w - min(tw(m.f11, l), w - 20 * S)) / 2, yy + 30 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	// the rows' heights, so the picked one is in view
	rh :: proc(r: Msg_Row, S: int) -> int {
		switch r.kind {
		case .Head: return 26 * S
		case .More: return 32 * S
		case .Chat: return 50 * S
		}
		return 0
	}
	sel_row := 0
	n := 0
	for r, i in rows do if r.kind != .Head { if n == m.cur do sel_row = i; n += 1 }
	bottom := y + h - 8 * S
	first := 0
	for {
		used := 0
		for i in first ..= sel_row do used += rh(rows[i], S)
		if yy + used <= bottom || first >= sel_row do break
		first += 1
	}
	unread := 0
	for r in m.rooms do if r.unread > 0 do unread += 1
	pick := 0
	for i in 0 ..< first do if rows[i].kind != .Head do pick += 1
	for i in first ..< len(rows) {
		r := rows[i]
		ht := rh(r, S)
		if yy + ht > bottom do break
		switch r.kind {
		case .Head:
			spaced(cv, m.f10b, "CONVERSATIONS", x + 18 * S, yy + 8 * S, 14 * S, H.dim, S)
			if unread > 0 do text_in(cv, m.f10, fmt.tprintf("%d unread", unread), x + 18 * S + spaced_w(m.f10b, "CONVERSATIONS", S) + 8 * S, yy + 8 * S, 14 * S, argb(H.faint, 0xff))
		case .More:
			on := pick == m.cur && !m.writing && !m.newchat
			bx, bw := x + 8 * S, w - 16 * S
			if on {
				fill_rect(cv, bx, yy + S, bw, 30 * S, argb(H.acc, 0x12))
				rounded_rect(cv, bx, yy + S, bw, 30 * S, 0, 0, f32(S), argb(H.acc, 0xff))
				mark_sel(a, bx, yy + S, bw, 30 * S)
			}
			older := len(m.rooms) - MSG_TOP
			l := m.older ? fmt.tprintf("Older · %d chats below", older) : fmt.tprintf("Show %d older chats", older)
			mt := m.older ? "↵ folds" : "↵"
			text_in(cv, m.f11, l, bx + 10 * S, yy + S, 30 * S, argb(on ? H.fg : tn.soft, 0xff))
			text_in(cv, m.f10, mt, bx + bw - 10 * S - tw(m.f10, mt), yy + S, 30 * S, argb(H.dim, 0xff))
			hit_add(a, bx, yy + S, bw, 30 * S, .Row, pick, 0)
			pick += 1
		case .Chat:
			msg_draw_row(a, cv, S, H, m.rooms[r.r], ql, pick, x + 8 * S, yy + S, w - 16 * S, now)
			pick += 1
		}
		yy += ht
	}
}

// A chat in the list: its avatar, name (a group's size beside it), the last line, when, unread.
@(private = "file")
msg_draw_row :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: Msg_Room, q: string, pick, x, y, w: int, now: i64) {
	m := M(a)
	tn := msg_tones(a, H)
	th := a.theme
	rh := 48 * S
	on := pick == m.cur && !m.writing && !m.newchat
	is_open := !m.popup && r.id == m.open
	row_bg := H.bg
	switch {
	case on:
		row_bg = mix(H.bg, H.acc, 0.08)
		fill_rect(cv, x, y, w, rh, argb(row_bg, 0xff))
		rounded_rect(cv, x, y, w, rh, 0, 0, f32(S), argb(H.acc, 0xff))
		fill_rect(cv, x, y, 3 * S, rh, argb(H.acc, 0xff))
		mark_sel(a, x, y, w, rh)
	case is_open:
		row_bg = H.panel
		fill_rect(cv, x, y, w, rh, argb(row_bg, 0xff))
		rounded_rect(cv, x, y, w, rh, 0, 0, f32(S), argb(H.line, 0xff))
	}
	hit_add(a, x, y, w, rh, .Row, pick, 0)
	ax, ay := x + 10 * S, y + 9 * S
	switch {
	case !r.group: // a person: initials in their colour
		c := note_app_color(th, r.name)
		fill_rect(cv, ax, ay, 30 * S, 30 * S, argb(c, 0x1a))
		rounded_rect(cv, ax, ay, 30 * S, 30 * S, 0, 0, f32(S), argb(c, 0x66))
		ini := msg_initials(r.name)
		text_in(cv, m.f11b, ini, ax + (30 * S - tw(m.f11b, ini)) / 2, ay, 30 * S, argb(c, 0xff))
	case r.titled || len(r.members) == 0: // a named group: #
		fill_rect(cv, ax, ay, 30 * S, 30 * S, argb(H.panel, 0xff))
		rounded_rect(cv, ax, ay, 30 * S, 30 * S, 0, 0, f32(S), argb(H.faint, 0xff))
		text_in(cv, m.f13b, "#", ax + (30 * S - tw(m.f13b, "#")) / 2, ay, 30 * S, argb(tn.soft, 0xff))
	case: // an unnamed group: two members' initials, stacked
		for j in 0 ..< min(len(r.members), 2) {
			who := r.members[j]
			c := note_app_color(th, who)
			sx, sy := ax + j * 10 * S, ay + j * 10 * S
			fill_rect(cv, sx - 2 * S, sy - 2 * S, 24 * S, 24 * S, argb(row_bg, 0xff))
			fill_rect(cv, sx, sy, 20 * S, 20 * S, argb(H.bg, 0xff))
			rounded_rect(cv, sx, sy, 20 * S, 20 * S, 0, 0, f32(S), argb(c, 0x88))
			ini := msg_initials(who)
			text_in(cv, m.f8, ini, sx + (20 * S - tw(m.f8, ini)) / 2, sy, 20 * S, argb(c, 0xff))
		}
	}
	tx := ax + 30 * S + 10 * S
	rx := x + w - 10 * S
	when_ := msg_ago(r.ts, now)
	text_in(cv, m.f9, when_, rx - tw(m.f9, when_), y + 8 * S, 14 * S, argb(H.dim, 0xff))
	cw := 0
	if r.unread > 0 {
		cw = count_tag_w(m.f9b, r.unread, S)
		count_tag(cv, m.f9b, rx - cw, y + 27 * S, r.unread, S, H.acc, H.bg, row_bg)
	}
	right := max(tw(m.f9, when_), cw) + 8 * S
	nf := r.unread > 0 ? m.f12b : m.f12
	name := msg_label(r, q)
	people := r.group && len(r.members) > 0 ? fmt.tprint(len(r.members) + 1) : ""
	pw := people != "" ? tw(m.f9, people) + 6 * S : 0
	nm := ellipsize(nf, name, rx - right - tx - pw)
	text_in(cv, nf, nm, tx, y + 7 * S, 17 * S, argb(H.fg, 0xff))
	if people != "" do text_in(cv, m.f9, people, tx + tw(nf, nm) + 6 * S, y + 7 * S, 17 * S, argb(H.dim, 0xff))
	lx := tx
	if r.unread > 0 {
		nl := fmt.tprintf("%d new · ", r.unread)
		text_in(cv, m.f10b, nl, lx, y + 26 * S, 15 * S, argb(H.acc, 0xff))
		lx += tw(m.f10b, nl)
	}
	last := r.last
	if r.mine do last = strings.concatenate({"you: ", last}, context.temp_allocator)
	else if r.group && r.who != "" do last = strings.concatenate({strings.fields(r.who, context.temp_allocator)[0], ": ", last}, context.temp_allocator)
	text_in(cv, m.f10, ellipsize(m.f10, last, rx - right - lx), lx, y + 26 * S, 15 * S, argb(r.unread > 0 ? tn.soft : H.dim, 0xff))
}

@(private = "file")
msg_draw_chat :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := M(a)
	tn := msg_tones(a, H)
	th := a.theme
	room, ok := msg_open_room(m)
	if !ok {
		l := len(m.rooms) > 0 ? "Pick a chat · ↵ opens it" : "Your chats show here once Messenger has sent them"
		text_in(cv, m.f12, l, x + (w - tw(m.f12, l)) / 2, y + h / 2 - 10 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	readonly := m.state == "relogin"
	// the head: the name, DM or how many people (^I lists them), the members of an unnamed group
	hy := y + 10 * S
	meta := room.group ? fmt.tprintf("%d people%s", len(room.members) + 1, m.members ? "" : " · ^I lists them") : "DM"
	mw := tw(m.f10, meta)
	text_in(cv, m.f13b, ellipsize(m.f13b, room.name, w - 32 * S - mw - 10 * S), x + 16 * S, hy, 18 * S, argb(H.fg, 0xff))
	text_in(cv, m.f10, meta, x + w - 16 * S - mw, hy, 18 * S, argb(H.dim, 0xff))
	hy += 18 * S
	if room.group && (m.members || !room.titled) && len(room.members) > 0 {
		hy += 3 * S
		ml := strings.concatenate({"You, ", strings.join(room.members, ", ", context.temp_allocator)}, context.temp_allocator)
		text_in(cv, m.f10, ellipsize(m.f10, ml, w - 32 * S), x + 16 * S, hy, 15 * S, argb(tn.soft, 0xff))
		hy += 15 * S
	}
	hy += 9 * S
	fill_rect(cv, x, hy, w, S, argb(H.line, 0xff))
	// the line to write, at the bottom
	cxx, cww, chh := x + 12 * S, w - 24 * S, 44 * S
	cy := y + h - chh - 10 * S
	fill_rect(cv, cxx, cy, cww, chh, argb(H.panel, 0xff))
	rounded_rect(cv, cxx, cy, cww, chh, 0, 0, f32(S), readonly ? argb(H.line, 0xff) : argb(H.acc, m.writing ? 0xff : 0x66))
	sendl := panel_busy(&m.pn) && m.run.verb == "send" ? "sending…" : "↵ send"
	sl := tw(m.f10, sendl)
	text_in(cv, m.f10, sendl, cxx + cww - 10 * S - sl, cy, chh, argb(H.dim, 0xff))
	q := panel_text(&m.pn)
	fw := cww - 30 * S - sl
	ph := readonly ? "Read-only · log in again to write" : (room.group ? "Write to the group…" : fmt.tprintf("Write to %s…", strings.fields(room.name, context.temp_allocator)[0] if len(strings.fields(room.name, context.temp_allocator)) > 0 else room.name))
	if q == "" do text_in(cv, m.f12, ph, cxx + 10 * S, cy, chh, argb(H.faint, 0xff))
	shown := q
	for tw(m.f12, shown) > fw && len(shown) > 0 do shown = shown[1:] // the end shows while it is long
	text_in(cv, m.f12, shown, cxx + 10 * S, cy, chh, argb(H.fg, 0xff))
	if m.writing do fill_rect(cv, cxx + 10 * S + (q != "" ? tw(m.f12, shown) + S : 0), cy + 13 * S, 2 * S, 18 * S, argb(H.acc, 0xff))
	// the messages, newest at the bottom: laid out first (heights), then drawn from the bottom up
	top, bottom := hy + S + 12 * S, cy - 12 * S
	pad := 16 * S
	maxw := (w - 2 * pad) * 78 / 100
	inner := maxw - 20 * S
	pic_w, pic_h := min(inner, 360 * S), 240 * S // a photo or video fits in this
	Item :: struct { kind: int, i: int, lines: []string, h, bw, bh: int, inline: bool } // 0 a day line, 1 a name, 2 a bubble, 3 a picture; h: with the gap under it
	items := make([dynamic]Item, 0, len(m.msgs) * 2, context.temp_allocator)
	prev_day: i64 = -1
	prev := ""
	for l, i in m.msgs {
		day := l.ts / 86400
		run := l.mine ? "\x00you" : l.sender
		if day != prev_day { append(&items, Item{kind = 0, i = i, h = 12 * S + 10 * S}); prev_day = day; prev = "" }
		new_run := run != prev
		if new_run && len(items) > 0 && items[len(items) - 1].kind != 0 do items[len(items) - 1].h += 7 * S // runs 10 apart, messages 3
		if new_run && room.group && !l.mine do append(&items, Item{kind = 1, i = i, h = 13 * S + 3 * S})
		prev = run
		tm := msg_clock(l.ts)
		tmw := tw(m.f9, tm) + 8 * S
		if l.media != "" {
			if img := image_scaled(a, l.media, pic_w, pic_h, false, f32(S)); img.ok {
				bh := img.h + 8 * S + 13 * S
				append(&items, Item{kind = 3, i = i, h = bh + 3 * S, bw = img.w + 8 * S, bh = bh})
				continue
			}
		}
		t := l.text
		if l.kind == "emote" do t = strings.concatenate({"* ", l.sender, " ", t}, context.temp_allocator)
		lines := wrap_hard(m.f12, t, inner)
		if len(lines) == 0 do lines = {""}
		bw := 0
		for s in lines do bw = max(bw, tw(m.f12, s))
		lastw := tw(m.f12, lines[len(lines) - 1])
		inline := lastw + tmw <= inner // the time at the end of the last line, or under it
		bw = max(bw, inline ? lastw + tmw : tmw)
		nl := len(lines) + (inline ? 0 : 1)
		bh := nl * 17 * S + 12 * S
		append(&items, Item{kind = 2, i = i, lines = lines, h = bh + 3 * S, bw = bw + 20 * S, bh = bh, inline = inline})
	}
	total := 0
	for it in items do total += it.h
	view := bottom - top
	m.scroll = clamp(m.scroll, 0, max((total - view) / (18 * S) + 1, 0))
	yy := bottom + m.scroll * 18 * S
	#reverse for it in items {
		yy -= it.h
		if yy + it.h < top do break
		v0, v1 := max(yy, top), min(yy + max(it.bh, 12 * S), bottom) // what shows of it (the canvas has no clip)
		if v1 <= v0 do continue
		whole := v0 == yy && v1 == yy + max(it.bh, 12 * S)
		l := m.msgs[it.i]
		switch it.kind {
		case 0:
			if !whole do continue
			d := msg_day(l.ts, now)
			dw := spaced_w(m.f9, d, S) + 20 * S
			ly := yy + 6 * S
			fill_rect(cv, x + pad, ly, (w - 2 * pad - dw) / 2, S, argb(H.line, 0xff))
			fill_rect(cv, x + pad + (w - 2 * pad + dw) / 2, ly, (w - 2 * pad - dw) / 2, S, argb(H.line, 0xff))
			spaced(cv, m.f9, d, x + (w - dw) / 2 + 10 * S, yy, 12 * S, H.faint, S)
		case 1:
			if !whole do continue
			text_in(cv, m.f10b, l.sender, x + pad, yy, 13 * S, argb(note_app_color(th, l.sender), 0xff))
		case 2, 3:
			bw, bh := it.bw, it.bh
			bx := l.mine ? x + w - pad - bw : x + pad
			bg := l.mine ? mix(H.bg, H.acc, 0.1) : H.panel
			bd := l.mine ? mix(H.bg, H.acc, 0.35) : H.line
			v1 = min(yy + bh, bottom)
			fill_rect(cv, bx, v0, bw, v1 - v0, argb(bg, 0xff))
			fill_rect(cv, bx, v0, S, v1 - v0, argb(bd, 0xff)); fill_rect(cv, bx + bw - S, v0, S, v1 - v0, argb(bd, 0xff))
			if yy >= top do fill_rect(cv, bx, yy, bw, S, argb(bd, 0xff))
			if yy + bh <= bottom do fill_rect(cv, bx, yy + bh - S, bw, S, argb(bd, 0xff))
			if room.group && !l.mine do fill_rect(cv, bx, v0, 2 * S, v1 - v0, argb(note_app_color(th, l.sender), 0xff))
			inside :: proc(y0, h, top, bottom: int) -> bool { return y0 >= top && y0 + h <= bottom }
			tm := msg_clock(l.ts)
			fg := l.mine ? H.fg : tn.soft
			if it.kind == 3 { // the picture, a video's ▶ on it, the time under it; a click opens it
				img := image_scaled(a, l.media, pic_w, pic_h, false, f32(S))
				iy := yy + 4 * S
				p0, p1 := max(iy, top), min(iy + img.h, bottom)
				if p1 > p0 {
					blit_image(cv, img.px[(p0 - iy) * img.w:], img.w, p1 - p0, bx + 4 * S, p0)
					hit_add(a, bx + 4 * S, p0, img.w, p1 - p0, .Item, it.i, 1)
				}
				if l.kind == "video" && inside(iy, img.h, top, bottom) {
					d := 44 * S
					fill_rect(cv, bx + 4 * S + (img.w - d) / 2, yy + 4 * S + (img.h - d) / 2, d, d, argb(th.bg, 0xe0))
					text_in(cv, m.f13b, "▶", bx + 4 * S + (img.w - tw(m.f13b, "▶")) / 2, yy + 4 * S + (img.h - d) / 2, d, argb(H.fg, 0xff))
				}
				if inside(iy + img.h + 2 * S, 13 * S, top, bottom) do text_in(cv, m.f9, tm, bx + bw - 8 * S - tw(m.f9, tm), iy + img.h + 2 * S, 13 * S, argb(H.faint, 0xff))
				continue
			}
			for s, k in it.lines do if inside(yy + 6 * S + k * 17 * S, 17 * S, top, bottom) do text_in(cv, m.f12, s, bx + 10 * S, yy + 6 * S + k * 17 * S, 17 * S, argb(fg, 0xff))
			ty := it.inline ? yy + 6 * S + (len(it.lines) - 1) * 17 * S : yy + 6 * S + len(it.lines) * 17 * S
			if inside(ty, 17 * S, top, bottom) do text_in(cv, m.f9, tm, bx + bw - 10 * S - tw(m.f9, tm), ty, 17 * S, argb(H.faint, 0xff))
		}
	}
	if m.scroll > 0 do text_in(cv, m.f10, "↓ newer · PgDn", x + w - pad - tw(m.f10, "↓ newer · PgDn"), top - 10 * S, 14 * S, argb(H.acc, 0xff))
}

// ^N: who to write to, and the people Messenger found for it.
@(private = "file")
msg_draw_newchat :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	m := M(a)
	pad := 14 * S
	yy := y + 12 * S
	spaced(cv, m.f10b, "NEW CHAT", x + pad, yy, 16 * S, H.dim, S)
	yy += 22 * S
	fh := 34 * S
	fill_rect(cv, x + pad, yy, w - 2 * pad, fh, argb(H.panel, 0xff))
	rounded_rect(cv, x + pad, yy, w - 2 * pad, fh, 0, 0, f32(S), argb(H.acc, 0xff))
	q := string(m.who[:])
	if q == "" do text_in(cv, m.f12, "A name…", x + pad + 16 * S, yy, fh, argb(H.faint, 0xff))
	q = ellipsize(m.f12, q, w - 2 * pad - 24 * S)
	text_in(cv, m.f12, q, x + pad + 12 * S, yy, fh, argb(H.fg, 0xff))
	fill_rect(cv, x + pad + 12 * S + (q != "" ? tw(m.f12, q) + S : 0), yy + 8 * S, 2 * S, 18 * S, argb(H.acc, 0xff))
	yy += fh + 10 * S
	if panel_busy(&m.pn) { text_in(cv, m.f11, "Searching Messenger…", x + pad, yy, 20 * S, argb(H.acc, 0xff)); return }
	if len(m.people) == 0 {
		l := m.searched == "" ? "↵ searches Messenger for the name" : "Nobody found · try another spelling"
		text_in(cv, m.f11, l, x + pad, yy, 20 * S, argb(H.dim, 0xff))
		return
	}
	rh := 40 * S
	for p, i in m.people {
		if yy + rh > y + h do break
		on := i == m.pcur
		if on { fill_rect(cv, x, yy, w, rh, argb(H.acc, 0x22)); fill_rect(cv, x, yy, 3 * S, rh, argb(H.acc, 0xff)); mark_sel(a, x, yy, w, rh) }
		hit_add(a, x, yy, w, rh, .Item, i, 0)
		ac := note_app_color(a.theme, p[1])
		fill_rect(cv, x + pad, yy + 7 * S, 26 * S, 26 * S, argb(ac, 0x22))
		ini := msg_initials(p[1])
		text_in(cv, m.f10b, ini, x + pad + (26 * S - tw(m.f10b, ini)) / 2, yy + 7 * S, 26 * S, argb(ac, 0xff))
		text_in(cv, on ? m.f12b : m.f12, ellipsize(m.f12b, p[1], w - 2 * pad - 36 * S), x + pad + 36 * S, yy, rh, argb(H.fg, 0xff))
		yy += rh
	}
}

msg_dump :: proc(a: ^App) -> string {
	m := M(a)
	sb := strings.builder_make(context.temp_allocator)
	view := msg_view(m)
	fmt.sbprintfln(&sb, "messenger %s · %d unread%s", m.state, m.unread, m.popup ? (m.chat ? " · chat" : " · list") : "")
	if view != .Chats {
		cur, _, fail := msg_setup_at(m)
		fmt.sbprintfln(&sb, "card %v%s", view, view == .Setup ? fmt.tprintf(" · step %d%s", cur + 1, fail != "" ? fmt.tprintf(" · failed: %s", fail) : "") : "")
		if view == .Login && len(m.input) > 0 do fmt.sbprintfln(&sb, "input %s%s", m.reveal ? panel_text(&m.pn) : msg_curl_look(panel_text(&m.pn)), msg_cookie_missing(panel_text(&m.pn)) == "" ? " · session found" : fmt.tprintf(" · no %s", msg_cookie_missing(panel_text(&m.pn))))
		panel_dump_toast(&m.pn, &sb)
		return strings.to_string(sb)
	}
	if m.state == "relogin" do fmt.sbprintln(&sb, "banner logged out")
	if m.state == "error" do fmt.sbprintln(&sb, "banner not answering")
	if m.newchat {
		fmt.sbprintfln(&sb, "newchat %s", string(m.who[:]))
		for p, i in m.people do fmt.sbprintfln(&sb, "%s person %s", i == m.pcur ? "*" : " ", p[1])
	}
	if len(m.find) > 0 do fmt.sbprintfln(&sb, "find %s", string(m.find[:]))
	if m.waiting > 0 && len(m.find) == 0 do fmt.sbprintfln(&sb, "waiting %d encrypted", m.waiting)
	ql := msg_lower(strings.trim_space(string(m.find[:])))
	pick := 0
	for r in msg_rows(m) {
		mark := pick == m.cur && !m.writing ? "*" : " "
		switch r.kind {
		case .Head: fmt.sbprintln(&sb, "  CONVERSATIONS")
		case .More: fmt.sbprintfln(&sb, "%s %s", mark, m.older ? "Older · folds" : fmt.tprintf("Show %d older chats", len(m.rooms) - MSG_TOP)); pick += 1
		case .Chat:
			x := m.rooms[r.r]
			fmt.sbprintfln(&sb, "%s %s%s%s · %s", mark, msg_label(x, ql), x.group && len(x.members) > 0 ? fmt.tprintf(" [%d]", len(x.members) + 1) : "", x.unread > 0 ? fmt.tprintf(" (%d)", x.unread) : "", x.last)
			pick += 1
		}
	}
	if m.open != "" do fmt.sbprintfln(&sb, "open %s", m.open)
	for l in m.msgs do fmt.sbprintfln(&sb, "  %s %s: %s%s", l.mine ? ">" : "<", l.sender, l.text, l.media != "" ? fmt.tprintf(" (picture %s)", l.media) : "")
	if m.writing do fmt.sbprintfln(&sb, "writing %s", panel_text(&m.pn))
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
