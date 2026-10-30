package k4

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --mail: your mail (k4-mail: Gmail through its API, gmail.py; aerc's IMAP accounts, mailimap.py), the Kestrel design's KMail boards
// (KMailWindow, KMailParts, KMailCompose, KMailStates), 1100×680: the labels (180: All inboxes, then
// a section per account: Gmail's labels, each IMAP account's folders), the threads of
// the picked one or of a search (360), and the reading pane: the open thread as a conversation
// (older messages folded to a line, the newest open, quoted text behind a button, attachments as
// chips) with a line to reply under it, or the card to write a mail. With --popup (the bar's
// module) 420×560, one pane at a time: the list (a label dropdown; Tab steps it), ↵ the thread.
// Typing in the list searches: the list narrows at once (from:, has:attachment, is:unread,
// is:starred understood), and after a pause Gmail is asked too. ↑↓ move, ↵ opens (reads) the
// thread; there typing starts a reply (↵ sends, ⇧↵ a new line, ^E the whole card), ↑↓ PgUp PgDn
// scroll, ↵ opens the picked attachment (←→ picks another). ^E archive, Del trash (^Z undoes
// either), ^S star, ^U unread, ^R reply, ^⇧R reply all, ^F forward, ^N a new mail, ^O the thread in
// the browser, ^L its newest link. The card: Tab the next field, ↵ in To or Cc adds the person
// (a name is looked up in your mail), ^A attaches files, ^E writes the body in nvim, ^↵ sends,
// Esc keeps it as a draft.
// Before it works a card fills the window: No Google client (↵ the Cloud Console, ^O pick the
// file), Connect (↵ signs in with the browser), Waiting for the browser, Sign in again (? how to
// stop it). Offline is a banner (the mail is what was saved; what you do waits).
// The data comes from k4-mail (panel lines R and L, panel.odin), again every 3 s while open; the
// loader syncs in the background every 10 s:
//   S <state ok|syncing|noclient|connect|signin|offline|error> <inbox unread> <account> <note> <waiting> <synced unix time>
//   V <label id> <search> <more 1|0>
//   Y <account> <address> <name>             who you can write as: gmail, then the IMAP accounts (aerc's)
//   G <label id> <name> <unread> <system|user|folder> <threads in it> <account|all>   ALL (every inbox) first;
//                                             an IMAP folder is <account>:<folder>
//   T <thread> <from> <subject> <snippet> <unix time> <unread> <starred> <count> <attachments> <labels, | between> <account>
//   O <thread> <subject> <labels> <starred>   the open one; then its messages, oldest first:
//   M <id> <from> <address> <to> <cc> <unix time> <unread> <body> <quoted> <the quote's first line>
//                                             (line breaks in body and quoted as U+2028)
//   A <message> <attachment id> <name> <size> <type>
// The runner's verbs: open T, close, label G, search Q, clear, more, archive T, unarchive T, trash
// T, untrash T, star T, unread T, send reply|replyall T ($K4_INPUT the text), send compose KIND
// [T] ($K4_INPUT the draft: To:, Cc:, Subject:, Attach: lines, a blank line, the body), draft
// KIND [T], prefill KIND T (k4:draft), edit (k4:draft), pick (k4:attach PATH SIZE lines), who
// NAME (k4:who NAME ADDRESS lines), attachment M ID NAME, browser [T], url URL, connect,
// pickclient, howto, sync; k4:sent after a sent card.

MAIL_W, MAIL_H :: 1100, 680
MAIL_PW, MAIL_PH :: 420, 560
MAIL_LABELS_W :: 180
MAIL_LIST_W :: 360
MAIL_NL :: " "
MAIL_SEARCH_MS :: 700 // a pause in typing, then Gmail is searched

Mail_Label :: struct { id, name, kind, account: string, unread, total: int }
Mail_Thread :: struct { id, from, subject, snippet, labels, account: string, ts: i64, unread, starred, attach: bool, count: int }
Mail_From :: struct { id, addr, name: string } // an account you can write as
Mail_Msg :: struct { id, from, addr, to, cc, body, quoted, qhead: string, ts: i64, unread: bool }
Mail_Att :: struct { msg, id, name, mime: string, size: int }
Mail_Focus :: enum { List, Labels, Read, Reply, Compose }

// The card to write a mail: its kind (new, reply, replyall, forward), the thread it answers, the
// people (name, address), the fields' text, the files (path, size).
Mail_Card :: struct {
	kind, thread: string,
	to, cc:      [dynamic][2]string,
	text:        [4][dynamic]u8, // to, cc, subject, body
	field:       int,
	files:       [dynamic][2]string,
	from:        int, // which of the accounts it goes from (Mail.froms)
}

Mail :: struct {
	using pn: Panel,
	arena:   vmem.Arena, // what a load brought, freed whole by the next one
	state, account, note, label, query: string,
	unread, waiting: int,
	synced:  i64,
	more:    bool,
	labels:  [dynamic]Mail_Label,
	threads: [dynamic]Mail_Thread,
	froms:   [dynamic]Mail_From,
	open, subject, olabels: string,
	ostar:   bool,
	msgs:    [dynamic]Mail_Msg,
	atts:    [dynamic]Mail_Att,
	// what you do (kept across loads)
	focus:   Mail_Focus,
	cur, lcur, acur, scroll: int,
	find:    [dynamic]u8,
	typed:   time.Tick, // when the find field last changed (Gmail is searched after a pause)
	asked:   string,    // what Gmail was last searched for from the field
	folds:   map[string]bool, // a message unfolded by hand
	quotes:  map[string]bool, // a message's quoted text shown
	replyall: bool,
	seen:    string, // the thread whose folds are set
	card:    Mail_Card,
	writing: bool, // the card shows
	card_lead: string, // a reply line taken into the card (^E): it stays first when the quote comes
	undo:    [2]string, // the last archive or trash undone by ^Z: its verb, the thread
}

mail_setup :: proc(a: ^App, data: string) {
	m := new(Mail)
	_ = vmem.arena_init_growing(&m.arena)
	m.mode = {draw = mail_draw, key = mail_key, click = mail_click, scroll = mail_scroll, loaded = mail_loaded, ran = mail_ran, tick = mail_tick, dump = mail_dump}
	panel_init(a, &m.pn, "mail", data)
	m.refresh_ms = 3000
	a.width, a.height = m.popup ? MAIL_PW : MAIL_W, m.popup ? MAIL_PH : MAIL_H
	if m.open != "" do m.focus = .Read // (opened at a thread: a card, the launcher)
	if to := os.get_env("K4_MAIL_COMPOSE", context.temp_allocator); to != "" { // (k4-mail window --compose [TO])
		mail_card_open(m, "new", "")
		if t := strings.trim_space(to); t != "" { append(&m.card.to, [2]string{strings.clone(t), strings.clone(t)}); m.card.field = 2 }
	}
}

@(private = "file")
ML :: proc(a: ^App) -> ^Mail { return (^Mail)(a.pn) }

@(private = "file")
mail_now :: proc() -> i64 {
	if v, ok := strconv.parse_i64(os.get_env("K4_MAIL_NOW", context.temp_allocator)); ok do return v
	return time.to_unix_seconds(time.now())
}

@(private = "file")
mail_loaded :: proc(a: ^App, data: string) {
	m := ML(a)
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al: runtime.Allocator) -> string { return strings.clone(s, al) }
	m.labels = make([dynamic]Mail_Label, al)
	m.threads = make([dynamic]Mail_Thread, al)
	m.msgs = make([dynamic]Mail_Msg, al)
	m.atts = make([dynamic]Mail_Att, al)
	m.froms = make([dynamic]Mail_From, al)
	m.state, m.account, m.note, m.label, m.query, m.open, m.subject, m.olabels = "", "", "", "INBOX", "", "", "", ""
	m.unread, m.waiting, m.synced, m.more, m.ostar = 0, 0, 0, false, false
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			m.state, m.account, m.note = c(fget(f, 1), al), c(fget(f, 3), al), c(fget(f, 4), al)
			m.unread, _ = strconv.parse_int(fget(f, 2))
			m.waiting, _ = strconv.parse_int(fget(f, 5))
			m.synced, _ = strconv.parse_i64(fget(f, 6))
		case "V":
			m.label, m.query, m.more = c(fget(f, 1), al), c(fget(f, 2), al), fget(f, 3) == "1"
		case "G":
			l := Mail_Label{id = c(fget(f, 1), al), name = c(fget(f, 2), al), kind = c(fget(f, 4), al), account = c(fget(f, 6), al)}
			l.unread, _ = strconv.parse_int(fget(f, 3))
			l.total, _ = strconv.parse_int(fget(f, 5))
			append(&m.labels, l)
		case "T":
			t := Mail_Thread{id = c(fget(f, 1), al), from = c(fget(f, 2), al), subject = c(fget(f, 3), al), snippet = c(fget(f, 4), al),
				unread = fget(f, 6) == "1", starred = fget(f, 7) == "1", attach = fget(f, 9) == "1", labels = c(fget(f, 10), al), account = c(fget(f, 11), al)}
			t.ts, _ = strconv.parse_i64(fget(f, 5))
			t.count, _ = strconv.parse_int(fget(f, 8))
			append(&m.threads, t)
		case "Y": append(&m.froms, Mail_From{id = c(fget(f, 1), al), addr = c(fget(f, 2), al), name = c(fget(f, 3), al)})
		case "O":
			m.open, m.subject, m.olabels, m.ostar = c(fget(f, 1), al), c(fget(f, 2), al), c(fget(f, 3), al), fget(f, 4) == "1"
		case "M":
			g := Mail_Msg{id = c(fget(f, 1), al), from = c(fget(f, 2), al), addr = c(fget(f, 3), al), to = c(fget(f, 4), al), cc = c(fget(f, 5), al),
				unread = fget(f, 7) == "1", body = c(fget(f, 8), al), quoted = c(fget(f, 9), al), qhead = c(fget(f, 10), al)}
			g.ts, _ = strconv.parse_i64(fget(f, 6))
			append(&m.msgs, g)
		case "A":
			t := Mail_Att{msg = c(fget(f, 1), al), id = c(fget(f, 2), al), name = c(fget(f, 3), al), mime = c(fget(f, 5), al)}
			t.size, _ = strconv.parse_int(fget(f, 4))
			append(&m.atts, t)
		}
	}
	if m.open != m.seen { // another thread: its folds and the picked file start again
		delete(m.seen)
		m.seen = strings.clone(m.open)
		for k in m.folds do delete(k)
		for k in m.quotes do delete(k)
		clear(&m.folds); clear(&m.quotes)
		m.scroll, m.acur = 0, 0
	}
	m.cur = clamp(m.cur, 0, max(len(mail_list(m)) - 1, 0))
	m.acur = clamp(m.acur, 0, max(len(m.atts) - 1, 0))
	if m.open == "" && (m.focus == .Read || m.focus == .Reply) do m.focus = .List
}

// ---------- the list ----------

@(private = "file")
mail_lower :: proc(s: string) -> string { return strings.to_lower(s, context.temp_allocator) }

// The find field over the threads at hand: words, and Gmail's from:, has:attachment, is:unread, is:starred.
@(private = "file")
mail_match :: proc(t: Mail_Thread, q: string) -> bool {
	for w in strings.fields(q, context.temp_allocator) {
		switch {
		case strings.has_prefix(w, "from:"): if !strings.contains(mail_lower(t.from), w[5:]) do return false
		case w == "has:attachment": if !t.attach do return false
		case strings.has_prefix(w, "has:"): return false
		case w == "is:unread": if !t.unread do return false
		case w == "is:starred": if !t.starred do return false
		case: if !strings.contains(mail_lower(strings.join({t.from, t.subject, t.snippet}, " ", context.temp_allocator)), w) do return false
		}
	}
	return true
}

