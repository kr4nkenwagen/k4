package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --messenger: Facebook Messenger (k4-messenger, over a Matrix bridge on this machine), 900×600:
// the conversations on the left (unread first, then the latest), the picked one's messages on the
// right (yours on the right in the accent, theirs on the left, a name over each run in a group, a
// line per day) and a line to write under them. With --popup (the bar's module) 420×560, one pane
// at a time: the list, ↵ the conversation, Esc back.
// ↑↓ pick a conversation (it opens, and is read), typing writes, ↵ sends, PgUp older messages, the
// wheel scrolls them, / filters the list, ^R marks it read, Esc clears the line, then the filter,
// then closes. Before it works: Set up (↵ runs k4-messengerd setup, its steps as they come), Log in
// (paste the cookies of a messenger.com session with ^V: Tab shows them, ↵ hands them to the bridge).
// The data comes from k4-messenger (panel lines R and L, panel.odin), again every 2 s while open:
//   S <state setup|down|login|relogin|error|ok> <unread> <account> <note>
//   C <room> <name> <unread> <unix time> <sender of the last, in groups> <last line> <group 1|0> <mine 1|0>
//   O <room>                    the open one; then its messages, oldest first:
//   M <id> <unix time> <sender> <mine 1|0> <text|image|video|audio|file|emote> <text>
// The runner's verbs: open ROOM, close, more, send ROOM ($K4_INPUT), read ROOM, setup (its steps in $XDG_RUNTIME_DIR/k4-messenger-setup.log),
// login ($K4_INPUT: the cookies).

MSG_W, MSG_H :: 900, 600
MSG_PW, MSG_PH :: 420, 560
MSG_LIST_W :: 300

Msg_Room :: struct { id, name, who, last: string, unread: int, ts: i64, group, mine: bool }
Msg_Line :: struct { id, sender, kind, text: string, ts: i64, mine: bool }

Messenger :: struct {
	using pn: Panel,
	state, account, note: string,
	unread: int,
	rooms: [dynamic]Msg_Room,
	open: string,
	msgs: [dynamic]Msg_Line,
	cur: int,       // the picked conversation, in the shown list
	filter: [dynamic]u8,
	filtering: bool,
	chat: bool,     // the popup: the conversation shows (else the list)
	scroll: int,    // lines up from the newest
	steps: [dynamic]string, // setup's lines as they come
	setting_up: bool,
}

messenger_setup :: proc(a: ^App, data: string) {
	m := new(Messenger)
	m.mode = {draw = msg_draw, key = msg_key, click = msg_click, scroll = msg_scroll, loaded = msg_loaded, ran = msg_ran, tick = msg_tick, dump = msg_dump}
	panel_init(a, &m.pn, "messenger", data)
	m.refresh_ms = 2000
	a.width, a.height = m.popup ? MSG_PW : MSG_W, m.popup ? MSG_PH : MSG_H
	if m.open != "" { // opened at a conversation (a card, the launcher)
		for r, i in msg_shown(m) do if r.id == m.open do m.cur = i
		m.chat = true
	}
}

@(private = "file")
M :: proc(a: ^App) -> ^Messenger { return (^Messenger)(a.pn) }

@(private = "file")
msg_now :: proc() -> i64 {
	if v, ok := strconv.parse_i64(os.get_env("K4_MESSENGER_NOW", context.temp_allocator)); ok do return v
	return time.to_unix_seconds(time.now())
}

@(private = "file")
msg_loaded :: proc(a: ^App, data: string) {
	m := M(a)
	for &r in m.rooms { delete(r.id); delete(r.name); delete(r.who); delete(r.last) }
	clear(&m.rooms)
	for &l in m.msgs { delete(l.id); delete(l.sender); delete(l.kind); delete(l.text) }
	clear(&m.msgs)
	open := ""
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			delete(m.state); delete(m.account); delete(m.note)
			m.state, m.account, m.note = strings.clone(fget(f, 1)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4))
			m.unread, _ = strconv.parse_int(fget(f, 2))
		case "C":
			r := Msg_Room{id = strings.clone(fget(f, 1)), name = strings.clone(fget(f, 2)), who = strings.clone(fget(f, 5)), last = strings.clone(fget(f, 6)), group = fget(f, 7) == "1", mine = fget(f, 8) == "1"}
			r.unread, _ = strconv.parse_int(fget(f, 3))
			r.ts, _ = strconv.parse_i64(fget(f, 4))
			append(&m.rooms, r)
		case "O": open = fget(f, 1)
		case "M":
			l := Msg_Line{id = strings.clone(fget(f, 1)), sender = strings.clone(fget(f, 3)), mine = fget(f, 4) == "1", kind = strings.clone(fget(f, 5)), text = strings.clone(fget(f, 6))}
			l.ts, _ = strconv.parse_i64(fget(f, 2))
			append(&m.msgs, l)
		}
	}
	if open != m.open { delete(m.open); m.open = strings.clone(open) }
	if m.state != "setup" do m.setting_up = false
	m.cur = clamp(m.cur, 0, max(len(msg_shown(m)) - 1, 0))
}

// The conversations as listed: the filter's matches (the daemon orders them).
@(private = "file")
msg_shown :: proc(m: ^Messenger) -> []Msg_Room {
	q := strings.to_lower(string(m.filter[:]), context.temp_allocator)
	if q == "" do return m.rooms[:]
	out := make([dynamic]Msg_Room, 0, len(m.rooms), context.temp_allocator)
	for r in m.rooms do if strings.contains(strings.to_lower(r.name, context.temp_allocator), q) do append(&out, r)
	return out[:]
}

// The picked conversation opens: the daemon shows (and reads) it, the loader brings its messages.
@(private = "file")
msg_pick :: proc(a: ^App, i: int) {
	m := M(a)
	shown := msg_shown(m)
	if len(shown) == 0 do return
	m.cur = clamp(i, 0, len(shown) - 1)
	r := shown[m.cur]
	m.scroll = 0
	if r.id == m.open do return
	delete(m.open); m.open = strings.clone(r.id)
	for &l in m.msgs { delete(l.id); delete(l.sender); delete(l.kind); delete(l.text) }
	clear(&m.msgs) // the old one's messages go at once; the new ones come with the next load
	panel_run(a, "open", r.id)
}

@(private = "file")
msg_ready :: proc(m: ^Messenger) -> bool { return m.state == "ok" || m.state == "error" }

@(private = "file")
msg_send :: proc(a: ^App) {
	m := M(a)
	t := strings.trim_space(panel_text(&m.pn))
	if t == "" || m.open == "" do return
	text := strings.clone(panel_text(&m.pn), context.temp_allocator)
	// shown at once as sent; the next load has it for real
	append(&m.msgs, Msg_Line{id = strings.clone("…"), sender = strings.clone("you"), kind = strings.clone("text"), text = strings.clone(text), ts = msg_now(), mine = true})
	panel_clear(&m.pn)
	m.scroll = 0
	panel_run(a, "send", m.open, secret = text)
}