// The threads shown: all of the label's (or of Gmail's search), narrowed by the field until
// Gmail's answer for it is in.
@(private = "file")
mail_list :: proc(m: ^Mail) -> []int {
	out := make([dynamic]int, 0, len(m.threads), context.temp_allocator)
	q := mail_lower(strings.trim_space(string(m.find[:])))
	gmail_has_it := q != "" && q == mail_lower(m.query)
	for t, i in m.threads do if gmail_has_it || mail_match(t, q) do append(&out, i)
	return out[:]
}

// The thread the keys act on: the open one while reading, else the picked row's.
@(private = "file")
mail_target :: proc(m: ^Mail) -> string {
	if (m.focus == .Read || m.focus == .Reply) && m.open != "" do return m.open
	l := mail_list(m)
	if m.cur < len(l) do return m.threads[l[m.cur]].id
	return ""
}

@(private = "file")
mail_label :: proc(m: ^Mail) -> Mail_Label {
	for l in m.labels do if l.id == m.label do return l
	return {id = m.label, name = m.label == "INBOX" ? "Inbox" : m.label}
}

@(private = "file")
mail_ready :: proc(m: ^Mail) -> bool { return m.state == "ok" || m.state == "offline" || m.state == "error" || m.state == "syncing" }

// A label's colour (its dot, its tags): the theme's, in turn, for your own labels; else dim.
@(private = "file")
mail_label_color :: proc(a: ^App, m: ^Mail, name: string, H: HUD) -> u32 {
	cols := [5]u32{a.theme.yellow, a.theme.green, a.theme.blue, a.theme.red, H.acc}
	n := 0
	for l in m.labels do if l.kind == "user" { if l.name == name do return cols[n % 5]; n += 1 }
	return H.dim
}

@(private = "file")
mail_api_off :: proc(m: ^Mail) -> bool { return m.state == "error" && strings.contains(m.note, "Gmail API is off") }

// An account's name and colour (its tag in All inboxes, its section).
@(private = "file")
mail_account :: proc(a: ^App, m: ^Mail, id: string, H: HUD) -> (string, u32) {
	cols := [5]u32{a.theme.blue, a.theme.green, a.theme.yellow, a.theme.red, H.acc}
	for f, i in m.froms do if f.id == id do return f.name, cols[i % 5]
	return id == "gmail" ? "Gmail" : id, H.dim
}

@(private = "file")
mail_multi :: proc(m: ^Mail) -> bool { return len(m.froms) > 1 }

// The From the card starts with: the shown account's (All inboxes: the first).
@(private = "file")
mail_from_default :: proc(m: ^Mail) -> int {
	acct := mail_label(m).account
	for f, i in m.froms do if f.id == acct do return i
	return 0
}

@(private = "file")
mail_unfolded :: proc(m: ^Mail, i: int) -> bool {
	if v, ok := m.folds[m.msgs[i].id]; ok do return v
	return i == len(m.msgs) - 1 || m.msgs[i].unread
}

@(private = "file")
mail_toggle :: proc(mp: ^map[string]bool, id: string, now: bool) {
	if id in mp do mp[id] = now
	else do mp[strings.clone(id)] = now
}

@(private = "file")
mail_open_row :: proc(a: ^App) {
	m := ML(a)
	l := mail_list(m)
	if m.cur >= len(l) do return
	t := m.threads[l[m.cur]]
	if t.id != m.open do panel_run(a, "open", t.id)
	m.focus = .Read
}

@(private = "file")
mail_send_reply :: proc(a: ^App) {
	m := ML(a)
	if strings.trim_space(panel_text(&m.pn)) == "" || m.open == "" { panel_say(&m.pn, "Write something first", a.theme.yellow); return }
	if m.state == "signin" { panel_say(&m.pn, "Sign in again to send", a.theme.yellow); return }
	text := strings.clone(panel_text(&m.pn), context.temp_allocator)
	panel_run(a, "send", m.replyall ? "replyall" : "reply", m.open, secret = text)
	panel_clear(&m.pn)
	m.replyall = false
	m.focus = .Read
}

// ---------- the card ----------

@(private = "file")
mail_card_free :: proc(c: ^Mail_Card) {
	delete(c.kind); delete(c.thread)
	for p in c.to { delete(p[0]); delete(p[1]) }
	for p in c.cc { delete(p[0]); delete(p[1]) }
	for p in c.files { delete(p[0]); delete(p[1]) }
	delete(c.to); delete(c.cc); delete(c.files)
	for &t in c.text do delete(t)
	c^ = {}
}

@(private = "file")
mail_card_open :: proc(m: ^Mail, kind, thread: string) {
	mail_card_free(&m.card)
	m.card.kind, m.card.thread = strings.clone(kind), strings.clone(thread)
	m.card.from = mail_from_default(m)
	m.writing, m.focus = true, .Compose
}

@(private = "file")
mail_card_close :: proc(m: ^Mail) {
	mail_card_free(&m.card)
	m.writing = false
	m.focus = m.open != "" ? .Read : .List
}

@(private = "file")
mail_card_title :: proc(c: ^Mail_Card) -> string {
	switch c.kind {
	case "reply": return "Reply"
	case "replyall": return "Reply all"
	case "forward": return "Forward"
	}
	return "New mail"
}

// The card as gmail.py reads it: To:, Cc:, Subject:, Attach: lines, a blank line, the body.
@(private = "file")
mail_card_text :: proc(m: ^Mail, c: ^Mail_Card) -> string {
	people :: proc(ps: [][2]string, rest: string) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for p, i in ps {
			if i > 0 do strings.write_string(&sb, ", ")
			if p[0] != p[1] && p[0] != "" do fmt.sbprintf(&sb, "%s <%s>", p[0], p[1])
			else do strings.write_string(&sb, p[1])
		}
		if r := strings.trim_space(rest); r != "" { if len(ps) > 0 do strings.write_string(&sb, ", "); strings.write_string(&sb, r) }
		return strings.to_string(sb)
	}
	sb := strings.builder_make(context.temp_allocator)
	if c.from >= 0 && c.from < len(m.froms) do fmt.sbprintfln(&sb, "From: %s", m.froms[c.from].id)
	fmt.sbprintfln(&sb, "To: %s", people(c.to[:], string(c.text[0][:])))
	fmt.sbprintfln(&sb, "Cc: %s", people(c.cc[:], string(c.text[1][:])))
	fmt.sbprintfln(&sb, "Subject: %s", string(c.text[2][:]))
	for f in c.files do fmt.sbprintfln(&sb, "Attach: %s", f[0])
	fmt.sbprintf(&sb, "\n%s", string(c.text[3][:]))
	return strings.to_string(sb)
}

// k4:draft back from gmail.py (prefill, the editor): the card takes its fields and body; what the
// card held of the body before (a reply line taken along) goes first.
@(private = "file")
mail_card_take :: proc(m: ^Mail, draft: string) {
	t, _ := strings.replace_all(draft, MAIL_NL, "\n", context.temp_allocator)
	head, body := t, ""
	if i := strings.index(t, "\n\n"); i >= 0 do head, body = t[:i], t[i + 2:]
	c := &m.card
	for p in c.to { delete(p[0]); delete(p[1]) }
	for p in c.cc { delete(p[0]); delete(p[1]) }
	for p in c.files { delete(p[0]); delete(p[1]) }
	clear(&c.to); clear(&c.cc); clear(&c.files)
	for &x in c.text do clear(&x)
	add :: proc(list: ^[dynamic][2]string, v: string) {
		for part in strings.split(v, ",", context.temp_allocator) {
			p := strings.trim_space(part)
			if p == "" do continue
			name, addr := p, p
			if i := strings.index_byte(p, '<'); i >= 0 && strings.has_suffix(p, ">") do name, addr = strings.trim(strings.trim_space(p[:i]), "\""), p[i + 1:len(p) - 1]
			append(list, [2]string{strings.clone(name), strings.clone(addr)})
		}
	}
	for ln in strings.split_lines(head, context.temp_allocator) {
		i := strings.index_byte(ln, ':')
		if i < 0 do continue
		v := strings.trim_space(ln[i + 1:])
		switch strings.to_lower(strings.trim_space(ln[:i]), context.temp_allocator) {
		case "from": for f, k in m.froms do if f.id == v do c.from = k
		case "to": add(&c.to, v)
		case "cc": add(&c.cc, v)
		case "subject": append(&c.text[2], ..transmute([]u8)v)
		case "attach": append(&c.files, [2]string{strings.clone(v), strings.clone("")})
		}
	}
	append(&c.text[3], ..transmute([]u8)body)
	c.field = len(c.to) == 0 ? 0 : 3
}

// ↵ in To or Cc: an address goes in as it is; a name is looked up in your mail (k4:who).
@(private = "file")
mail_card_add :: proc(a: ^App) {
	m := ML(a)
	c := &m.card
	t := strings.trim_space(string(c.text[c.field][:]))
	if t == "" { c.field = min(c.field + 1, 3); return }
	if strings.contains(t, "@") {
		append(c.field == 0 ? &c.to : &c.cc, [2]string{strings.clone(t), strings.clone(t)})
		clear(&c.text[c.field])
		return
	}
	panel_run(a, "who", t)
}

@(private = "file")
mail_card_send :: proc(a: ^App) {
	m := ML(a)
	c := &m.card
	if len(c.to) == 0 && strings.trim_space(string(c.text[0][:])) == "" { panel_say(&m.pn, "Add someone in To first", a.theme.yellow); return }
	panel_run(a, "send", "compose", c.kind, c.thread, secret = mail_card_text(m, c))
}

// ---------- keys ----------

@(private = "file")
mail_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := ML(a)
	shift := a.shift
	plain := text != "" && k == .None && !ctrl && !alt
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	if ctrl && low == 'c' && m.focus != .Compose { panel_close(a); return true }
	if !mail_ready(m) { // a card fills the window
		busy := panel_busy(&m.pn) && m.run.verb == "connect"
		switch {
		case k == .Enter && !busy: panel_run(a, "connect")
		case ctrl && low == 'o' && m.state == "noclient": panel_run(a, "pickclient")
		case text == "?" && m.state == "signin": panel_run(a, "howto")
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	if m.focus == .Compose do return mail_key_card(a, k, ctrl, low, text, plain)
	if m.focus == .Reply {
		switch {
		case k == .Enter && shift: panel_type(&m.pn, "\n")
		case k == .Enter: mail_send_reply(a)
		case k == .Backspace: panel_bs(&m.pn)
		case ctrl && low == 'e': // the card, with the line written so far, the people and the quote
			kind := m.replyall ? "replyall" : "reply"
			typed := strings.clone(panel_text(&m.pn), context.temp_allocator)
			panel_clear(&m.pn)
			mail_card_open(m, kind, m.open)
			panel_run(a, "prefill", kind, m.open)
			if typed != "" do mail_card_prepend(m, typed)
		case ctrl && low == 'r' && shift: m.replyall = !m.replyall
		case ctrl && low == 'v': panel_type(&m.pn, msg_clipboard())
		case k == .Escape:
			if len(m.input) > 0 do panel_clear(&m.pn)
			else { m.focus = .Read; m.replyall = false }
		case k == .Up || k == .Down: m.focus = .Read
		case plain: panel_type(&m.pn, text)
		case: return false
		}
		return true
	}
	if ctrl { // the thread's actions, from the list and while reading
		id := mail_target(m)
		switch low {
		case 'e':
			if id != "" { panel_run(a, "archive", id); mail_set_undo(m, "unarchive", id); if id == m.open do m.focus = .List }
			return true
		case 's': if id != "" do panel_run(a, "star", id); return true
		case 'u':
			if id != "" { panel_run(a, "unread", id); if id == m.open do m.focus = .List }
			return true
		case 'r':
			if id == "" do return true
			if id != m.open do panel_run(a, "open", id)
			m.replyall = shift
			m.focus = .Reply
			if shift do panel_say(&m.pn, "Reply all")
			return true
		case 'f':
			if id != "" { mail_card_open(m, "forward", id); panel_run(a, "prefill", "forward", id) }
			return true
		case 'n': mail_card_open(m, "new", ""); return true
		case 'o': panel_run(a, "browser", id); return true
		case 'l':
			for i := len(m.msgs) - 1; i >= 0; i -= 1 {
				if us := msg_urls(strings.join(mail_lines(m.msgs[i].body), " ", context.temp_allocator)); len(us) > 0 { msg_open_url(a, us[len(us) - 1]); return true }
			}
			panel_say(&m.pn, "No link in this thread", a.theme.yellow)
			return true
		case 'z':
			if m.undo[0] == "" { panel_say(&m.pn, "Nothing to undo"); return true }
			panel_run(a, m.undo[0], m.undo[1])
			mail_set_undo(m, "", "")
			return true
		case 'q':
			if last := len(m.msgs) - 1; m.open != "" && last >= 0 { id := m.msgs[last].id; mail_toggle(&m.quotes, id, !m.quotes[id]) }
			return true
		case 'y': panel_run(a, "sync"); return true
		}
	}
	if k == .Delete {
		if id := mail_target(m); id != "" { panel_run(a, "trash", id); mail_set_undo(m, "untrash", id); if id == m.open do m.focus = .List }
		return true
	}
	switch m.focus {
	case .Labels:
		switch {
		case k == .Down: m.lcur = min(m.lcur + 1, max(len(m.labels) - 1, 0))
		case k == .Up: m.lcur = max(m.lcur - 1, 0)
		case k == .Enter || k == .Tab || k == .Right:
			if m.lcur < len(m.labels) && m.labels[m.lcur].id != m.label { panel_run(a, "label", m.labels[m.lcur].id); m.cur = 0 }
			m.focus = .List
		case k == .Escape: m.focus = .List
		case: return false
		}
	case .Read:
		switch {
		case k == .Down: m.scroll += 3
		case k == .Up: m.scroll = max(m.scroll - 3, 0)
		case k == .Page_Down: m.scroll += 15
		case k == .Page_Up: m.scroll = max(m.scroll - 15, 0)
		case k == .Right: if len(m.atts) > 0 do m.acur = (m.acur + 1) % len(m.atts)
		case k == .Left: if len(m.atts) > 0 do m.acur = (m.acur + len(m.atts) - 1) % len(m.atts)
		case k == .Enter:
			if m.acur < len(m.atts) { t := m.atts[m.acur]; panel_run(a, "attachment", t.msg, t.id, t.name) }
			else do panel_say(&m.pn, "Type to reply")
		case k == .Escape: m.focus = .List
		case k == .Tab: m.focus = .Reply
		case ctrl && low == 'v': m.focus = .Reply; panel_type(&m.pn, msg_clipboard())
		case plain: m.focus = .Reply; panel_type(&m.pn, text)
		case: return false
		}
	case .List, .Reply, .Compose:
		n := len(mail_list(m))
		switch {
		case k == .Down: m.cur = min(m.cur + 1, max(n - 1, 0))
		case k == .Up: m.cur = max(m.cur - 1, 0)
		case k == .Page_Down:
			m.cur = min(m.cur + 8, max(n - 1, 0))
			if m.cur == n - 1 && m.more && len(m.find) == 0 do panel_run(a, "more")
		case k == .Page_Up: m.cur = max(m.cur - 8, 0)
		case k == .Enter:
			switch {
			case n == 0 && len(m.find) > 0: mail_search_now(a)
			case n == 0 && mail_api_off(m): panel_run(a, "enableapi")
			case: mail_open_row(a)
			}
		case k == .Tab:
			if m.popup do mail_next_label(a)
			else {
				m.focus = .Labels
				for l, i in m.labels do if l.id == m.label do m.lcur = i
			}
		case k == .Right: if m.open != "" do m.focus = .Read
		case k == .Backspace: if len(m.find) > 0 { pop(&m.find); m.cur = 0; m.typed = time.tick_now() }
		case k == .Escape:
			switch {
			case len(m.find) > 0:
				clear(&m.find); m.cur = 0
				if m.query != "" do panel_run(a, "clear")
			case m.query != "": panel_run(a, "clear"); m.cur = 0
			case: panel_close(a)
			}
		case ctrl && low == 'v': append(&m.find, ..transmute([]u8)msg_clipboard()); m.cur = 0; m.typed = time.tick_now()
		case plain: append(&m.find, ..transmute([]u8)text); m.cur = 0; m.typed = time.tick_now()
		case: return false
		}
	}
	return true
}

@(private = "file")
mail_set_undo :: proc(m: ^Mail, verb, id: string) {
	delete(m.undo[0]); delete(m.undo[1])
	m.undo = {strings.clone(verb), strings.clone(id)}
}

// The popup's dropdown steps: Inbox, Starred, your labels.
@(private = "file")
mail_next_label :: proc(a: ^App) {
	m := ML(a)
	ids := make([dynamic]string, 0, 8, context.temp_allocator)
	for l in m.labels do if l.id == "ALL" || l.id == "INBOX" || strings.has_suffix(l.id, ":INBOX") || l.id == "STARRED" || (l.kind == "user" && l.account == "gmail") do append(&ids, l.id)
	if len(ids) == 0 do return
	i := 0
	for x, j in ids do if x == m.label do i = j
	panel_run(a, "label", ids[(i + 1) % len(ids)])
	m.cur = 0
}

// A reply line taken into the card goes before the quote the card gets.
@(private = "file")
mail_card_prepend :: proc(m: ^Mail, t: string) {
	body := strings.clone(string(m.card.text[3][:]), context.temp_allocator)
	clear(&m.card.text[3])
	append(&m.card.text[3], ..transmute([]u8)t)
	append(&m.card.text[3], ..transmute([]u8)body)
	delete(m.card_lead)
	m.card_lead = strings.clone(t)
}

@(private = "file")
mail_key_card :: proc(a: ^App, k: Key, ctrl: bool, low: rune, text: string, plain: bool) -> bool {
	m := ML(a)
	c := &m.card
	if panel_busy(&m.pn) && m.run.verb == "edit" { // nvim has it
		if k == .Escape do panel_say(&m.pn, "Still waiting for nvim · :wq there", a.theme.yellow)
		return true
	}
	if c.field == 4 { // From: ←→ another account, ↓ Tab To
		switch {
		case k == .Left: c.from = (c.from + len(m.froms) - 1) % max(len(m.froms), 1)
		case k == .Right || k == .Enter: c.from = (c.from + 1) % max(len(m.froms), 1)
		case k == .Down || k == .Tab: c.field = 0
		case k == .Escape: mail_card_close(m)
		case ctrl && k == .Enter: mail_card_send(a)
		}
		return true
	}
	switch {
	case ctrl && k == .Enter: mail_card_send(a)
	case ctrl && low == 'e': panel_run(a, "edit", secret = mail_card_text(m, c))
	case ctrl && low == 'a': panel_run(a, "pick")
	case ctrl && low == 'v': append(&c.text[c.field], ..transmute([]u8)msg_clipboard())
	case k == .Tab: c.field = (c.field + 1) % 4
	case k == .Back_Tab: c.field = (c.field + 3) % 4
	case k == .Escape:
		if len(c.text[2]) + len(c.text[3]) + len(c.to) > 0 do panel_run(a, "draft", c.kind, c.thread, secret = mail_card_text(m, c))
		mail_card_close(m)
	case k == .Enter:
		switch c.field {
		case 0, 1: mail_card_add(a)
		case 2: c.field = 3
		case 3: append(&c.text[3], '\n')
		}
	case k == .Backspace:
		t := &c.text[c.field]
		switch {
		case len(t) > 0: for len(t) > 0 { b := pop(t); if b & 0xc0 != 0x80 do break } // a whole character
		case c.field == 0 && len(c.to) > 0: p := pop(&c.to); delete(p[0]); delete(p[1])
		case c.field == 1 && len(c.cc) > 0: p := pop(&c.cc); delete(p[0]); delete(p[1])
		}
	case k == .Up && c.field == 0 && mail_multi(m): c.field = 4
	case k == .Up && c.field > 0 && c.field < 3: c.field -= 1
	case k == .Down && c.field < 3: c.field += 1
	case plain: append(&c.text[c.field], ..transmute([]u8)text)
	case: return false
	}
	return true
}

// Gmail searched for what the field holds (after a pause in typing, or ↵ when nothing here matches).
@(private = "file")
mail_search_now :: proc(a: ^App) {
	m := ML(a)
	q := strings.trim_space(string(m.find[:]))
	if q == "" || q == m.asked || panel_busy(&m.pn) do return
	delete(m.asked)
	m.asked = strings.clone(q)
	panel_run(a, "search", q)
}

@(private = "file")
mail_tick :: proc(a: ^App) -> int {
	m := ML(a)
	if len(m.find) == 0 || m.typed == {} do return -1
	if time.tick_since(m.typed) < MAIL_SEARCH_MS * time.Millisecond do return MAIL_SEARCH_MS / 2
	if len(strings.trim_space(string(m.find[:]))) >= 2 do mail_search_now(a)
	m.typed = {}
	return -1
}

// The runner's own lines: a card's draft, files picked, people found, a card sent.
@(private = "file")
mail_ran :: proc(a: ^App, verb, line: string) -> bool {
	m := ML(a)
	switch {
	case strings.has_prefix(line, "k4:draft\t"):
		if m.writing {
			lead := verb == "prefill" ? strings.clone(m.card_lead, context.temp_allocator) : ""
			mail_card_take(m, line[9:])
			if lead != "" do mail_card_prepend(m, lead)
		}
		return true
	case strings.has_prefix(line, "k4:attach\t"):
		f := fields(line[10:])
		if m.writing do append(&m.card.files, [2]string{strings.clone(fget(f, 0)), strings.clone(fget(f, 1))})
		return true
	case strings.has_prefix(line, "k4:who\t"):
		f := fields(line[7:])
		c := &m.card
		if m.writing && (c.field == 0 || c.field == 1) && len(c.text[c.field]) > 0 { // the first found goes in
			append(c.field == 0 ? &c.to : &c.cc, [2]string{strings.clone(fget(f, 0)), strings.clone(fget(f, 1))})
			clear(&c.text[c.field])
		}
		return true
	case line == "k4:sent":
		if m.writing do mail_card_close(m)
		return true
	}
	return false
}

@(private = "file")
mail_scroll :: proc(a: ^App, n: int) -> bool {
	m := ML(a)
	if m.focus == .Read || m.focus == .Reply || (!m.popup && m.open != "") do m.scroll = max(m.scroll - n * 3, 0)
	else do m.cur = clamp(m.cur - n, 0, max(len(mail_list(m)) - 1, 0))
	return true
}

// Hits: .Row a thread (a: its place in the list), .Item b 1 a label, b 2 a message's head (folds
// it), b 3 an attachment, b 4 a quote's button, b 5 a card's field, b 6 a card's file (removes it),
// b ≥ 10 a link in a message; .Chip a button: 0 and 1 a full card's, 2 Send, 3 the label dropdown.
@(private = "file")
mail_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := ML(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: m.cur = h.a; m.focus = .List; mail_open_row(a)
	case .Item:
		switch {
		case h.b == 1 && h.a < len(m.labels): m.lcur = h.a; panel_run(a, "label", m.labels[h.a].id); m.cur = 0; m.focus = .List
		case h.b == 2 && h.a < len(m.msgs): m.focus = .Read; mail_toggle(&m.folds, m.msgs[h.a].id, !mail_unfolded(m, h.a))
		case h.b == 3 && h.a < len(m.atts): m.acur = h.a; t := m.atts[h.a]; panel_run(a, "attachment", t.msg, t.id, t.name)
		case h.b == 4 && h.a < len(m.msgs): id := m.msgs[h.a].id; mail_toggle(&m.quotes, id, !m.quotes[id])
		case h.b == 5:
			m.focus = .Compose
			if h.a == 4 && m.card.field == 4 do m.card.from = (m.card.from + 1) % max(len(m.froms), 1)
			m.card.field = h.a
		case h.b == 6 && h.a < len(m.card.files): p := m.card.files[h.a]; delete(p[0]); delete(p[1]); ordered_remove(&m.card.files, h.a)
		case h.b >= 10 && h.a < len(m.msgs):
			us := msg_urls(strings.join(mail_lines(m.msgs[h.a].body), " ", context.temp_allocator))
			if h.b - 10 < len(us) do msg_open_url(a, us[h.b - 10])
		}
	case .Chip:
		switch h.a {
		case 0: panel_run(a, "connect")
		case 1:
			switch m.state {
			case "noclient": panel_run(a, "pickclient")
			case "signin": panel_run(a, "howto")
			case: panel_close(a)
			}
		case 2: mail_card_send(a)
		case 3: mail_next_label(a)
		case 4: panel_run(a, "enableapi")
		}
	case: return false
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
mail_size :: proc(n: int) -> string {
	switch {
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f32(n) / f32(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%d KB", n >> 10)
	}
	return fmt.tprintf("%d B", n)
}

@(private = "file")
mail_lines :: proc(s: string) -> []string { return strings.split(s, MAIL_NL, context.temp_allocator) }

@(private = "file")
mail_first_line :: proc(s: string) -> string {
	for l in mail_lines(s) do if t := strings.trim_space(l); t != "" do return t
	return ""
}

// A row's time: 08:12 today, Yesterday, Tue this week, else 26 Oct.
@(private = "file")
mail_when :: proc(ts, now: i64) -> string {
	switch now / 86400 - ts / 86400 {
	case 0: return msg_clock(ts)
	case 1: return "Yesterday"
	case 2 ..= 6: return msg_date(ts, true)[:3]
	}
	return msg_date(ts, false)
}

// A message's time: 08:12 · 24 min ago this hour, 08:12 today, Yesterday 21:40, else Wed 19:02.
@(private = "file")
mail_msg_when :: proc(ts, now: i64) -> string {
	switch now / 86400 - ts / 86400 {
	case 0:
		d := now - ts
		return d < 3600 ? fmt.tprintf("%s · %d min ago", msg_clock(ts), max(d / 60, 1)) : msg_clock(ts)
	case 1: return fmt.tprintf("Yesterday %s", msg_clock(ts))
	}
	return fmt.tprintf("%s %s", msg_date(ts, true)[:3], msg_clock(ts))
}

// A file's type as its badge (JPG, PDF, GPX…) and the badge's colour.
@(private = "file")
mail_type :: proc(a: ^App, name: string, H: HUD) -> (string, u32) {
	ext := ""
	if i := strings.last_index_byte(name, '.'); i >= 0 && len(name) - i <= 6 do ext = strings.to_upper(name[i + 1:], context.temp_allocator)
	switch ext {
	case "JPG", "JPEG", "PNG", "GIF", "WEBP", "HEIC", "SVG": return ext, a.theme.blue
	case "GPX", "KML", "CSV", "XLSX", "ODS": return ext, a.theme.green
	case "PDF": return ext, a.theme.red
	case "ZIP", "DOC", "DOCX", "ODT", "ICS": return ext, a.theme.yellow
	case "": return "FILE", H.dim
	}
	return ext, H.dim
}

@(private = "file")
mail_hints :: proc(m: ^Mail) -> [][2]string {
	h: [][2]string
	switch {
	case m.state == "noclient": h = msg_keys({"↵", "Cloud Console"}, {"^O", "Pick the file"}, {"Esc", "Close"})
	case m.state == "connect" || m.state == "signin": h = panel_busy(&m.pn) && m.run.verb == "connect" ? msg_keys({"Esc", "Close"}) : msg_keys({"↵", "Sign in"}, {"Esc", "Not now"})
	case m.focus == .Compose: h = panel_busy(&m.pn) && m.run.verb == "edit" ? msg_keys({":wq", "in nvim to come back"}, {"Esc", "Waits"}) : msg_keys({"^↵", "Send"}, {"Tab", "Next field"}, {"^E", "nvim"}, {"^A", "Attach"}, {"Esc", "Save draft"})
	case m.focus == .Reply: h = msg_keys({"↵", "Send"}, {"⇧↵", "New line"}, {"^E", "nvim"}, {"^⇧R", m.replyall ? "Reply" : "Reply all"}, {"Esc", "Thread"})
	case m.focus == .Read: h = msg_keys({"type", "Reply"}, {"↑↓ PgDn", "Scroll"}, {"↵", "Open file"}, {"^R", "Reply"}, {"^F", "Forward"}, {"^E", "Archive"}, {"^L", "Link"}, {"Esc", "List"})
	case m.focus == .Labels: h = msg_keys({"↑↓", "Label"}, {"↵ Tab", "List"})
	case: h = msg_keys({"type", "Search"}, {"↑↓", "Move"}, {"↵", "Open"}, {"^E", "Archive"}, {"Del", "Trash"}, {"^S", "Star"}, {"^N", "Compose"}, {"Tab", m.popup ? "Label" : "Labels"})
	}
	if m.popup && len(h) > 4 do h = h[:4]
	return h
}

@(private = "file")
mail_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := ML(a)
	H := panel_ground(a, cv)
	tn := msg_tones(a, H)
	w, h := cv.w, cv.h
	now := mail_now()
	reading := m.popup && (m.focus == .Read || m.focus == .Reply) && m.open != ""
	lab := mail_label(m)
	// the head: MAIL › INBOX, the account, the state
	hh, px := 40 * S, 14 * S
	crumb := "MAIL"
	switch {
	case !mail_ready(m):
	case m.writing: crumb = m.card.kind == "new" ? "MAIL › COMPOSE" : strings.concatenate({"MAIL › ", strings.to_upper(strings.fields(mail_card_title(&m.card), context.temp_allocator)[0], context.temp_allocator)}, context.temp_allocator)
	case m.query != "": crumb = "MAIL › SEARCH"
	case: crumb = strings.concatenate({"MAIL › ", strings.to_upper(lab.name, context.temp_allocator), reading ? " › THREAD" : ""}, context.temp_allocator)
	}
	cw := tw(m.f11b, crumb) + 12 * S
	fill_rect(cv, px, (hh - 20 * S) / 2, cw, 20 * S, argb(H.acc, 0xff))
	text_in(cv, m.f11b, crumb, px + 6 * S, (hh - 20 * S) / 2, 20 * S, argb(H.bg, 0xff))
	st, stc := "synced", tn.green
	if m.synced > 0 {
		d := now - m.synced
		st = d < 60 ? "synced · just now" : (d < 3600 ? fmt.tprintf("synced · %d min ago", d / 60) : fmt.tprintf("synced · %s", msg_clock(m.synced)))
	}
	switch m.state {
	case "syncing": st, stc = "syncing · first 50", H.acc
	case "noclient", "connect": st, stc = "not connected", H.dim
	case "signin": st, stc = "signed out by Google", tn.yellow
	case "offline": st, stc = fmt.tprintf("offline · %d waiting", m.waiting), tn.yellow
	case "error": st, stc = "Gmail error", tn.red
	}
	if panel_busy(&m.pn) && m.run.verb == "connect" do st, stc = "signing in", H.acc
	sw := tw(m.f10, st)
	text_in(cv, m.f10, st, w - px - sw, 0, hh, argb(stc, 0xff))
	rounded_rect(cv, w - px - sw - 12 * S, (hh - 6 * S) / 2, 6 * S, 6 * S, f32(3 * S), argb(stc, 0xff))
	acct := m.account
	switch m.state {
	case "noclient": acct = "set up · shared with Calendar"
	case "connect": acct = "Gmail"
	}
	ax := px + cw + 10 * S
	text_in(cv, m.f12, ellipsize(m.f12, acct, w - px - sw - 30 * S - ax), ax, 0, hh, argb(tn.soft, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the foot: the keys at the left, the last message at the right
	fh := 30 * S
	fy := h - fh
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	toast_w := m.toast != "" ? min(tw(m.f10, m.toast), w / 2) : 0
	kx := px
	for k in mail_hints(m) {
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
	if !mail_ready(m) { mail_draw_card(a, cv, S, H, 0, body_y, w, fy - body_y); return }
	if m.state == "error" { // Gmail said no: its reason (an API that is off: a click opens its page)
		bh := 30 * S
		fill_rect(cv, 0, body_y, w, bh, argb(tn.red, 0x10))
		fill_rect(cv, 0, body_y, 3 * S, bh, argb(tn.red, 0xff))
		fill_rect(cv, 0, body_y + bh - S, w, S, argb(tn.red, 0xff))
		text_in(cv, m.f11b, "Gmail", px, body_y, bh, argb(tn.red, 0xff))
		sx := px + tw(m.f11b, "Gmail") + 10 * S
		text_in(cv, m.f10, ellipsize(m.f10, m.note != "" ? m.note : "Gmail answered with an error · ^Y tries again", w - px - sx), sx, body_y, bh, argb(tn.soft, 0xff))
		if mail_api_off(m) do hit_add(a, 0, body_y, w, bh, .Chip, 4, 0)
		body_y += bh
	}
	if m.state == "offline" { // the banner: what shows is what was saved; what you do waits
		bh := 30 * S
		fill_rect(cv, 0, body_y, w, bh, argb(tn.yellow, 0x10))
		fill_rect(cv, 0, body_y, 3 * S, bh, argb(tn.yellow, 0xff))
		fill_rect(cv, 0, body_y + bh - S, w, S, argb(tn.yellow, 0xff))
		text_in(cv, m.f11b, "Offline", px, body_y, bh, argb(tn.yellow, 0xff))
		chip := fmt.tprintf("%d waiting", m.waiting)
		chw := tw(m.f10b, chip) + 12 * S
		rounded_rect(cv, w - px - chw, body_y + (bh - 16 * S) / 2, chw, 16 * S, 0, 0, f32(S), argb(tn.yellow, 0xff))
		text_in(cv, m.f10b, chip, w - px - chw + 6 * S, body_y, bh, argb(tn.yellow, 0xff))
		sub := m.synced > 0 ? fmt.tprintf("showing mail from %s · archive, star and replies wait and sync when the network is back", msg_clock(m.synced)) : "archive, star and replies wait and sync when the network is back"
		sx := px + tw(m.f11b, "Offline") + 10 * S
		text_in(cv, m.f10, ellipsize(m.f10, sub, w - px - chw - 10 * S - sx), sx, body_y, bh, argb(tn.soft, 0xff))
		body_y += bh
	}
	bh := fy - body_y
	if m.popup {
		switch {
		case m.writing: mail_draw_compose(a, cv, S, H, 0, body_y, w, bh)
		case reading: mail_draw_thread(a, cv, S, H, 0, body_y, w, bh, now)
		case: mail_draw_list(a, cv, S, H, 0, body_y, w, bh, now)
		}
		return
	}
	lw, lsw := MAIL_LABELS_W * S, MAIL_LIST_W * S
	mail_draw_labels(a, cv, S, H, 0, body_y, lw, bh)
	fill_rect(cv, lw, body_y, S, bh, argb(H.line, 0xff))
	mail_draw_list(a, cv, S, H, lw + S, body_y, lsw, bh, now)
	fill_rect(cv, lw + S + lsw, body_y, S, bh, argb(H.line, 0xff))
	rx := lw + 2 * S + lsw
	if m.writing do mail_draw_compose(a, cv, S, H, rx, body_y, w - rx, bh)
	else do mail_draw_thread(a, cv, S, H, rx, body_y, w - rx, bh, now)
}

// No Google client, Connect, Waiting for the browser, Sign in again: a card in the middle.
@(private = "file")
mail_draw_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	m := ML(a)
	tn := msg_tones(a, H)
	waiting := panel_busy(&m.pn) && m.run.verb == "connect"
	title := ""
	lines: [dynamic][2]string // text, "soft" | "dim"
	lines.allocator = context.temp_allocator
	steps: []string
	acts: [2][2]string
	c := H.acc
	cw := 520 * S
	switch {
	case waiting:
		title = "Waiting for the browser…"
		append(&lines, [2]string{"Finish signing in on the Google page that opened in your browser. This window carries on by itself.", "soft"})
		append(&lines, [2]string{"Nothing opened? Run k4-mail act connect in a terminal and open the page it opens by hand.", "dim"})
		acts = {{"Close", "Esc"}, {}}
	case m.state == "noclient":
		title, cw = "Mail needs a Google client first", 560 * S
		append(&lines, [2]string{"k4 talks to Gmail with your own OAuth client, the same file Calendar uses. It takes about 3 minutes, once.", "soft"})
		steps = {"Create a project and turn on the Gmail API in the Cloud Console", "Add an OAuth client of type “Desktop app” and download its JSON", "Pick the file here (^O), or leave it in Downloads · Calendar picks it up too"}
		acts = {{"Open the Cloud Console", "↵"}, {"Pick the file…", "^O"}}
	case m.state == "connect":
		title = "Connect Gmail"
		append(&lines, [2]string{"Signs in with Google in your browser. k4 asks to read, send and label mail, nothing else, and keeps the token in the keyring.", "soft"})
		append(&lines, [2]string{"Client: ~/.config/k4/google-client.json · shared with Calendar", "dim"})
		acts = {{"Sign in with Google", "↵"}, {"Not now", "Esc"}}
	case m.state == "signin":
		title, c, cw = "Sign in to Gmail again", tn.yellow, 560 * S
		append(&lines, [2]string{fmt.tprintf("Google ended the sign-in%s. Your mail on this computer is still here; new mail waits until you sign in.", m.account != "" ? fmt.tprintf(" for %s", m.account) : ""), "soft"})
		append(&lines, [2]string{"Why every 7 days? Your Google client is in “Testing”. Set it to “In production” on the OAuth consent screen and the sign-in lasts.", "dim"})
		acts = {{"Sign in again", "↵"}, {"How to set In production", "?"}}
	}
	cw = min(cw, w - 40 * S)
	iw := cw - 40 * S
	wrapped := make([dynamic][]string, 0, len(lines), context.temp_allocator)
	ch := 18 * S + 18 * S
	for l in lines { ws := wrap_text(m.f11, l[0], iw); append(&wrapped, ws); ch += 12 * S + len(ws) * 17 * S }
	steps_w := make([dynamic][]string, 0, len(steps), context.temp_allocator)
	for s in steps { ws := wrap_text(m.f11, s, iw - 28 * S); append(&steps_w, ws); ch += len(ws) * 17 * S + 7 * S }
	if len(steps) > 0 do ch += 12 * S - 7 * S
	if waiting do ch += 12 * S + 3 * S
	ch += 12 * S + 28 * S + 18 * S
	cx, cy := x + (w - cw) / 2, y + max((h - ch) / 2, 12 * S)
	fill_rect(cv, cx, cy, cw, ch, argb(c, 0x0d))
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, cx, cy, 3 * S, ch, argb(c, 0xff))
	yy := cy + 18 * S
	text_in(cv, m.f13b, ellipsize(m.f13b, title, iw), cx + 20 * S, yy, 18 * S, argb(c, 0xff))
	yy += 18 * S
	for ws, i in wrapped {
		yy += 12 * S
		col := lines[i][1] == "soft" ? tn.soft : H.dim
		for l in ws { text_in(cv, m.f11, l, cx + 20 * S, yy, 17 * S, argb(col, 0xff)); yy += 17 * S }
	}
	if len(steps) > 0 {
		yy += 12 * S - 7 * S
		for ws, i in steps_w {
			yy += 7 * S
			n := fmt.tprint(i + 1)
			text_in(cv, m.f11b, n, cx + 38 * S - tw(m.f11b, n), yy, 17 * S, argb(H.acc, 0xff))
			for l in ws { text_in(cv, m.f11, l, cx + 48 * S, yy, 17 * S, argb(tn.soft, 0xff)); yy += 17 * S }
		}
	}
	if waiting { yy += 12 * S; fill_rect(cv, cx + 20 * S, yy, iw, 3 * S, argb(H.line, 0xff)); fill_rect(cv, cx + 20 * S, yy, iw * 3 / 10, 3 * S, argb(H.acc, 0xff)); yy += 3 * S }
	yy += 12 * S
	bx := cx + 20 * S
	for b, i in acts {
		if b[0] == "" do continue
		bw := panel_btn(a, cv, S, bx, yy, 28 * S, H, b[0], b[1], i == 0 && !waiting ? .Prime : .Plain, waiting ? 1 : i)
		bx += bw + 6 * S
	}
}

@(private = "file")
mail_draw_labels :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	m := ML(a)
	tn := msg_tones(a, H)
	focused := m.focus == .Labels
	if focused do fill_rect(cv, x, y, w, h, argb(H.acc, 0x08))
	rh := 28 * S
	foot := 44 * S
	// the rows first: a section's head before each account's labels (and Gmail's own ones)
	Row :: struct { head: string, hc: u32, l: int }
	rows := make([dynamic]Row, 0, len(m.labels) + 8, context.temp_allocator)
	acct, gl := "", false
	for l, i in m.labels {
		if mail_multi(m) && l.account != acct && l.account != "all" {
			acct, gl = l.account, false
			name, col := mail_account(a, m, l.account, H)
			append(&rows, Row{head = strings.to_upper(name, context.temp_allocator), hc = col, l = -1})
		}
		if l.kind == "user" && !gl && l.account == "gmail" {
			gl = true
			append(&rows, Row{head = "LABELS", hc = H.faint, l = -1})
		}
		append(&rows, Row{l = i})
	}
	rh_of :: proc(r: Row, S: int) -> int { return r.l < 0 ? 26 * S : 28 * S }
	// scrolled so the picked one shows
	pick := 0
	for r, k in rows do if r.l >= 0 && (focused ? r.l == m.lcur : (m.labels[r.l].id == m.label && m.query == "")) do pick = k
	room := h - foot - 8 * S
	first := 0
	for {
		used := 0
		for k in first ..= pick do used += rh_of(rows[k], S)
		if used <= room || first >= pick do break
		first += 1
	}
	yy := y + 8 * S
	for k in first ..< len(rows) {
		r := rows[k]
		if yy + rh_of(r, S) > y + h - foot do break
		if r.l < 0 {
			spaced(cv, m.f9, r.head, x + 14 * S, yy + 10 * S, 12 * S, r.hc == H.faint ? H.faint : mix(H.bg, r.hc, 0.75), S)
			yy += 26 * S
			continue
		}
		i := r.l
		l := m.labels[i]
		on := focused ? i == m.lcur : (l.id == m.label && m.query == "")
		if on {
			fill_rect(cv, x, yy, w, rh, argb(H.acc, focused ? 0x1f : 0x12))
			fill_rect(cv, x, yy, 3 * S, rh, argb(H.acc, focused ? 0xff : 0x80))
			if focused do mark_sel(a, x, yy, w, rh)
		}
		hit_add(a, x, yy, w, rh, .Item, i, 1)
		g, gc := "●", mail_label_color(a, m, l.name, H)
		sys := true
		folder := l.account != "gmail" && l.account != "all"
		switch {
		case l.id == "ALL": g = "⊞"
		case l.id == "INBOX" || (folder && l.name == "Inbox"): g = "▣"
		case l.id == "STARRED": g = "★"
		case l.id == "SNOOZED": g = "◷"
		case l.id == "SENT" || (folder && l.name == "Sent"): g = "↗"
		case l.id == "DRAFT" || (folder && l.name == "Drafts"): g = "✎"
		case l.id == "SPAM" || (folder && (l.name == "Junk" || l.name == "spam")): g = "⚠"
		case l.id == "TRASH" || (folder && l.name == "Trash"): g = "⌫"
		case l.id == "IMPORTANT": g = "»"
		case folder && l.name == "Archive": g = "▤"
		case folder: g = "▭"
		case: sys = false
		}
		if sys do gc = on ? H.acc : H.dim
		text_in(cv, m.f11, g, x + 14 * S, yy, rh, argb(gc, 0xff))
		n := l.unread > 0 ? fmt.tprint(l.unread) : ""
		nw := tw(m.f10b, n)
		if n != "" do text_in(cv, m.f10b, n, x + w - 12 * S - nw, yy, rh, argb(on ? H.acc : tn.soft, 0xff))
		f := on || l.unread > 0 ? m.f12b : m.f12
		text_in(cv, f, ellipsize(f, l.name, w - 34 * S - 12 * S - nw - 6 * S), x + 34 * S, yy, rh, argb(on || l.unread > 0 ? H.fg : tn.soft, 0xff))
		yy += rh
	}
	// the account at the foot
	fy := y + h - foot
	fill_rect(cv, x, fy, w, S, argb(H.line, 0xff))
	bc := a.theme.blue
	user, _ := strings.replace_all(strings.split(m.account, "@", context.temp_allocator)[0], ".", " ", context.temp_allocator)
	ini := msg_initials(user)
	fill_rect(cv, x + 12 * S, fy + 10 * S, 24 * S, 24 * S, argb(bc, 0x22))
	rounded_rect(cv, x + 12 * S, fy + 10 * S, 24 * S, 24 * S, 0, 0, f32(S), argb(bc, 0x66))
	text_in(cv, m.f10b, ini, x + 12 * S + (24 * S - tw(m.f10b, ini)) / 2, fy + 10 * S, 24 * S, argb(bc, 0xff))
	text_in(cv, m.f10, ellipsize(m.f10, m.account, w - 56 * S), x + 44 * S, fy + 8 * S, 14 * S, argb(tn.soft, 0xff))
	text_in(cv, m.f9, "Gmail", x + 44 * S, fy + 23 * S, 13 * S, argb(H.dim, 0xff))
}

@(private = "file")
mail_draw_list :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := ML(a)
	tn := msg_tones(a, H)
	lab := mail_label(m)
	// the head: the label dropdown (the popup), the search field
	fx, fy, fh := x + 10 * S, y + 8 * S, 34 * S
	if m.popup {
		n := lab.unread > 0 ? fmt.tprint(lab.unread) : ""
		dw := tw(m.f11b, lab.name) + (n != "" ? tw(m.f11b, n) + 6 * S : 0) + tw(m.f11, "▾") + 24 * S
		fill_rect(cv, fx, fy, dw, fh, argb(H.panel, 0xff))
		rounded_rect(cv, fx, fy, dw, fh, 0, 0, f32(S), argb(H.line, 0xff))
		dx := fx + 9 * S
		text_in(cv, m.f11b, lab.name, dx, fy, fh, argb(H.fg, 0xff))
		dx += tw(m.f11b, lab.name) + 6 * S
		if n != "" { text_in(cv, m.f11b, n, dx, fy, fh, argb(H.acc, 0xff)); dx += tw(m.f11b, n) + 6 * S }
		text_in(cv, m.f11, "▾", dx, fy, fh, argb(H.dim, 0xff))
		hit_add(a, fx, fy, dw, fh, .Chip, 3, 0)
		fx += dw + 6 * S
	}
	fw := x + w - 10 * S - fx
	typing := m.focus == .List && len(m.find) > 0
	fill_rect(cv, fx, fy, fw, fh, argb(H.panel, 0xff))
	rounded_rect(cv, fx, fy, fw, fh, 0, 0, f32(S), argb(typing ? mix(H.bg, H.acc, 0.5) : H.line, 0xff))
	fill_rect(cv, fx, fy, 3 * S, fh, argb(H.acc, 0xff))
	text_in(cv, m.f13b, "›", fx + 10 * S, fy, fh, argb(H.acc, 0xff))
	q := string(m.find[:])
	qx := fx + 10 * S + tw(m.f13b, "›") + 8 * S
	if q == "" do text_in(cv, m.f12, ellipsize(m.f12, m.popup ? "Search mail…" : "Search mail · from:maja has:attachment", fx + fw - qx - 8 * S), qx, fy, fh, argb(H.faint, 0xff))
	shown := q
	for tw(m.f12, shown) > fw - (qx - fx) - 10 * S && len(shown) > 0 do shown = shown[1:]
	text_in(cv, m.f12, shown, qx, fy, fh, argb(H.fg, 0xff))
	if m.focus == .List do fill_rect(cv, qx + (q != "" ? tw(m.f12, shown) + S : 0), fy + 9 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
	// the line under it: what the list is
	l := mail_list(m)
	yy := fy + fh
	searching := strings.trim_space(q) != "" || m.query != ""
	title := searching ? "Search" : lab.name
	sub := ""
	switch {
	case m.state == "syncing": sub = "first sync · newest first"
	case searching: sub = fmt.tprintf("%d match%s%s", len(l), len(l) == 1 ? "" : "es", panel_busy(&m.pn) && m.run.verb == "search" ? " · asking Gmail…" : "")
	case len(l) > 0:
		un := lab.unread > 0 && m.label != "SENT" && m.label != "DRAFT" ? fmt.tprintf("%d unread · ", lab.unread) : ""
		sub = lab.total > len(l) ? fmt.tprintf("%s%d of %d · newest first", un, len(l), lab.total) : fmt.tprintf("%s%d · newest first", un, len(l))
	}
	text_in(cv, m.f10b, title, x + 14 * S, yy, 26 * S, argb(tn.soft, 0xff))
	text_in(cv, m.f10, ellipsize(m.f10, sub, w - 28 * S - tw(m.f10b, title) - 8 * S), x + 14 * S + tw(m.f10b, title) + 8 * S, yy, 26 * S, argb(H.dim, 0xff))
	yy += 26 * S
	bottom := y + h
	rh := 52 * S
	if m.state == "syncing" { // skeleton rows until the first 50 are in
		for i := 0; yy + rh <= bottom && i < 9; i += 1 {
			fill_rect(cv, x + 24 * S, yy + 15 * S, (w - 38 * S) * (40 + (i * 23) % 40) / 100, 9 * S, argb(H.line, 0xff))
			fill_rect(cv, x + 24 * S, yy + 30 * S, (w - 38 * S) * (60 + (i * 17) % 30) / 100, 9 * S, argb(H.panel, 0xff))
			fill_rect(cv, x, yy + rh - S, w, S, argb(H.line, 0x55))
			yy += rh
		}
		return
	}
	if len(l) == 0 {
		qq := strings.trim_space(q)
		e := searching ? fmt.tprintf("No mail matches %s · Esc clears the search", qq != "" ? qq : m.query) : fmt.tprintf("Nothing in %s", lab.name)
		ly := yy + 28 * S
		for s in wrap_text(m.f12, e, w - 36 * S) { text_in(cv, m.f12, s, x + 18 * S, ly, 18 * S, argb(H.dim, 0xff)); ly += 18 * S }
		return
	}
	first := 0
	for m.cur - first >= (bottom - yy) / rh && first < m.cur do first += 1
	for i in first ..< len(l) {
		if yy + rh > bottom do break
		mail_draw_row(a, cv, S, H, m.threads[l[i]], i, x, yy, w, now)
		yy += rh
	}
}

// A thread (KMailParts' rows): the dot, who (how many), a clip, the time, the star; the subject,
// its other labels, the snippet.
@(private = "file")
mail_draw_row :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, t: Mail_Thread, i: int, x, y, w: int, now: i64) {
	m := ML(a)
	tn := msg_tones(a, H)
	rh := 52 * S
	on := i == m.cur
	dim := m.focus != .List
	if on {
		fill_rect(cv, x, y, w, rh, dim ? argb(H.faint, 0x2e) : argb(H.acc, 0x1a))
		fill_rect(cv, x, y, 3 * S, rh, argb(dim ? H.faint : H.acc, 0xff))
		if !dim { rounded_rect(cv, x, y, w, rh, 0, 0, f32(S), argb(mix(H.bg, H.acc, 0.35), 0xff)); mark_sel(a, x, y, w, rh) }
	}
	fill_rect(cv, x, y + rh - S, w, S, argb(H.line, 0x55))
	hit_add(a, x, y, w, rh, .Row, i, 0)
	if t.unread do rounded_rect(cv, x + 8 * S, y + 22 * S, 7 * S, 7 * S, f32(S) * 3.5, argb(H.acc, 0xff))
	tx := x + 22 * S
	rx := x + w - 12 * S
	// the first line: from at the left; the clip, the time, the star at the right
	l1 := y + 9 * S
	ix := rx
	if t.starred { ix -= tw(m.f12, "★"); text_in(cv, m.f12, "★", ix, l1, 16 * S, argb(tn.yellow, 0xff)); ix -= 6 * S }
	when_ := mail_when(t.ts, now)
	tf := t.unread ? m.f10b : m.f10
	ix -= tw(tf, when_)
	text_in(cv, tf, when_, ix, l1, 16 * S, argb(t.unread ? H.acc : H.dim, 0xff))
	ix -= 6 * S
	if t.attach { ix -= tw(m.f10, "⎘"); text_in(cv, m.f10, "⎘", ix, l1, 16 * S, argb(tn.soft, 0xff)); ix -= 6 * S }
	nf := t.unread ? m.f12b : m.f12
	cnt := t.count > 1 ? fmt.tprint(t.count) : ""
	nm := ellipsize(nf, t.from, ix - tx - (cnt != "" ? tw(m.f10, cnt) + 6 * S : 0))
	text_in(cv, nf, nm, tx, l1, 16 * S, argb(t.unread ? H.fg : tn.soft, 0xff))
	if cnt != "" do text_in(cv, m.f10, cnt, tx + tw(nf, nm) + 6 * S, l1, 16 * S, argb(H.dim, 0xff))
	// the second line: the subject (70 % at most), the tags, the snippet
	l2 := y + 28 * S
	sf := t.unread ? m.f11b : m.f11
	sub := ellipsize(sf, t.subject, (rx - tx) * 7 / 10)
	text_in(cv, sf, sub, tx, l2, 15 * S, argb(t.unread ? H.fg : tn.soft, 0xff))
	lx := tx + tw(sf, sub) + 6 * S
	if m.label == "ALL" && mail_multi(m) && t.account != "" { // whose inbox it came to
		name, col := mail_account(a, m, t.account, H)
		lw := tw(m.f9b, name) + 8 * S
		if lx + lw <= rx - 30 * S {
			rounded_rect(cv, lx, l2 + S, lw, 13 * S, 0, 0, f32(S), argb(mix(H.bg, col, 0.5), 0xff))
			text_in(cv, m.f9b, name, lx + 4 * S, l2 + S, 13 * S, argb(col, 0xff))
			lx += lw + 6 * S
		}
	}
	if t.labels != "" {
		cur := mail_label(m).name
		for name in strings.split(t.labels, "|", context.temp_allocator) {
			if name == cur do continue
			c := mail_label_color(a, m, name, H)
			lw := tw(m.f9b, name) + 8 * S
			if lx + lw > rx - 30 * S do break
			rounded_rect(cv, lx, l2 + S, lw, 13 * S, 0, 0, f32(S), argb(mix(H.bg, c, 0.5), 0xff))
			text_in(cv, m.f9b, name, lx + 4 * S, l2 + S, 13 * S, argb(c, 0xff))
			lx += lw + 6 * S
		}
	}
	if lx < rx - 20 * S do text_in(cv, m.f11, ellipsize(m.f11, strings.concatenate({"— ", t.snippet}, context.temp_allocator), rx - lx), lx, l2, 15 * S, argb(H.dim, 0xff))
}

@(private = "file")
mail_draw_thread :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := ML(a)
	tn := msg_tones(a, H)
	th := a.theme
	if m.open == "" || len(m.msgs) == 0 {
		b := m.open != "" ? "Opening…" : (m.state == "syncing" ? "Mail shows here once the first 50 threads are in" : "No thread open")
		text_in(cv, m.f11, b, x + (w - tw(m.f11, b)) / 2, y + h / 2 - 10 * S, 20 * S, argb(H.faint, 0xff))
		return
	}
	pad := 18 * S
	// the head: the subject; its labels, how many messages and files, the star
	hy := y + 12 * S
	for l, i in wrap_text(m.f15b, m.subject, w - 2 * pad) {
		if i == 2 do break
		text_in(cv, m.f15b, l, x + pad, hy, 20 * S, argb(H.fg, 0xff))
		hy += 20 * S
	}
	hy += 6 * S
	lx := x + pad
	tags := make([dynamic]string, 0, 4, context.temp_allocator)
	if mail_multi(m) { // the account it is in
		for t in m.threads do if t.id == m.open && t.account != "" {
			name, col := mail_account(a, m, t.account, H)
			tw_ := tw(m.f9b, name) + 10 * S
			rounded_rect(cv, lx, hy + S, tw_, 14 * S, 0, 0, f32(S), argb(mix(H.bg, col, 0.5), 0xff))
			text_in(cv, m.f9b, name, lx + 5 * S, hy + S, 14 * S, argb(col, 0xff))
			lx += tw_ + 6 * S
			break
		}
	}
	if m.label == "INBOX" || m.label == "ALL" || strings.has_suffix(m.label, ":INBOX") do append(&tags, "Inbox")
	if m.olabels != "" do for t in strings.split(m.olabels, "|", context.temp_allocator) do append(&tags, t)
	for t in tags {
		c := t == "Inbox" ? H.dim : mail_label_color(a, m, t, H)
		tw_ := tw(m.f9b, t) + 10 * S
		rounded_rect(cv, lx, hy + S, tw_, 14 * S, 0, 0, f32(S), argb(mix(H.bg, c, 0.5), 0xff))
		text_in(cv, m.f9b, t, lx + 5 * S, hy + S, 14 * S, argb(c, 0xff))
		lx += tw_ + 6 * S
	}
	meta := fmt.tprintf("%d message%s%s", len(m.msgs), len(m.msgs) == 1 ? "" : "s", len(m.atts) > 0 ? fmt.tprintf(" · %d attachment%s", len(m.atts), len(m.atts) == 1 ? "" : "s") : "")
	text_in(cv, m.f10, meta, lx, hy, 16 * S, argb(H.dim, 0xff))
	if m.ostar do text_in(cv, m.f12, "★", lx + tw(m.f10, meta) + 6 * S, hy, 16 * S, argb(tn.yellow, 0xff))
	hy += 16 * S + 10 * S
	fill_rect(cv, x, hy, w, S, argb(H.line, 0xff))
	// the line to reply, at the bottom
	rx, rw, rh := x + 12 * S, w - 24 * S, 42 * S
	ry := y + h - rh - 10 * S
	focus := m.focus == .Reply
	sending := panel_busy(&m.pn) && m.run.verb == "send"
	alpha: u8 = sending ? 0x80 : 0xff
	fill_rect(cv, rx, ry, rw, rh, argb(H.panel, 0xff))
	rounded_rect(cv, rx, ry, rw, rh, 0, 0, f32(S), focus ? argb(mix(H.bg, H.acc, 0.6), alpha) : argb(H.line, alpha))
	fill_rect(cv, rx, ry, 3 * S, rh, argb(focus ? H.acc : H.faint, alpha))
	tag := m.replyall ? "ALL" : "RE"
	text_in(cv, m.f10b, tag, rx + 10 * S, ry, rh, argb(H.dim, alpha))
	hint := sending ? (m.state == "offline" ? "queued" : "sending…") : (focus ? "↵ send · ^E nvim" : (m.popup ? "^R" : "Reply ^R · all ^⇧R"))
	hw := tw(m.f10, hint)
	text_in(cv, m.f10, hint, rx + rw - 10 * S - hw, ry, rh, argb(sending ? H.acc : H.dim, alpha))
	ix := rx + 10 * S + tw(m.f10b, tag) + 8 * S
	q, _ := strings.replace_all(panel_text(&m.pn), "\n", " ⏎ ", context.temp_allocator)
	first := m.msgs[len(m.msgs) - 1].from
	if first == "me" do for g in m.msgs do if g.from != "me" do first = g.from
	nm := strings.fields(first, context.temp_allocator)
	ph := fmt.tprintf("%s %s…%s", m.replyall ? "Reply all to" : "Reply to", len(nm) > 0 ? strings.trim_right(nm[0], ",") : "the thread", m.popup ? "" : "   or just start typing")
	if q == "" do text_in(cv, m.f12, ellipsize(m.f12, ph, rx + rw - hw - 20 * S - ix), ix, ry, rh, argb(H.faint, alpha))
	shown := q
	for tw(m.f12, shown) > rx + rw - hw - 20 * S - ix && len(shown) > 0 do shown = shown[1:]
	text_in(cv, m.f12, shown, ix, ry, rh, argb(H.fg, alpha))
	if focus do fill_rect(cv, ix + (q != "" ? tw(m.f12, shown) + S : 0), ry + 12 * S, 2 * S, 18 * S, argb(H.acc, 0xff))
	// the messages, top down from the scroll: folded to a line, or whole
	top, bottom := hy + S + 6 * S, ry - 10 * S
	vis :: proc(y0, h, top, bottom: int) -> bool { return y0 >= top && y0 + h <= bottom }
	yy := top - m.scroll * 18 * S
	start := yy
	inner := w - 2 * pad - 40 * S
	for g, i in m.msgs {
		c := g.from == "me" ? tn.soft : note_app_color(th, g.from)
		ini := g.from == "me" ? "ME" : msg_initials(g.from)
		if !mail_unfolded(m, i) { // one line: who, the first line, when
			if vis(yy, 34 * S, top, bottom) {
				fill_rect(cv, x + pad, yy + 6 * S, 22 * S, 22 * S, argb(c, 0x1f))
				rounded_rect(cv, x + pad, yy + 6 * S, 22 * S, 22 * S, 0, 0, f32(S), argb(c, 0x80))
				text_in(cv, m.f9b, ini, x + pad + (22 * S - tw(m.f9b, ini)) / 2, yy + 6 * S, 22 * S, argb(c, 0xff))
				t := mail_msg_when(g.ts, now)
				twd := tw(m.f10, t)
				text_in(cv, m.f10, t, x + w - pad - twd, yy, 34 * S, argb(H.dim, 0xff))
				text_in(cv, m.f11b, ellipsize(m.f11b, g.from, 110 * S), x + pad + 32 * S, yy, 34 * S, argb(tn.soft, 0xff))
				sx := x + pad + 32 * S + 110 * S + 10 * S
				text_in(cv, m.f11, ellipsize(m.f11, mail_first_line(g.body), x + w - pad - twd - 10 * S - sx), sx, yy, 34 * S, argb(H.dim, 0xff))
				fill_rect(cv, x + pad, yy + 34 * S - S, w - 2 * pad, S, argb(H.line, 0x66))
				hit_add(a, x, yy, w, 34 * S, .Item, i, 2)
			}
			yy += 34 * S
			continue
		}
		yy += 12 * S
		if vis(yy, 30 * S, top, bottom) { // the avatar; from, address, time; to and cc
			fill_rect(cv, x + pad, yy, 30 * S, 30 * S, argb(c, 0x1f))
			rounded_rect(cv, x + pad, yy, 30 * S, 30 * S, 0, 0, f32(S), argb(c, 0x80))
			text_in(cv, m.f11b, ini, x + pad + (30 * S - tw(m.f11b, ini)) / 2, yy, 30 * S, argb(c, 0xff))
			hx := x + pad + 40 * S
			t := mail_msg_when(g.ts, now)
			twd := tw(m.f10, t)
			text_in(cv, m.f10, t, x + w - pad - twd, yy, 16 * S, argb(H.dim, 0xff))
			nm_ := ellipsize(m.f12b, g.from, x + w - pad - twd - 10 * S - hx)
			text_in(cv, m.f12b, nm_, hx, yy, 16 * S, argb(H.fg, 0xff))
			if g.addr != "" && g.from != "me" {
				axx := hx + tw(m.f12b, nm_) + 8 * S
				text_in(cv, m.f10, ellipsize(m.f10, fmt.tprintf("<%s>", g.addr), x + w - pad - twd - 10 * S - axx), axx, yy, 16 * S, argb(H.dim, 0xff))
			}
			to := g.cc != "" ? fmt.tprintf("to %s · cc %s", g.to, g.cc) : fmt.tprintf("to %s", g.to)
			text_in(cv, m.f10, ellipsize(m.f10, to, x + w - pad - hx), hx, yy + 17 * S, 14 * S, argb(H.dim, 0xff))
			if len(m.msgs) > 1 do hit_add(a, x, yy, w, 30 * S, .Item, i, 2)
		}
		yy += 30 * S + 10 * S
		bx := x + pad + 40 * S
		urls := msg_urls(strings.join(mail_lines(g.body), " ", context.temp_allocator))
		for para in mail_lines(g.body) {
			ls := wrap_hard(m.f12, para, inner)
			if len(ls) == 0 do ls = {""}
			for ln in ls {
				if vis(yy, 19 * S, top, bottom) do msg_draw_text_line(a, cv, S, m.f12, ln, urls, i, bx, yy, 19 * S, H.fg, H.acc)
				yy += 19 * S
			}
		}
		if g.quoted != "" { // the quote's button, and the quote under it when shown
			yy += 6 * S
			open_q := m.quotes[g.id]
			ql := mail_lines(g.quoted)
			lab := open_q ? "··· hide quoted" : fmt.tprintf("··· show quoted · %d lines", len(ql) + (g.qhead != "" ? 1 : 0))
			qw := tw(m.f10, lab) + 12 * S
			if vis(yy, 20 * S, top, bottom) {
				fill_rect(cv, bx, yy, qw, 20 * S, argb(H.panel, 0xff))
				rounded_rect(cv, bx, yy, qw, 20 * S, 0, 0, f32(S), argb(H.line, 0xff))
				text_in(cv, m.f10, lab, bx + 6 * S, yy, 20 * S, argb(H.dim, 0xff))
				hit_add(a, bx, yy, qw, 20 * S, .Item, i, 4)
			}
			yy += 20 * S
			if open_q {
				yy += 6 * S
				all := make([dynamic]string, 0, len(ql) + 1, context.temp_allocator)
				if g.qhead != "" do append(&all, g.qhead)
				for s in ql do append(&all, s)
				for para in all {
					for ln in wrap_hard(m.f11, para, inner - 12 * S) {
						if vis(yy, 17 * S, top, bottom) {
							fill_rect(cv, bx, yy, 2 * S, 17 * S, argb(H.faint, 0xff))
							text_in(cv, m.f11, ln, bx + 12 * S, yy, 17 * S, argb(H.dim, 0xff))
						}
						yy += 17 * S
					}
				}
			}
		}
		chips := false
		ax := bx
		for t, k in m.atts {
			if t.msg != g.id do continue
			// the files: a type badge, the name, the size; the picked one says ↵ open
			if !chips { yy += 10 * S; chips = true }
			ty, tc := mail_type(a, t.name, H)
			pick := k == m.acur && m.focus == .Read
			sz := mail_size(t.size)
			kw := pick ? tw(m.f10, "↵ open") + 8 * S : 0
			bw := tw(m.f9b, ty) + 6 * S
			cw := min(9 * S + bw + 8 * S + tw(m.f11, t.name) + 8 * S + tw(m.f11, sz) + kw + 9 * S, inner)
			if ax + cw > x + w - pad { ax = bx; yy += 36 * S }
			if vis(yy, 30 * S, top, bottom) {
				fill_rect(cv, ax, yy, cw, 30 * S, pick ? argb(H.acc, 0x14) : argb(H.panel, 0xff))
				rounded_rect(cv, ax, yy, cw, 30 * S, 0, 0, f32(S), argb(pick ? H.acc : H.line, 0xff))
				fill_rect(cv, ax + 9 * S, yy + 8 * S, bw, 14 * S, argb(tc, 0xff))
				text_in(cv, m.f9b, ty, ax + 12 * S, yy + 8 * S, 14 * S, argb(H.bg, 0xff))
				nx := ax + 9 * S + bw + 8 * S
				name := ellipsize(m.f11, t.name, ax + cw - nx - 9 * S - tw(m.f11, sz) - 8 * S - kw)
				text_in(cv, m.f11, name, nx, yy, 30 * S, argb(H.fg, 0xff))
				text_in(cv, m.f11, sz, nx + tw(m.f11, name) + 8 * S, yy, 30 * S, argb(H.dim, 0xff))
				if pick do text_in(cv, m.f10, "↵ open", ax + cw - 9 * S - tw(m.f10, "↵ open"), yy, 30 * S, argb(H.acc, 0xff))
				hit_add(a, ax, yy, cw, 30 * S, .Item, k, 3)
			}
			ax += cw + 6 * S
		}
		if chips do yy += 30 * S
		yy += 14 * S
	}
	total := yy - start
	m.scroll = clamp(m.scroll, 0, max((total - (bottom - top)) / (18 * S) + 1, 0))
	if m.scroll > 0 do text_in(cv, m.f10, "↑ PgUp", x + w - pad - tw(m.f10, "↑ PgUp"), top - 4 * S, 12 * S, argb(H.acc, 0xff))
}