@(private = "file")
msg_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := M(a)
	if ctrl && (ch == 'c' || ch == 'g') { panel_close(a); return true }
	switch m.state {
	case "setup", "down": // ↵ sets up (again)
		switch {
		case k == .Enter && !m.setting_up: msg_setup(a)
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	case "login", "relogin": // the cookies go in the field
		switch {
		case k == .Enter && strings.trim_space(panel_text(&m.pn)) != "": panel_run(a, "login", secret = panel_text(&m.pn)); panel_clear(&m.pn)
		case k == .Tab: m.reveal = !m.reveal
		case k == .Backspace: panel_bs(&m.pn)
		case k == .Escape: if len(m.input) > 0 do panel_clear(&m.pn); else do panel_close(a)
		case ctrl && ch == 'v': panel_type(&m.pn, msg_clipboard())
		case text != "" && k == .None && !ctrl: panel_type(&m.pn, text)
		case: return false
		}
		return true
	}
	if m.filtering {
		switch {
		case k == .Escape: clear(&m.filter); m.filtering = false; m.cur = 0
		case k == .Enter || k == .Tab: m.filtering = false; msg_pick(a, m.cur); if m.popup do m.chat = true
		case k == .Backspace: if len(m.filter) > 0 do pop(&m.filter); else do m.filtering = false
		case k == .Down: msg_pick(a, m.cur + 1)
		case k == .Up: msg_pick(a, m.cur - 1)
		case text != "" && k == .None && !ctrl: append(&m.filter, ..transmute([]u8)text); m.cur = 0
		case: return false
		}
		return true
	}
	list_keys := !m.popup || !m.chat
	switch {
	case k == .Down && list_keys: msg_pick(a, m.cur + 1)
	case k == .Up && list_keys: msg_pick(a, m.cur - 1)
	case k == .Enter && m.popup && !m.chat: msg_pick(a, m.cur); m.chat = true
	case k == .Enter: msg_send(a)
	case k == .Page_Up: if m.open != "" { m.scroll += 10; panel_run(a, "more") }
	case k == .Page_Down: m.scroll = max(m.scroll - 10, 0)
	case ctrl && ch == 'r': if m.open != "" do panel_run(a, "read", m.open)
	case k == .Backspace: if !panel_bs(&m.pn) && m.popup && m.chat do m.chat = false
	case k == .Escape:
		switch {
		case len(m.input) > 0: panel_clear(&m.pn)
		case len(m.filter) > 0: clear(&m.filter); m.cur = 0
		case m.popup && m.chat: m.chat = false
		case: panel_close(a)
		}
	case ctrl && ch == 'v' && m.open != "": panel_type(&m.pn, msg_clipboard())
	case text == "/" && len(m.input) == 0 && list_keys: m.filtering = true
	case text != "" && k == .None && !ctrl && !alt && m.open != "": panel_type(&m.pn, text)
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

@(private = "file")
msg_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := M(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: msg_pick(a, h.a); if m.popup do m.chat = true
	case .Chip: // the notices' buttons
		switch h.a {
		case 0: if !m.setting_up do msg_setup(a)
		case 1: if strings.trim_space(panel_text(&m.pn)) != "" { panel_run(a, "login", secret = panel_text(&m.pn)); panel_clear(&m.pn) }
		}
	case: return false
	}
	return true
}

@(private = "file")
msg_ran :: proc(a: ^App, verb, line: string) -> bool { return false }

// Setup runs in the background (a minute or two: downloads, the services' first start); its
// steps ("Step 2/5 · …") come from its log, read while it runs.
@(private = "file")
msg_setup_log :: proc() -> string {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	return fmt.tprintf("%s/k4-messenger-setup.log", run != "" ? run : "/tmp")
}

@(private = "file")
msg_setup :: proc(a: ^App) {
	m := M(a)
	m.setting_up = true
	for s in m.steps do delete(s)
	clear(&m.steps)
	panel_run(a, "setup")
}

@(private = "file")
msg_tick :: proc(a: ^App) -> int {
	m := M(a)
	if !m.setting_up do return -1
	if data, err := os.read_entire_file(msg_setup_log(), context.temp_allocator); err == nil {
		for s in m.steps do delete(s)
		clear(&m.steps)
		text := string(data)
		for l in strings.split_lines_iterator(&text) do if l != "" do append(&m.steps, strings.clone(l))
	}
	if !panel_busy(&m.pn) { m.setting_up = false; panel_reload(a); return -1 }
	return 300
}

// ---------- drawing ----------

@(private = "file")
msg_day :: proc(ts, now: i64) -> string {
	d := now / 86400 - ts / 86400
	switch d {
	case 0: return "Today"
	case 1: return "Yesterday"
	}
	return clock_text_at("%a %d %b", ts)
}

@(private = "file")
clock_text_at :: proc(f: string, ts: i64) -> string {
	t := time.unix(ts, 0)
	y, mo, dd := time.date(t)
	_ = y
	if f == "%H:%M" {
		h, mi, _ := time.clock(t)
		return fmt.tprintf("%02d:%02d", h, mi)
	}
	days := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s %d %s", days[int(time.weekday(t))], dd, months[int(mo) - 1])
}

@(private = "file")
msg_ago :: proc(ts, now: i64) -> string {
	d := now - ts
	switch {
	case d < 60: return "now"
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 86400 && now / 86400 == ts / 86400: return clock_text_at("%H:%M", ts)
	case d < 2 * 86400: return "yesterday"
	case d < 7 * 86400: return fmt.tprintf("%d d", d / 86400)
	}
	return clock_text_at("%a %d %b", ts)[4:]
}

@(private = "file")
msg_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := M(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	now := msg_now()
	right := ""
	switch m.state {
	case "ok": right = m.unread > 0 ? fmt.tprintf("%d unread", m.unread) : (m.account != "" ? m.account : "")
	case "error": right = "Messenger is not answering"
	}
	title := "Messenger"
	if m.popup && m.chat do for r in m.rooms do if r.id == m.open do title = r.name
	hh, px, _ := panel_head(a, cv, S, H, "MESSENGER", title, !m.popup, tw(m.f10, right) + 8 * S)
	text_in(cv, m.f10, right, w - px - tw(m.f10, right), 0, hh, argb(m.state == "error" ? th.yellow : H.dim, 0xff))
	hints: [][2]string
	switch m.state {
	case "setup", "down": hints = {{"↵", m.state == "down" ? "Repair" : "Set up"}, {"Esc", "Close"}}
	case "login", "relogin": hints = {{"↵", "Log in"}, {"Tab", m.reveal ? "Hide" : "Show"}, {"Esc", "Close"}}
	case:
		if m.filtering do hints = {{"↑↓", "Pick"}, {"↵", "Open"}, {"Esc", "Stop filtering"}}
		else if m.popup && !m.chat do hints = {{"↑↓", "Pick"}, {"↵", "Open"}, {"/", "Filter"}, {"Esc", "Close"}}
		else if m.popup do hints = {{"↵", "Send"}, {"PgUp", "Older"}, {"Esc", "Back"}}
		else do hints = {{"↑↓", "Chat"}, {"↵", "Send"}, {"PgUp", "Older"}, {"/", "Filter"}, {"Esc", "Close"}}
	}
	fy := panel_foot(a, cv, S, H, hints, !m.popup)
	body_y := hh + S
	switch m.state {
	case "setup", "down": msg_draw_setup(a, cv, S, H, px, body_y, w - 2 * px); return
	case "login", "relogin": msg_draw_login(a, cv, S, H, px, body_y, w - 2 * px); return
	}
	if m.popup {
		if m.chat do msg_draw_chat(a, cv, S, H, 0, body_y, w, fy - body_y, now)
		else do msg_draw_list(a, cv, S, H, 0, body_y, w, fy - body_y, now)
	} else {
		lw := MSG_LIST_W * S
		msg_draw_list(a, cv, S, H, 0, body_y, lw, fy - body_y, now)
		fill_rect(cv, lw, body_y, S, fy - body_y, argb(H.line, 0xff))
		msg_draw_chat(a, cv, S, H, lw + S, body_y, w - lw - S, fy - body_y, now)
	}
}

@(private = "file")
msg_draw_list :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := M(a)
	yy := y
	if m.filtering || len(m.filter) > 0 { // the filter, as typed
		fh := 30 * S
		f := string(m.filter[:])
		text_in(cv, m.f12, "/", x + 14 * S, yy, fh, argb(H.acc, 0xff))
		if f == "" do text_in(cv, m.f12, "Filter conversations…", x + 28 * S, yy, fh, argb(H.faint, 0xff))
		else do text_in(cv, m.f12, f, x + 28 * S, yy, fh, argb(H.fg, 0xff))
		if m.filtering do fill_rect(cv, x + 28 * S + (f != "" ? tw(m.f12, f) + S : 0), yy + 7 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
		fill_rect(cv, x, yy + fh, w, S, argb(H.line, 0xff))
		yy += fh + S
	}
	shown := msg_shown(m)
	if len(shown) == 0 {
		l := len(m.rooms) == 0 ? "No conversations yet" : "No match"
		text_in(cv, m.f12, l, x + (w - tw(m.f12, l)) / 2, yy + 40 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	rh := 52 * S
	vis := max((y + h - yy) / rh, 1)
	first := clamp(m.cur - vis + 1, 0, max(len(shown) - vis, 0))
	for i in first ..< min(first + vis, len(shown)) {
		r := shown[i]
		on := i == m.cur && (!m.popup || !m.chat)
		open := r.id == m.open
		if on || (open && !m.popup) {
			fill_rect(cv, x, yy, w, rh, argb(H.acc, on ? 0x22 : 0x10))
			fill_rect(cv, x, yy, 3 * S, rh, argb(H.acc, 0xff))
			if on do mark_sel(a, x, yy, w, rh)
		}
		hit_add(a, x, yy, w, rh, .Row, i, 0)
		ix := x + 14 * S
		// the initials, in the conversation's colour
		ac := note_app_color(a.theme, r.name)
		fill_rect(cv, ix, yy + 10 * S, 32 * S, 32 * S, argb(ac, 0x22))
		rounded_rect(cv, ix, yy + 10 * S, 32 * S, 32 * S, 0, 0, f32(S), argb(ac, 0x66))
		mono := note_mono(r.name)
		text_in(cv, m.f11b, mono, ix + (32 * S - tw(m.f11b, mono)) / 2, yy + 10 * S, 32 * S, argb(ac, 0xff))
		tx := ix + 32 * S + 10 * S
		rx := x + w - 12 * S
		when_ := msg_ago(r.ts, now)
		text_in(cv, m.f10, when_, rx - tw(m.f10, when_), yy + 8 * S, 18 * S, argb(r.unread > 0 ? H.acc : H.faint, 0xff))
		nf := r.unread > 0 ? m.f12b : m.f12
		text_in(cv, nf, ellipsize(nf, r.name, rx - tw(m.f10, when_) - 10 * S - tx), tx, yy + 8 * S, 18 * S, argb(H.fg, 0xff))
		last := r.last
		if r.mine do last = strings.concatenate({"You: ", last}, context.temp_allocator)
		else if r.group && r.who != "" do last = strings.concatenate({strings.fields(r.who, context.temp_allocator)[0], ": ", last}, context.temp_allocator)
		lr := rx
		if r.unread > 0 {
			cw := count_tag_w(m.f9b, r.unread, S)
			count_tag(cv, m.f9b, rx - cw, yy + 30 * S, r.unread, S, H.acc, H.bg, H.acc)
			lr = rx - cw - 8 * S
		}
		text_in(cv, m.f11, ellipsize(m.f11, last, lr - tx), tx, yy + 28 * S, 16 * S, argb(r.unread > 0 ? H.fg : H.dim, 0xff))
		yy += rh
	}
}

@(private = "file")
msg_draw_chat :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, now: i64) {
	m := M(a)
	th := a.theme
	if m.open == "" {
		l := len(m.rooms) > 0 ? "Pick a conversation" : "Your conversations show here once Messenger has sent them"
		text_in(cv, m.f12, l, x + (w - tw(m.f12, l)) / 2, y + h / 2 - 10 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	room: Msg_Room
	for r in m.rooms do if r.id == m.open do room = r
	pad := 16 * S
	// the line to write, at the bottom
	ch := 40 * S
	cy := y + h - ch - 8 * S
	rounded_rect(cv, x + pad, cy, w - 2 * pad, ch, 0, argb(H.bg, 0xff), f32(S), argb(len(m.input) > 0 ? H.acc : H.line, 0xff))
	q := panel_text(&m.pn)
	fw := w - 2 * pad - 24 * S
	if q == "" do text_in(cv, m.f12, fmt.tprintf("Message %s…", room.name), x + pad + 16 * S, cy, ch, argb(H.faint, 0xff))
	shown := q
	for tw(m.f12, shown) > fw && len(shown) > 0 do shown = shown[1:] // the end shows while it is long
	text_in(cv, m.f12, shown, x + pad + 12 * S, cy, ch, argb(H.fg, 0xff))
	fill_rect(cv, x + pad + 12 * S + (q != "" ? tw(m.f12, shown) + S : 0), cy + 11 * S, 2 * S, 18 * S, argb(H.acc, 0xff))
	if panel_busy(&m.pn) do text_in(cv, m.f10, "sending…", x + w - pad - 12 * S - tw(m.f10, "sending…"), cy, ch, argb(H.dim, 0xff))
	// the conversation's name over the messages
	nh := 0
	if !m.popup {
		nh = 34 * S
		text_in(cv, m.f13b, ellipsize(m.f13b, room.name, w - 2 * pad), x + pad, y, nh, argb(H.fg, 0xff))
		fill_rect(cv, x, y + nh, w, S, argb(H.line, 0xff))
	}
	// the messages, newest at the bottom: laid out first (heights), then drawn from the bottom up
	top, bottom := y + nh + 8 * S, cy - 10 * S
	maxw := (w - 2 * pad) * 7 / 10 - 40 * S // (room for the time beside it)
	Item :: struct { kind: int, i: int, lines: []string, h: int } // 0 a day line, 1 a name, 2 a bubble
	items := make([dynamic]Item, 0, len(m.msgs) * 2, context.temp_allocator)
	prev_day: i64 = -1
	prev_sender := ""
	for l, i in m.msgs {
		day := l.ts / 86400
		if day != prev_day { append(&items, Item{0, i, nil, 30 * S}); prev_day = day; prev_sender = "" }
		if room.group && !l.mine && l.sender != prev_sender do append(&items, Item{1, i, nil, 18 * S})
		prev_sender = l.mine ? "" : l.sender
		t := l.text
		if l.kind == "emote" do t = strings.concatenate({"* ", l.sender, " ", t}, context.temp_allocator)
		lines := wrap_text(m.f12, t, maxw - 24 * S)
		if len(lines) == 0 do lines = {""}
		append(&items, Item{2, i, lines, len(lines) * 18 * S + 14 * S + 4 * S})
	}
	total := 0
	for it in items do total += it.h
	view := bottom - top
	m.scroll = clamp(m.scroll, 0, max((total - view) / (18 * S) + 1, 0))
	yy := bottom + m.scroll * 18 * S
	#reverse for it in items {
		yy -= it.h
		if yy + it.h < top do break
		if yy > bottom do continue
		l := m.msgs[it.i]
		switch it.kind {
		case 0:
			d := msg_day(l.ts, now)
			dw := tw(m.f10, d) + 16 * S
			fill_rect(cv, x + pad, yy + 15 * S, (w - 2 * pad - dw) / 2, S, argb(H.line, 0xff))
			fill_rect(cv, x + pad + (w - 2 * pad + dw) / 2, yy + 15 * S, (w - 2 * pad - dw) / 2, S, argb(H.line, 0xff))
			text_in(cv, m.f10, d, x + (w - tw(m.f10, d)) / 2, yy + 6 * S, 18 * S, argb(H.dim, 0xff))
		case 1:
			text_in(cv, m.f10b, l.sender, x + pad + 4 * S, yy, 18 * S, argb(note_app_color(th, l.sender), 0xff))
		case 2:
			bw := 0
			for s in it.lines do bw = max(bw, tw(m.f12, s))
			tm := clock_text_at("%H:%M", l.ts)
			bw += 24 * S
			bh := it.h - 4 * S
			bx := l.mine ? x + w - pad - bw : x + pad
			// the time beside the bubble, at its foot (inside it would sit on the text)
			text_in(cv, m.f9, tm, l.mine ? bx - 6 * S - tw(m.f9, tm) : bx + bw + 6 * S, yy + bh - 14 * S, 12 * S, argb(H.faint, 0xff))
			if l.mine do fill_rect(cv, bx, yy, bw, bh, argb(H.acc, 0xff))
			else do rounded_rect(cv, bx, yy, bw, bh, 0, argb(th.fg, 0x0c), f32(S), argb(H.line, 0xff))
			fg := l.mine ? H.bg : H.fg
			for s, k in it.lines do text_in(cv, m.f12, s, bx + 12 * S, yy + 6 * S + k * 18 * S, 18 * S, argb(fg, 0xff))
			if l.kind != "text" && l.kind != "emote" && len(it.lines) == 1 && strings.has_prefix(l.text, "[") do rounded_rect(cv, bx + 3 * S, yy + 3 * S, bw - 6 * S, bh - 6 * S, 0, 0, f32(S), argb(l.mine ? H.bg : H.dim, 0x66))
		}
	}
	if m.scroll > 0 do text_in(cv, m.f10, "↓ newer · PgDn", x + w - pad - tw(m.f10, "↓ newer · PgDn"), top, 16 * S, argb(H.acc, 0xff))
}

@(private = "file")
msg_draw_setup :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w: int) {
	m := M(a)
	th := a.theme
	yy := y + 20 * S
	if m.state == "down" {
		yy += panel_notice(a, cv, S, x, yy, w, H, "Messenger is not running", m.note != "" ? m.note : "Its services stopped. ↵ starts them again (and repairs what is missing).", th.yellow) + 14 * S
	} else {
		yy += panel_notice(a, cv, S, x, yy, w, H, "Messenger, on this machine", "k4 talks to Messenger through a Matrix server and the mautrix-meta bridge, both running here and reachable only from here. Set up downloads them (about 150 MB), starts them as your user's services and makes your account. Then you log in with the cookies of a messenger.com session. Meta may ask you to confirm the login.", H.acc) + 14 * S
	}
	if !m.setting_up do panel_btn(a, cv, S, x, yy, 30 * S, H, m.state == "down" ? "Start again" : "Set up", "↵", .Prime, 0)
	yy += 44 * S
	for s, i in m.steps {
		last := i == len(m.steps) - 1
		c := last && m.setting_up ? H.acc : (strings.has_prefix(s, "k4-messengerd:") ? th.red : H.dim)
		text_in(cv, m.f11, s, x, yy, 18 * S, argb(c, 0xff))
		yy += 20 * S
	}
	if m.setting_up do text_in(cv, m.f11, "…", x, yy, 18 * S, argb(H.acc, 0xff))
}

@(private = "file")
msg_draw_login :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w: int) {
	m := M(a)
	th := a.theme
	yy := y + 20 * S
	title := m.state == "relogin" ? "Log in to Messenger again" : "Log in to Messenger"
	body := "In a browser where you are logged in, open messenger.com, then the developer tools (F12) › Network, reload, right-click any request to messenger.com › Copy › Copy as cURL, and paste it here. Only the cookies xs, c_user and datr are used, and they go only to the bridge on this machine."
	if m.state == "relogin" && m.note != "" do body = strings.concatenate({m.note, ". ", body}, context.temp_allocator)
	yy += panel_notice(a, cv, S, x, yy, w, H, title, body, m.state == "relogin" ? th.yellow : H.acc) + 16 * S
	fh := 36 * S
	rounded_rect(cv, x, yy, w, fh, 0, argb(H.bg, 0xff), f32(S), argb(len(m.input) > 0 ? H.acc : H.line, 0xff))
	t := m.reveal ? panel_text(&m.pn) : panel_masked(&m.pn)
	if t == "" do text_in(cv, m.f12, "Paste the cURL (or the cookies)…", x + 12 * S, yy, fh, argb(H.faint, 0xff))
	t = ellipsize(m.f12, t, w - 24 * S)
	text_in(cv, m.f12, t, x + 12 * S, yy, fh, argb(H.fg, 0xff))
	fill_rect(cv, x + 12 * S + (t != "" ? tw(m.f12, t) + S : 0), yy + 9 * S, 2 * S, 18 * S, argb(H.acc, 0xff))
	yy += fh + 12 * S
	if !panel_busy(&m.pn) do panel_btn(a, cv, S, x, yy, 30 * S, H, "Log in", "↵", .Prime, 1)
	else do text_in(cv, m.f11, "Logging in…", x, yy, 30 * S, argb(H.acc, 0xff))
}

msg_dump :: proc(a: ^App) -> string {
	m := M(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "messenger %s · %d unread%s", m.state, m.unread, m.popup ? (m.chat ? " · chat" : " · list") : "")
	if m.filtering || len(m.filter) > 0 do fmt.sbprintfln(&sb, "filter %s", string(m.filter[:]))
	for r, i in msg_shown(m) do fmt.sbprintfln(&sb, "%s %s%s · %s", i == m.cur ? "*" : " ", r.name, r.unread > 0 ? fmt.tprintf(" (%d)", r.unread) : "", r.last)
	if m.open != "" do fmt.sbprintfln(&sb, "open %s", m.open)
	for l in m.msgs do fmt.sbprintfln(&sb, "  %s %s: %s", l.mine ? ">" : "<", l.sender, l.text)
	if len(m.input) > 0 do fmt.sbprintfln(&sb, "input %s", m.state == "login" || m.state == "relogin" ? panel_masked(&m.pn) : panel_text(&m.pn))
	for s in m.steps do fmt.sbprintfln(&sb, "step %s", s)
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