// The card to write (KMailCompose): its title and draft state; To, Cc, Subject; the body (or
// nvim's wait); the files and Send.
@(private = "file")
mail_draw_compose :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	m := ML(a)
	tn := msg_tones(a, H)
	c := &m.card
	nvim := panel_busy(&m.pn) && m.run.verb == "edit"
	bx, by, bw, bh := x + 12 * S, y + 12 * S, w - 24 * S, h - 24 * S
	fill_rect(cv, bx, by, bw, bh, argb(H.panel, 0xff))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(nvim ? mix(H.bg, tn.green, 0.6) : mix(H.bg, H.acc, 0.5), 0xff))
	fill_rect(cv, bx, by, bw, 3 * S, argb(H.acc, 0xff))
	yy := by
	text_in(cv, m.f11b, mail_card_title(c), bx + 12 * S, yy, 34 * S, argb(H.acc, 0xff))
	saved := nvim ? "editing in nvim" : (len(c.text[2]) + len(c.text[3]) > 0 ? "Esc keeps it as a draft" : "nothing written yet")
	text_in(cv, m.f10, saved, bx + bw - 12 * S - tw(m.f10, saved), yy, 34 * S, argb(H.dim, 0xff))
	yy += 34 * S
	fill_rect(cv, bx, yy - S, bw, S, argb(H.line, 0xff))
	alpha: u8 = nvim ? 0x73 : 0xff
	if mail_multi(m) && c.from < len(m.froms) { // From: the account it goes from; ←→ another
		on := c.field == 4 && m.focus == .Compose && !nvim
		if on do fill_rect(cv, bx, yy, 3 * S, 34 * S, argb(H.acc, 0xff))
		hit_add(a, bx, yy, bw, 34 * S, .Item, 4, 5)
		text_in(cv, m.f10, "From", bx + 12 * S, yy, 34 * S, argb(H.dim, alpha))
		f := m.froms[c.from]
		name, col := mail_account(a, m, f.id, H)
		fx := bx + 12 * S + 52 * S + 10 * S
		tw_ := tw(m.f10b, name) + 10 * S
		rounded_rect(cv, fx, yy + 9 * S, tw_, 16 * S, 0, 0, f32(S), argb(mix(H.bg, col, 0.5), alpha))
		text_in(cv, m.f10b, name, fx + 5 * S, yy + 9 * S, 16 * S, argb(col, alpha))
		text_in(cv, m.f12, ellipsize(m.f12, f.addr, bx + bw - 60 * S - fx - tw_), fx + tw_ + 8 * S, yy, 34 * S, argb(H.fg, alpha))
		hint := on ? "← →" : (len(m.froms) > 1 ? "↑ changes it" : "")
		text_in(cv, m.f10, hint, bx + bw - 12 * S - tw(m.f10, hint), yy, 34 * S, argb(on ? H.acc : H.faint, alpha))
		yy += 34 * S
		fill_rect(cv, bx, yy - S, bw, S, argb(H.line, 0xff))
	}
	names := [3]string{"To", "Cc", "Subject"}
	for name, i in names { // the fields: people as chips, then what is typed
		on := c.field == i && m.focus == .Compose && !nvim
		if on do fill_rect(cv, bx, yy, 3 * S, 34 * S, argb(H.acc, 0xff))
		hit_add(a, bx, yy, bw, 34 * S, .Item, i, 5)
		text_in(cv, m.f10, name, bx + 12 * S, yy, 34 * S, argb(H.dim, alpha))
		fx := bx + 12 * S + 52 * S + 10 * S
		ps := i == 0 ? c.to[:] : (i == 1 ? c.cc[:] : nil)
		for p in ps {
			pc := note_app_color(a.theme, p[0])
			ini := strings.contains(p[0], "@") ? strings.to_upper(p[0][:1], context.temp_allocator) : msg_initials(p[0])
			pw := tw(m.f9b, ini) + 5 * S + tw(m.f11, p[0]) + 12 * S
			if fx + pw > bx + bw - 60 * S do break
			fill_rect(cv, fx, yy + 7 * S, pw, 20 * S, argb(pc, 0x14))
			rounded_rect(cv, fx, yy + 7 * S, pw, 20 * S, 0, 0, f32(S), argb(mix(H.bg, pc, 0.4), alpha))
			text_in(cv, m.f9b, ini, fx + 6 * S, yy + 7 * S, 20 * S, argb(pc, alpha))
			text_in(cv, m.f11, p[0], fx + 6 * S + tw(m.f9b, ini) + 5 * S, yy + 7 * S, 20 * S, argb(H.fg, alpha))
			fx += pw + 6 * S
		}
		t := string(c.text[i][:])
		if t == "" && len(ps) == 0 do text_in(cv, m.f12, i == 0 ? "name or address…" : (i == 1 ? "Tab skips" : "Subject"), fx, yy, 34 * S, argb(H.faint, alpha))
		text_in(cv, m.f12, ellipsize(m.f12, t, bx + bw - 12 * S - fx), fx, yy, 34 * S, argb(H.fg, alpha))
		if on do fill_rect(cv, fx + (t != "" ? tw(m.f12, t) + S : 0), yy + 9 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
		yy += 34 * S
		fill_rect(cv, bx, yy - S, bw, S, argb(H.line, 0xff))
	}
	// the bottom: the files, Send
	fh := 42 * S
	fy := by + bh - fh
	fill_rect(cv, bx, fy, bw, S, argb(H.line, 0xff))
	send_w := tw(m.f11b, "Send") + 7 * S + tw(m.f11, "^↵") + 24 * S
	sx := bx + bw - 12 * S - send_w
	if !nvim do fill_rect(cv, sx, fy + 8 * S, send_w, 26 * S, argb(H.acc, 0xff))
	rounded_rect(cv, sx, fy + 8 * S, send_w, 26 * S, 0, 0, f32(S), argb(H.acc, 0xff))
	text_in(cv, m.f11b, "Send", sx + 12 * S, fy + 8 * S, 26 * S, argb(nvim ? H.acc : H.bg, 0xff))
	text_in(cv, m.f11, "^↵", sx + 12 * S + tw(m.f11b, "Send") + 7 * S, fy + 8 * S, 26 * S, argb(nvim ? H.acc : H.bg, 0xb3))
	hit_add(a, sx, fy + 8 * S, send_w, 26 * S, .Chip, 2, 0)
	ax := bx + 12 * S
	if len(c.files) == 0 do text_in(cv, m.f10, "^A attach a file", ax, fy, fh, argb(H.dim, 0xff))
	for f, k in c.files {
		name := f[0]
		if i := strings.last_index_byte(name, '/'); i >= 0 do name = name[i + 1:]
		ty, tc := mail_type(a, name, H)
		n, _ := strconv.parse_int(f[1])
		sz := n > 0 ? mail_size(n) : ""
		tbw := tw(m.f9b, ty) + 6 * S
		cw := 8 * S + tbw + 8 * S + tw(m.f11, name) + (sz != "" ? 8 * S + tw(m.f11, sz) : 0) + 8 * S + tw(m.f11, "✕") + 8 * S
		if ax + cw > sx - 10 * S do break
		fill_rect(cv, ax, fy + 8 * S, cw, 26 * S, argb(H.bg, 0xff))
		rounded_rect(cv, ax, fy + 8 * S, cw, 26 * S, 0, 0, f32(S), argb(H.line, 0xff))
		fill_rect(cv, ax + 8 * S, fy + 14 * S, tbw, 14 * S, argb(tc, 0xff))
		text_in(cv, m.f9b, ty, ax + 11 * S, fy + 14 * S, 14 * S, argb(H.bg, 0xff))
		nx := ax + 8 * S + tbw + 8 * S
		text_in(cv, m.f11, name, nx, fy + 8 * S, 26 * S, argb(H.fg, 0xff))
		nx += tw(m.f11, name) + 8 * S
		if sz != "" { text_in(cv, m.f11, sz, nx, fy + 8 * S, 26 * S, argb(H.dim, 0xff)); nx += tw(m.f11, sz) + 8 * S }
		text_in(cv, m.f11, "✕", nx, fy + 8 * S, 26 * S, argb(H.dim, 0xff))
		hit_add(a, ax, fy + 8 * S, cw, 26 * S, .Item, k, 6)
		ax += cw + 8 * S
	}
	// the body, or the wait for nvim
	top, bottom := yy, fy
	if nvim {
		for sy := top; sy < bottom; sy += 20 * S do fill_rect(cv, bx + S, sy, bw - 2 * S, min(10 * S, bottom - sy), argb(H.bg, 0xff))
		cy := top + (bottom - top) / 2 - 40 * S
		l1 := "editing in nvim…"
		text_in(cv, m.f13b, l1, bx + (bw - tw(m.f13b, l1)) / 2, cy, 20 * S, argb(tn.green, 0xff))
		for l, i in ([]string{"A terminal opened with the draft.", "Save and quit (:wq) to come back here. :cq throws the edit away."}) do text_in(cv, m.f11, l, bx + (bw - tw(m.f11, l)) / 2, cy + 28 * S + i * 17 * S, 17 * S, argb(tn.soft, 0xff))
		l3 := "waiting for nvim"
		text_in(cv, m.f10, l3, bx + (bw - tw(m.f10, l3)) / 2, cy + 72 * S, 14 * S, argb(H.dim, 0xff))
		return
	}
	hit_add(a, bx, top, bw, bottom - top, .Item, 3, 5)
	body := string(c.text[3][:])
	ly := top + 12 * S
	lh := 19 * S
	if body == "" do text_in(cv, m.f12, "Write your mail…   ^E edits in nvim", bx + 14 * S, ly, lh, argb(H.faint, 0xff))
	all := make([dynamic]string, 0, 16, context.temp_allocator)
	for para in strings.split(body, "\n", context.temp_allocator) {
		ws := wrap_hard(m.f12, para, bw - 28 * S)
		if len(ws) == 0 do append(&all, "")
		for s in ws do append(&all, s)
	}
	if body == "" do clear(&all)
	rows := max((bottom - top - 24 * S) / lh, 1)
	editing := c.field == 3 && m.focus == .Compose
	from := editing ? max(len(all) - rows, 0) : 0 // the end shows while writing
	for i in from ..< min(len(all), from + rows) {
		text_in(cv, m.f12, all[i], bx + 14 * S, ly, lh, argb(H.fg, 0xff))
		ly += lh
	}
	if editing {
		lastw := len(all) > 0 ? tw(m.f12, all[len(all) - 1]) : 0
		cy := len(all) > 0 ? ly - lh : ly
		fill_rect(cv, bx + 14 * S + lastw + S, cy + 2 * S, 2 * S, 15 * S, argb(H.acc, 0xff))
	}
}

mail_dump :: proc(a: ^App) -> string {
	m := ML(a)
	sb := strings.builder_make(context.temp_allocator)
	lab := mail_label(m)
	fmt.sbprintfln(&sb, "mail %s · %d unread · %s%s%s", m.state, m.unread, lab.name, m.query != "" ? fmt.tprintf(" · search %s", m.query) : "", m.popup ? fmt.tprintf(" · popup %v", m.focus) : "")
	if !mail_ready(m) {
		fmt.sbprintfln(&sb, "card %s%s", m.state, panel_busy(&m.pn) && m.run.verb == "connect" ? " · waiting for the browser" : "")
		panel_dump_toast(&m.pn, &sb)
		return strings.to_string(sb)
	}
	if m.state == "offline" do fmt.sbprintfln(&sb, "banner offline · %d waiting", m.waiting)
	if m.state == "error" do fmt.sbprintfln(&sb, "banner error · %s", m.note)
	fmt.sbprintf(&sb, "labels")
	for l, i in m.labels do fmt.sbprintf(&sb, " %s%s%s", m.focus == .Labels && i == m.lcur ? "*" : "", l.name, l.unread > 0 ? fmt.tprintf("(%d)", l.unread) : "")
	fmt.sbprintln(&sb)
	if len(m.find) > 0 do fmt.sbprintfln(&sb, "find %s", string(m.find[:]))
	if m.state == "syncing" do fmt.sbprintln(&sb, "skeleton")
	l := mail_list(m)
	if len(l) == 0 && m.state != "syncing" do fmt.sbprintln(&sb, "empty")
	for ti, i in l {
		t := m.threads[ti]
		mark := i == m.cur && m.focus == .List ? "*" : " "
		fmt.sbprintfln(&sb, "%s %s%s%s%s%s · %s%s — %s", mark, t.unread ? "• " : "", t.from, t.count > 1 ? fmt.tprintf(" (%d)", t.count) : "", t.starred ? " ★" : "", t.attach ? " ⎘" : "", m.label == "ALL" && t.account != "" ? fmt.tprintf("[%s] ", t.account) : "", t.subject, t.snippet)
	}
	if m.writing {
		c := &m.card
		fmt.sbprintfln(&sb, "card %s%s · field %d", mail_card_title(c), c.thread != "" ? fmt.tprintf(" · %s", c.thread) : "", c.field)
		t, _ := strings.replace_all(strings.trim_right(mail_card_text(m, c), "\n"), "\n", " | ", context.temp_allocator)
		fmt.sbprintfln(&sb, "  %s", t)
	} else if m.open != "" {
		fmt.sbprintfln(&sb, "open %s · %s%s", m.open, m.subject, m.olabels != "" ? fmt.tprintf(" [%s]", m.olabels) : "")
		for g, i in m.msgs {
			if !mail_unfolded(m, i) { fmt.sbprintfln(&sb, "  [folded] %s: %s", g.from, mail_first_line(g.body)); continue }
			b, _ := strings.replace_all(g.body, MAIL_NL, " / ", context.temp_allocator)
			fmt.sbprintfln(&sb, "  %s%s → %s%s: %s", g.from, g.addr != "" ? fmt.tprintf(" <%s>", g.addr) : "", g.to, g.cc != "" ? fmt.tprintf(" cc %s", g.cc) : "", b)
			if g.quoted != "" {
				if m.quotes[g.id] { qq, _ := strings.replace_all(g.quoted, MAIL_NL, " / ", context.temp_allocator); fmt.sbprintfln(&sb, "    quoted: %s", qq) }
				else do fmt.sbprintfln(&sb, "    quoted (folded)%s", g.qhead != "" ? fmt.tprintf(" %s", g.qhead) : "")
			}
			for t, k in m.atts do if t.msg == g.id do fmt.sbprintfln(&sb, "    %sattachment %s · %s", k == m.acur && m.focus == .Read ? "*" : "", t.name, mail_size(t.size))
		}
	}
	if m.focus == .Reply do fmt.sbprintfln(&sb, "reply%s %s", m.replyall ? " all" : "", panel_text(&m.pn))
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
