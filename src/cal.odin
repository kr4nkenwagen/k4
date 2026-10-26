package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "logic"

// The calendar (a page with O cal: the bar clock's popup, 644×474): the Kestrel design's month
// grid with the day's events beside it, an agenda, event details, quick add and the calendars,
// over data a script prints (k4-cal: Google Calendar, cached):
//   CS <conn> <status>        ok | sync | offline | none | setup (no OAuth client yet), and the header's status text
//   CX <command>              actions run as `<command> VERB ARGS…` (join, open, copy, rsvp,
//                             delete, add, toggle, sync, connect, disconnect, later)
//   CC <id> <name> <tone> <account> <1|0 shown> <1|0 read-only>
//   CE <id> <cal> <YYYY-MM-DD> <HH:MM|-> <HH:MM|-> <days> <title> <where> <video> <link> <flags>
//      flags (;): own, pending (waiting to sync), org=NAME (someone else's invitation),
//      rsvp=yes|maybe|no
//   CG <event id> <name> <status>   guests;  CN <event id> <notes> (\n for new lines)
// K4_NOW=YYYY-MM-DDTHH:MM pins the clock (tests).

Cal_Cal :: struct { id, name, tone, acct: string, on, ro: bool }
Cal_Ev :: struct {
	id, cal, date, s, e: string,
	days: int,
	title, loc, meet, link, org, rsvp, notes: string,
	own, pending, all: bool,
	guests: [dynamic][2]string,
}
Cal_Data :: struct {
	conn, status, cx: string,
	cals: [dynamic]Cal_Cal,
	evs:  [dynamic]Cal_Ev,
}
Cal_View :: enum { Month, Agenda, Detail, Add, Cals }
Cal_UI :: struct {
	view, back: Cal_View,
	list: bool, // month: the day's events have the keys (else the grid)
	cur: int, // the cursor's day (days since 1970-01-01), 0 = not set yet
	ei, ai, di, ci, acal: int,
	det: int, // the event the details show
	arm: bool, // delete: asked once
	syncing, synced: bool, // a sync runs; the open's sync ran
	scroll_day, scroll_ag: int,
	rsvp: map[string]string, // replies sent, until the next load shows them
}

Cal_Hit :: enum { Tab_Month, Tab_Agenda, Prev, Next, Day, Event, Agenda, Act, Cal_Row, Connect, Not_Now }

// ---------- data ----------

cal_line :: proc(s: ^Section, f: []string) -> bool {
	get :: proc(f: []string, i: int) -> string { return i < len(f) && f[i] != "-" ? f[i] : "" }
	d := &s.cd
	switch f[0] {
	case "CS": d.conn, d.status = strings.clone(get(f, 1)), strings.clone(get(f, 2))
	case "CX": d.cx = strings.clone(get(f, 1))
	case "CC":
		append(&d.cals, Cal_Cal{strings.clone(get(f, 1)), strings.clone(get(f, 2)), strings.clone(get(f, 3)), strings.clone(get(f, 4)), get(f, 5) != "0", get(f, 6) == "1"})
	case "CE":
		e := Cal_Ev{id = strings.clone(get(f, 1)), cal = strings.clone(get(f, 2)), date = strings.clone(get(f, 3)), s = strings.clone(get(f, 4)), e = strings.clone(get(f, 5))}
		e.days, _ = strconv.parse_int(get(f, 6))
		e.days = max(e.days, 1)
		e.all = e.s == ""
		e.title, e.loc, e.meet, e.link = strings.clone(get(f, 7)), strings.clone(get(f, 8)), strings.clone(get(f, 9)), strings.clone(get(f, 10))
		for fl in strings.split(get(f, 11), ";", context.temp_allocator) {
			k, _, v := strings.partition(fl, "=")
			switch k {
			case "own": e.own = true
			case "pending": e.pending = true
			case "org": e.org = strings.clone(v)
			case "rsvp": e.rsvp = strings.clone(v)
			}
		}
		append(&d.evs, e)
	case "CG":
		for &e in d.evs do if e.id == get(f, 1) { append(&e.guests, [2]string{strings.clone(get(f, 2)), strings.clone(get(f, 3))}); break }
	case "CN":
		for &e in d.evs do if e.id == get(f, 1) { n, _ := strings.replace_all(get(f, 2), "\\n", "\n"); e.notes = strings.clone(n); break }
	case: return false
	}
	return true
}

cal_reset :: proc(s: ^Section) {
	clear(&s.cd.cals)
	clear(&s.cd.evs)
	s.cd.conn, s.cd.status = "", ""
}

@(private)
cal_by_id :: proc(d: ^Cal_Data, id: string) -> ^Cal_Cal {
	for &c in d.cals do if c.id == id do return &c
	return nil
}

// Today and the minute of the day (K4_NOW for tests).
cal_now :: proc() -> (day, mins: int) {
	if v := os.get_env("K4_NOW", context.temp_allocator); len(v) >= 16 {
		y, _ := strconv.parse_int(v[:4]); mo, _ := strconv.parse_int(v[5:7]); dd, _ := strconv.parse_int(v[8:10])
		h, _ := strconv.parse_int(v[11:13]); mi, _ := strconv.parse_int(v[14:16])
		return days_from_civil(y, mo, dd), h * 60 + mi
	}
	y, mo, dd := today()
	t := libc_now_minutes()
	return days_from_civil(y, mo, dd), t
}

@(private) hm :: proc(s: string) -> int { if len(s) < 4 do return 0; h, _ := strconv.parse_int(s[:len(s) - 3]); m, _ := strconv.parse_int(s[len(s) - 2:]); return h * 60 + m }
@(private) day_of :: proc(date: string) -> int {
	if len(date) < 10 do return 0
	y, _ := strconv.parse_int(date[:4]); mo, _ := strconv.parse_int(date[5:7]); d, _ := strconv.parse_int(date[8:10])
	return days_from_civil(y, mo, d)
}
MON3 := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
DOW3 := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
@(private) short_day :: proc(day: int) -> string { _, mo, d := civil_from_days(day); return fmt.tprintf("%s %d %s", DOW3[weekday(day)], d, MON3[mo - 1]) }
@(private) long_day :: proc(day: int) -> string { _, mo, d := civil_from_days(day); return fmt.tprintf("%s %d %s", DAYS[weekday(day)], d, MONTHS[mo - 1]) }

Cal_Occ :: struct { ev: int, part: string }

// The events on a day, shown calendars only: all-day first, then by start.
cal_day :: proc(d: ^Cal_Data, day: int) -> []Cal_Occ {
	out := make([dynamic]Cal_Occ, 0, 8, context.temp_allocator)
	if !cal_connected(d) do return out[:]
	for e, i in d.evs {
		c := cal_by_id(d, e.cal)
		if c != nil && !c.on do continue
		d0 := day_of(e.date)
		if day < d0 || day >= d0 + e.days do continue
		append(&out, Cal_Occ{i, e.days > 1 ? fmt.tprintf("day %d of %d", day - d0 + 1, e.days) : ""})
	}
	key :: proc(d: ^Cal_Data, o: Cal_Occ) -> int { e := d.evs[o.ev]; return e.all ? -1 : hm(e.s) }
	for i in 1 ..< len(out) { // insertion sort: a handful per day
		j := i
		for j > 0 && key(d, out[j - 1]) > key(d, out[j]) { out[j - 1], out[j] = out[j], out[j - 1]; j -= 1 }
	}
	return out[:]
}

@(private)
cal_past :: proc(e: Cal_Ev, day: int) -> bool {
	now_day, now_m := cal_now()
	if e.all do return false
	if day == now_day do return hm(e.e) <= now_m
	return day < now_day
}

@(private)
cal_meta :: proc(d: ^Cal_Data, o: Cal_Occ) -> string {
	e := d.evs[o.ev]
	bits := make([dynamic]string, 0, 4, context.temp_allocator)
	if o.part != "" do append(&bits, o.part)
	if e.loc != "" do append(&bits, e.loc)
	if e.meet != "" do append(&bits, "Google Meet")
	if e.pending do append(&bits, "waiting to sync")
	if len(bits) == 0 { if c := cal_by_id(d, e.cal); c != nil do append(&bits, c.name) }
	return strings.join(bits[:], " · ", context.temp_allocator)
}
@(private) cal_time :: proc(e: Cal_Ev) -> string { return e.all ? "all day" : fmt.tprintf("%s–%s", e.s, e.e) }

@(private)
cal_tone :: proc(t: logic.Theme, d: ^Cal_Data, cal: string) -> u32 {
	c := cal_by_id(d, cal)
	return c != nil ? token(t, c.tone, t.fg_dim) : t.fg_dim
}

// The agenda: 14 days from the cursor, days with something on (and today).
Cal_Ag :: struct { head: bool, day: int, occ: Cal_Occ, empty: bool }
cal_agenda :: proc(d: ^Cal_Data, from: int) -> (rows: []Cal_Ag, evs: []Cal_Ag) {
	r := make([dynamic]Cal_Ag, 0, 32, context.temp_allocator)
	e := make([dynamic]Cal_Ag, 0, 32, context.temp_allocator)
	now_day, _ := cal_now()
	for i in 0 ..< 14 {
		day := from + i
		l := cal_day(d, day)
		if len(l) == 0 && day != now_day && i > 0 do continue
		append(&r, Cal_Ag{head = true, day = day, empty = len(l) == 0})
		for o in l { append(&r, Cal_Ag{day = day, occ = o}); append(&e, Cal_Ag{day = day, occ = o}) }
	}
	return r[:], e[:]
}

// The detail view's actions.
Cal_Act :: enum { Rsvp, Join, Open, Copy, Delete }
cal_acts :: proc(m: ^Menu, d: ^Cal_Data, e: Cal_Ev) -> []Cal_Act {
	out := make([dynamic]Cal_Act, 0, 5, context.temp_allocator)
	if len(e.guests) > 0 && e.org != "" do append(&out, Cal_Act.Rsvp)
	if e.meet != "" do append(&out, Cal_Act.Join)
	if e.link != "" do append(&out, Cal_Act.Open)
	if e.meet != "" do append(&out, Cal_Act.Copy)
	if c := cal_by_id(d, e.cal); c == nil || !c.ro do append(&out, Cal_Act.Delete)
	return out[:]
}
@(private)
cal_rsvp_now :: proc(m: ^Menu, e: Cal_Ev) -> string {
	if v, ok := m.calu.rsvp[e.id]; ok do return v
	switch e.rsvp { case "maybe": return "Maybe"; case "no": return "No" }
	return "Yes"
}

// ---------- quick add: "Lunch with Elin fri 12" -> title, day, time ----------

Cal_Quick :: struct { title: string, day: int, time: string }
cal_quick :: proc(s: string, cur: int) -> Cal_Quick {
	q := Cal_Quick{day = cur}
	now_day, _ := cal_now()
	words := strings.fields(s, context.temp_allocator)
	keep := make([dynamic]string, 0, len(words), context.temp_allocator)
	date_done, time_done := false, false
	for wi := 0; wi < len(words); wi += 1 {
		w := strings.to_lower(words[wi], context.temp_allocator)
		if !date_done {
			off := -1
			switch w {
			case "today": off = 0
			case "tomorrow", "tmrw": off = 1
			case:
				names := [7][]string{{"mon", "monday"}, {"tue", "tues", "tuesday"}, {"wed", "wednesday"}, {"thu", "thur", "thurs", "thursday"}, {"fri", "friday"}, {"sat", "saturday"}, {"sun", "sunday"}}
				for ns, wd in names do for n in ns do if w == n do off = (wd - weekday(now_day) + 7) % 7
			}
			if off >= 0 { q.day, date_done = now_day + off, true; continue }
		}
		if !time_done {
			t := w
			if (t == "at" || t == "kl" || t == "kl.") && wi + 1 < len(words) do t = strings.to_lower(words[wi + 1], context.temp_allocator)
			pm := strings.has_suffix(t, "pm")
			am := strings.has_suffix(t, "am")
			if pm || am do t = t[:len(t) - 2]
			if wi + 1 < len(words) && !pm && !am {
				nx := strings.to_lower(words[wi + 1], context.temp_allocator)
				if t != w do nx = wi + 2 < len(words) ? strings.to_lower(words[wi + 2], context.temp_allocator) : ""
				if nx == "pm" do pm = true
				if nx == "am" do am = true
			}
			hs, _, ms := strings.partition(strings.trim_prefix(t, "kl"), ":")
			if !strings.contains(t, ":") do hs, _, ms = strings.partition(t, ".")
			h, okh := strconv.parse_int(hs)
			mi, okm := strconv.parse_int(ms)
			if ms == "" do mi, okm = 0, true
			if okh && okm && len(hs) <= 2 && len(ms) != 1 && h <= 23 && mi <= 59 && (h > 0 || len(hs) > 0) {
				if pm && h < 12 do h += 12
				q.time, time_done = fmt.tprintf("%02d:%02d", h, mi), true
				if t != w do wi += 1 // "at 12"
				if wi + 1 < len(words) && (strings.to_lower(words[wi + 1], context.temp_allocator) == "pm" || strings.to_lower(words[wi + 1], context.temp_allocator) == "am") do wi += 1
				continue
			}
		}
		append(&keep, words[wi])
	}
	title := strings.join(keep[:], " ", context.temp_allocator)
	if title != "" {
		r, n := utf8.decode_rune_in_string(title)
		up := strings.to_upper(utf8.runes_to_string({r}, context.temp_allocator), context.temp_allocator)
		title = strings.concatenate({up, title[n:]}, context.temp_allocator)
	}
	q.title = title
	return q
}
@(private) quick_end :: proc(t: string) -> string { h := min(23, hm(t) / 60 + 1); return fmt.tprintf("%02d:%s", h, t[3:]) }

// ---------- actions ----------

// A calendar action: `<CX> VERB ARGS…` in the runner (its last line is the footer's message);
// the page loads again after it.
cal_run :: proc(a: ^App, toast: string, args: ..string) {
	m := a.menu
	d := &m.sections[m.open].cd
	if d.cx == "" { m.toast = "No calendar command (CX)"; return }
	if m.runner.state == .Loading { m.toast = "Still running the last action…"; return }
	parts := make([dynamic]string, 0, len(args) + 1, context.temp_allocator)
	append(&parts, d.cx)
	for x in args do append(&parts, sh_quote(x))
	m.runner = Loader{cmd = strings.join(parts[:], " "), state = .Lazy}
	saved := m.loading
	m.loading = 0
	loader_start(m, &m.runner)
	m.loading = saved + (m.runner.state == .Loading ? 1 : 0)
	m.calu.syncing = len(args) > 0 && args[0] == "sync"
	m.toast = toast
}

@(private)
cal_join :: proc(a: ^App, e: ^Cal_Ev) {
	m := a.menu
	d := &m.sections[m.open].cd
	ev := e
	if ev == nil {
		now_day, now_m := cal_now()
		for o in cal_day(d, now_day) {
			x := &d.evs[o.ev]
			if x.meet != "" && !x.all && hm(x.e) > now_m { ev = x; break }
		}
	}
	if ev == nil || ev.meet == "" { m.toast = "No video call coming up today"; return }
	cal_run(a, "Opening the call…", "join", ev.meet)
}

@(private)
cal_detail :: proc(m: ^Menu, ev: int, from: Cal_View) {
	m.calu.view, m.calu.det, m.calu.di, m.calu.back, m.calu.arm = .Detail, ev, 0, from, false
	m.toast = ""
}

@(private)
cal_act :: proc(a: ^App, act: Cal_Act, step := 1) {
	m := a.menu
	d := &m.sections[m.open].cd
	if m.calu.det < 0 || m.calu.det >= len(d.evs) do return
	e := &d.evs[m.calu.det]
	switch act {
	case .Rsvp:
		o := [3]string{"Yes", "Maybe", "No"}
		cur := 0
		for x, i in o do if x == cal_rsvp_now(m, e^) do cur = i
		n := o[(cur + step + 3) % 3]
		m.calu.rsvp[strings.clone(e.id)] = n
		cal_run(a, fmt.tprintf("Replying  %s…", n), "rsvp", e.id, strings.to_lower(n, context.temp_allocator), e.org)
	case .Join: cal_join(a, e)
	case .Open: cal_run(a, "Opening Google Calendar…", "open", e.link)
	case .Copy: cal_run(a, "", "copy", e.meet)
	case .Delete:
		if !m.calu.arm { m.calu.arm = true; return }
		m.calu.arm = false
		m.calu.view = m.calu.back
		cal_run(a, fmt.tprintf("Deleting  %s…", e.title), "delete", e.id, e.title)
	}
}

@(private)
cal_create :: proc(a: ^App) {
	m := a.menu
	d := &m.sections[m.open].cd
	q := cal_quick(string(a.query[:]), m.calu.cur)
	if q.title == "" { m.toast = "Type what the event is first"; return }
	cals := cal_writable(d)
	if len(cals) == 0 { m.toast = "No calendar to add to"; return }
	c := cals[clamp(m.calu.acal, 0, len(cals) - 1)]
	y, mo, dd := civil_from_days(q.day)
	m.calu.view, m.calu.cur, m.calu.list = .Month, q.day, false
	clear_query(a)
	cal_run(a, fmt.tprintf("Creating  %s…", q.title), "add", c.id, fmt.tprintf("%04d-%02d-%02d", y, mo, dd), q.time, q.title)
}

@(private)
cal_writable :: proc(d: ^Cal_Data) -> []Cal_Cal {
	out := make([dynamic]Cal_Cal, 0, len(d.cals), context.temp_allocator)
	for c in d.cals do if !c.ro do append(&out, c)
	return out[:]
}

// The month's first shown day and its weeks (at least four, while a week starts in the month).
@(private)
month_weeks :: proc(day: int) -> (first, n: int) {
	y, mo, _ := civil_from_days(day)
	d1 := days_from_civil(y, mo, 1)
	first = d1 - weekday(d1)
	n = 4
	for n < 6 {
		_, m2, _ := civil_from_days(first + n * 7)
		if m2 != mo do break
		n += 1
	}
	return
}
@(private)
shift_month :: proc(day, n: int) -> int {
	y, mo, d := civil_from_days(day)
	mo += n
	for mo < 1 { mo += 12; y -= 1 }
	for mo > 12 { mo -= 12; y += 1 }
	return days_from_civil(y, mo, min(d, days_in_month(y, mo)))
}

cal_open :: proc(a: ^App) {
	m := a.menu
	if m.calu.cur == 0 do m.calu.cur, _ = cal_now()
	if m.calu.rsvp == nil do m.calu.rsvp = make(map[string]string)
}

// The page's data arrived: sync once per open when connected.
cal_loaded :: proc(a: ^App, s: ^Section) {
	m := a.menu
	cal_open(a)
	if !m.calu.synced && cal_connected(&s.cd) && s.cd.cx != "" && m.runner.state != .Loading && os.get_env("K4_CAL_NOSYNC", context.temp_allocator) == "" {
		m.calu.synced = true
		cal_run(a, "", "sync")
	}
}

@(private)
cal_back :: proc(a: ^App) -> bool { // false: nothing to go back to
	m := a.menu
	u := &m.calu
	switch {
	case u.view == .Month && u.list: u.list = false
	case u.view == .Detail || u.view == .Cals || u.view == .Add:
		u.view, u.arm = u.back, false
		clear_query(a)
	case: return false
	}
	m.toast = ""
	return true
}

cal_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	m := a.menu
	s := &m.sections[m.open]
	d := &s.cd
	u := &m.calu
	cal_open(a)
	connected := cal_connected(d)
	close :: proc(a: ^App) {
		m := a.menu
		if at_entry(m) { a.exit = 1; a.done = true } else do menu_back(a)
	}
	if u.view == .Add {
		switch {
		case k == .Enter: cal_create(a)
		case k == .Escape: cal_back(a)
		case k == .Tab: u.acal = (u.acal + 1) % max(len(cal_writable(d)), 1)
		case k == .Backspace && len(a.query) == 0: cal_back(a)
		case: return app_edit_key(a, k, ctrl, ch, text)
		}
		return true
	}
	if k == .Escape { if !cal_back(a) do close(a); return true }
	if k == .Backspace { if !cal_back(a) && !at_entry(m) do menu_back(a); return true }
	if !connected && k == .Enter && (u.view == .Month || u.view == .Agenda) { cal_run(a, a.menu.sections[a.menu.open].cd.conn == "setup" ? "Looking for the OAuth client…" : "Opening the Google sign-in…", "connect"); return true }
	if u.view == .Month || u.view == .Agenda {
		switch {
		case k == .Tab: u.view, u.list = u.view == .Month ? .Agenda : .Month, false; m.toast = ""; return true
		case text == "n" && connected: u.back, u.view, u.acal = u.view, .Add, 0; clear_query(a); m.toast = ""; return true
		case text == "c" && connected: u.back, u.view, u.ci = u.view, .Cals, 0; m.toast = ""; return true
		case text == "t": u.cur, _ = cal_now(); u.list, u.ei, u.ai = false, 0, 0; m.toast = ""; return true
		case text == "j": cal_join(a, nil); return true
		case k == .Page_Up || k == .Page_Down: u.cur = shift_month(u.cur, k == .Page_Up ? -1 : 1); u.ei = 0; m.toast = ""; return true
		}
	}
	switch u.view {
	case .Month:
		dl := cal_day(d, u.cur)
		if !u.list {
			mv := 0
			#partial switch k { case .Left: mv = -1; case .Right: mv = 1; case .Up: mv = -7; case .Down: mv = 7 }
			if mv != 0 { u.cur += mv; u.ei = 0; m.toast = ""; return true }
			if k == .Enter && len(dl) > 0 {
				u.list, u.ei = true, 0
				for o, i in dl do if !cal_past(d.evs[o.ev], u.cur) { u.ei = i; break }
				m.toast = ""
			}
		} else {
			#partial switch k {
			case .Down, .Up: u.ei = clamp(u.ei + (k == .Down ? 1 : -1), 0, max(len(dl) - 1, 0))
			case .Left: u.list = false
			case .Enter: if u.ei < len(dl) do cal_detail(m, dl[u.ei].ev, .Month)
			}
		}
	case .Agenda:
		_, evs := cal_agenda(d, u.cur)
		#partial switch k {
		case .Down, .Up: u.ai = clamp(u.ai + (k == .Down ? 1 : -1), 0, max(len(evs) - 1, 0))
		case .Enter: if u.ai < len(evs) do cal_detail(m, evs[u.ai].occ.ev, .Agenda)
		}
	case .Detail:
		if u.det < 0 || u.det >= len(d.evs) { u.view = u.back; return true }
		e := &d.evs[u.det]
		acts := cal_acts(m, d, e^)
		switch {
		case k == .Down || k == .Up: u.di = clamp(u.di + (k == .Down ? 1 : -1), 0, max(len(acts) - 1, 0)); u.arm = false
		case (k == .Left || k == .Right) && u.di < len(acts) && acts[u.di] == .Rsvp: cal_act(a, .Rsvp, k == .Left ? -1 : 1)
		case k == .Enter && u.di < len(acts): cal_act(a, acts[u.di])
		case text == "j" && e.meet != "": cal_join(a, e)
		case text == "o" && e.link != "": cal_act(a, .Open)
		}
	case .Cals:
		n := len(d.cals) + 2
		switch {
		case k == .Down || k == .Up: u.ci = clamp(u.ci + (k == .Down ? 1 : -1), 0, n - 1)
		case k == .Enter || text == " ": cal_cal_row(a, u.ci)
		case text == "s": cal_run(a, "Syncing…", "sync")
		}
	case .Add:
	}
	return true
}

@(private)
cal_cal_row :: proc(a: ^App, i: int) {
	m := a.menu
	d := &m.sections[m.open].cd
	switch {
	case i < len(d.cals):
		c := &d.cals[i]
		c.on = !c.on // at once; the script keeps it
		cal_run(a, "", "toggle", c.id, c.name, c.on ? "on" : "off")
	case i == len(d.cals): cal_run(a, "Syncing…", "sync")
	case: m.toast = "Disconnect asks first in Setup"
	}
}

// ---------- drawing ----------

cal_hints :: proc(m: ^Menu, d: ^Cal_Data) -> [][2]string {
	u := &m.calu
	connected := cal_connected(d)
	h: [][2]string
	switch {
	case !connected && (u.view == .Month || u.view == .Agenda): h = {{"↵", d.conn == "setup" ? "Set up Google" : "Connect Google"}, {"←→↑↓", "Day"}, {"Esc", "Close"}}
	case u.view == .Month && !u.list: h = {{"←→↑↓", "Day"}, {"↵", "Events"}, {"PgUp/Dn", "Month"}, {"Tab", "Agenda"}, {"n", "New"}, {"t", "Today"}}
	case u.view == .Month: h = {{"↑↓", "Event"}, {"↵", "Details"}, {"j", "Join"}, {"←", "Days"}, {"n", "New"}}
	case u.view == .Agenda: h = {{"↑↓", "Event"}, {"↵", "Details"}, {"j", "Join"}, {"Tab", "Month"}, {"c", "Calendars"}}
	case u.view == .Detail: h = {{"↑↓", "Move"}, {"← →", "Reply"}, {"↵", "Run"}, {"j", "Join"}, {"o", "Google"}, {"Esc", "Back"}}
	case u.view == .Add: h = {{"↵", "Create"}, {"Tab", "Calendar"}, {"Esc", "Cancel"}}
	case: h = {{"↑↓", "Move"}, {"␣", "Show / hide"}, {"s", "Sync"}, {"Esc", "Back"}}
	}
	out := make([][2]string, len(h), context.temp_allocator)
	copy(out, h)
	return out
}

@(private)
// Signed in to Google ("none": not yet; "setup": not yet, and no OAuth client to sign in with).
cal_connected :: proc(d: ^Cal_Data) -> bool { return d.conn != "none" && d.conn != "setup" && d.conn != "" }

chit :: proc(a: ^App, x, y, w, h: int, what: Cal_Hit, i: int) { hit_add(a, x, y, w, h, .Cal, int(what), i) }

draw_calendar :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := a.menu
	t := a.theme
	s := &m.sections[m.open]
	d := &s.cd
	u := &m.calu
	cal_open(a)
	bg, fg, dim, acc := t.bg, t.fg, t.fg_dim, t.accent
	sel := t.selection
	B := 2 * S
	canvas_clear(cv)
	fill_rect(cv, 0, 0, cv.w, cv.h, argb(bg, a.bg_alpha))
	frame(cv, 0, 0, cv.w, cv.h, S, argb(mix(t.bg, acc, 0.17), 0xff), argb(acc, 0xff))
	x0, x1 := B, cv.w - B
	y := B
	connected := cal_connected(d)
	f14b := msize(a, 14, true, S)
	f17b := msize(a, 17, true, S)
	f10 := msize(a, 10, false, S)

	// header: CALENDAR · Month Agenda (or › Event …) · status
	hh := 40 * S
	chip := "CALENDAR"
	cw := tw(m.f_bold11, chip) + 12 * S
	chh := int(m.f_bold11.line_h) + 6 * S
	cx := x0 + 12 * S
	fill_rect(cv, cx, y + (hh - chh) / 2, cw, chh, argb(acc, 0xff))
	text_in(cv, m.f_bold11, chip, cx + 6 * S, y + (hh - chh) / 2, chh, argb(bg, 0xff))
	hx := cx + cw + 12 * S
	if u.view == .Month || u.view == .Agenda {
		for name, i in ([2]string{"Month", "Agenda"}) {
			on := (i == 0) == (u.view == .Month)
			f := on ? m.f_bold12 : m.f_small
			w := tw(f, name) + 8 * S
			text_in(cv, f, name, hx + 4 * S, y, hh, argb(on ? fg : dim, 0xff))
			if on do fill_rect(cv, hx, y + hh - 3 * S, w, 2 * S, argb(acc, 0xff))
			chit(a, hx, y, w, hh, i == 0 ? .Tab_Month : .Tab_Agenda, 0)
			hx += w + 12 * S
		}
	} else {
		crumb := u.view == .Detail ? "› Event" : (u.view == .Add ? "› New event" : "› Calendars")
		text_in(cv, m.f_bold13, crumb, hx, y, hh, argb(fg, 0xff))
	}
	status, sc := d.status, dim
	switch {
	case u.syncing && m.runner.state == .Loading: status, sc = "↻ syncing…", acc
	case d.conn == "offline": sc = t.yellow
	case d.conn == "sync": sc = acc
	case d.conn == "setup": status = "not set up"
	case d.conn == "none" || d.conn == "": status = "not connected"
	}
	text_in(cv, m.f_tiny, status, x1 - 12 * S - tw(m.f_tiny, status), y, hh, argb(sc, 0xff))
	y += hh
	fill_rect(cv, x0, y, x1 - x0, S, argb(sel, 0xff))
	y += S

	// footer: hints, or the last action's message
	fh := 30 * S
	fy := cv.h - B - fh
	fill_rect(cv, x0, fy, x1 - x0, S, argb(sel, 0xff))
	if m.toast != "" {
		text_in(cv, m.f_tiny, m.toast, x0 + 12 * S, fy, fh, argb(acc, 0xff), x1 - 12 * S)
	} else {
		kx := x0 + 12 * S
		for h in cal_hints(m, d) {
			w := tw(f10, h[0]) + 10 * S
			if kx + w > x1 - 12 * S do break
			kh := int(f10.line_h) + 2 * S
			fill_rect(cv, kx, fy + (fh - kh) / 2, w, kh, argb(sel, 0xff))
			text_in(cv, f10, h[0], kx + 5 * S, fy + (fh - kh) / 2, kh, argb(fg, 0xff))
			kx += w + 5 * S
			text_in(cv, m.f_tiny, h[1], kx, fy, fh, argb(dim, 0xff), x1 - 12 * S)
			kx += tw(m.f_tiny, h[1]) + 14 * S
		}
	}
	body := [4]int{x0, y, x1 - x0, fy - y}
	switch u.view {
	case .Month: cal_draw_month(a, cv, S, body)
	case .Agenda: cal_draw_agenda(a, cv, S, body)
	case .Detail: cal_draw_detail(a, cv, S, body, f17b)
	case .Add: cal_draw_add(a, cv, S, body)
	case .Cals: cal_draw_cals(a, cv, S, body)
	}
	_ = f14b
}

@(private)
cal_event_row :: proc(a: ^App, cv: ^Canvas, S: int, d: ^Cal_Data, o: Cal_Occ, day, x, y, w, h: int, on: bool, time_w: int, two_line: bool) {
	m := a.menu
	t := a.theme
	e := d.evs[o.ev]
	past := cal_past(e, day)
	fg := on ? t.bg : (past ? t.fg_dim : t.fg)
	dc := on ? t.bg : t.fg_dim
	if on { fill_rect(cv, x, y, w, h, argb(t.accent, 0xff)); mark_sel(a, x, y, w, h) }
	px := x + (two_line ? 14 : 16) * S
	right := x + w - (two_line ? 14 : 16) * S
	ty := two_line ? y + 6 * S : y
	th := two_line ? int(m.f_body.line_h) : h
	text_in(cv, m.f_tiny, cal_time(e), px, ty, th, argb(dc, 0xff))
	px += time_w * S + 10 * S
	fill_rect(cv, px, ty + (th - 8 * S) / 2, 8 * S, 8 * S, argb(on ? t.bg : cal_tone(t, d, e.cal), 0xff))
	px += 8 * S + 10 * S
	if e.meet != "" && !past {
		jw := tw(msize(a, 10, true, S), "JOIN") + 10 * S
		jh := 16 * S
		rounded_rect(cv, right - jw, ty + (th - jh) / 2, jw, jh, 0, 0, f32(S), argb(on ? t.bg : t.accent, 0xff))
		text_in(cv, msize(a, 10, true, S), "JOIN", right - jw + 5 * S, ty + (th - jh) / 2, jh, argb(on ? t.bg : t.accent, 0xff))
		right -= jw + 10 * S
	}
	meta := cal_meta(d, o)
	if two_line {
		text_in(cv, m.f_body, ellipsize(m.f_body, e.title, right - px), px, ty, th, argb(fg, 0xff))
		text_in(cv, m.f_tiny, ellipsize(m.f_tiny, meta, right - px), px, ty + th + 2 * S, int(m.f_tiny.line_h), argb(dc, 0xff))
	} else {
		mw := min(tw(m.f_tiny, meta), 190 * S)
		text_in(cv, m.f_tiny, ellipsize(m.f_tiny, meta, mw), right - mw, y, h, argb(dc, 0xff))
		text_in(cv, m.f_body, ellipsize(m.f_body, e.title, right - mw - 10 * S - px), px, y, h, argb(fg, 0xff))
	}
}

@(private)
cal_draw_month :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	d := &m.sections[m.open].cd
	u := &m.calu
	bg, fg, dim, acc, sel := t.bg, t.fg, t.fg_dim, t.accent, t.selection
	connected := cal_connected(d)
	now_day, now_m := cal_now()
	// left: the month grid, 312 px
	lw := 312 * S
	lx, ly := body[0] + 12 * S, body[1] + 8 * S
	lr := body[0] + lw - 12 * S
	fill_rect(cv, body[0] + lw, body[1], S, body[3], argb(sel, 0xff))
	y, mo, _ := civil_from_days(u.cur)
	text_in(cv, m.f_body, "‹", lx + 8 * S, ly, 28 * S, argb(dim, 0xff))
	chit(a, lx, ly, 28 * S, 28 * S, .Prev, 0)
	text_in(cv, m.f_body, "›", lr - 16 * S, ly, 28 * S, argb(dim, 0xff))
	chit(a, lr - 28 * S, ly, 28 * S, 28 * S, .Next, 0)
	title := fmt.tprintf("%s %d", MONTHS[mo - 1], y)
	text_in(cv, m.f_bold13, title, lx + (lr - lx - tw(m.f_bold13, title)) / 2, ly, 28 * S, argb(fg, 0xff))
	ly += 28 * S + 2 * S
	wkw := 30 * S
	colw := (lr - lx - wkw - 2 * S) / 7
	gx := lx + wkw + 2 * S
	heads := [8]string{"wk", "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"}
	text_in(cv, m.f_tiny, heads[0], lx + (wkw - tw(m.f_tiny, heads[0])) / 2, ly, 20 * S, argb(dim, 0xff))
	for i in 1 ..< 8 do text_in(cv, m.f_tiny, heads[i], gx + (i - 1) * colw + (colw - tw(m.f_tiny, heads[i])) / 2, ly, 20 * S, argb(dim, 0xff))
	ly += 20 * S + 2 * S
	first, n := month_weeks(u.cur)
	for w in 0 ..< n {
		d0 := first + w * 7
		wk := fmt.tprintf("%d", iso_week(d0))
		text_in(cv, m.f_tiny, wk, lx + (wkw - tw(m.f_tiny, wk)) / 2, ly, 26 * S, argb(dim, 0xff))
		fill_rect(cv, lx + wkw - S, ly, S, 36 * S, argb(sel, 0xff))
		for i in 0 ..< 7 {
			day := d0 + i
			_, dmo, dd := civil_from_days(day)
			x := gx + i * colw
			is_t, is_c := day == now_day, day == u.cur
			c := dmo == mo ? fg : dim
			f := m.f_small
			if is_t { fill_rect(cv, x, ly, colw, 36 * S, argb(acc, 0xff)); c = bg }
			else if is_c do fill_rect(cv, x, ly, colw, 36 * S, argb(sel, 0xff))
			if is_t || is_c do f = m.f_bold12
			if is_c && u.view == .Month && !u.list { rounded_rect(cv, x, ly, colw, 36 * S, 0, 0, f32(S), argb(is_t ? fg : acc, 0xff)); mark_sel(a, x, ly, colw, 36 * S) }
			lbl := fmt.tprintf("%d", dd)
			draw_text_f(cv, f, lbl, x + (colw - tw(f, lbl)) / 2, ly + 5 * S, argb(c, 0xff))
			// up to three dots, one per calendar
			cals := make([dynamic]string, 0, 3, context.temp_allocator)
			for o in cal_day(d, day) {
				id := d.evs[o.ev].cal
				have := false
				for x in cals do if x == id { have = true; break }
				if !have && len(cals) < 3 do append(&cals, id)
			}
			if len(cals) > 0 {
				dw := len(cals) * 4 * S + (len(cals) - 1) * 2 * S
				dx := x + (colw - dw) / 2
				dy := ly + 5 * S + int(f.line_h) + 4 * S
				for id in cals { fill_rect(cv, dx, dy, 4 * S, 4 * S, argb(is_t ? bg : cal_tone(t, d, id), 0xff)); dx += 6 * S }
			}
			chit(a, x, ly, colw, 36 * S, .Day, day)
		}
		ly += 36 * S + 2 * S
	}
	// legend: the shown calendars
	lgx, lgy := lx, body[1] + body[3] - 10 * S - int(m.f_tiny.line_h)
	for c in d.cals {
		if !c.on do continue
		w := 8 * S + 5 * S + tw(m.f_tiny, c.name)
		if lgx + w > lr { lgx = lx; lgy -= int(m.f_tiny.line_h) + 4 * S }
		lgx += w + 12 * S
	}
	lgx = lx
	for c in d.cals {
		if !c.on do continue
		w := 8 * S + 5 * S + tw(m.f_tiny, c.name)
		if lgx + w > lr { lgx = lx; lgy += int(m.f_tiny.line_h) + 4 * S }
		fill_rect(cv, lgx, lgy + (int(m.f_tiny.line_h) - 8 * S) / 2, 8 * S, 8 * S, argb(token(t, c.tone, dim), 0xff))
		text_in(cv, m.f_tiny, c.name, lgx + 13 * S, lgy, int(m.f_tiny.line_h), argb(dim, 0xff))
		lgx += w + 12 * S
	}

	// right: the day
	rx := body[0] + lw + S
	rr := body[0] + body[2]
	ry := body[1] + 10 * S
	f14 := msize(a, 14, true, S)
	draw_text_f(cv, f14, long_day(u.cur), rx + 14 * S, ry, argb(fg, 0xff))
	ry += int(f14.line_h) + 2 * S
	dl := cal_day(d, u.cur)
	sub := fmt.tprintf("w%d%s", iso_week(u.cur), u.cur == now_day ? " · today" : "")
	if connected do sub = fmt.tprintf("%s · %s", sub, len(dl) > 0 ? plural_n(len(dl), "event") : "nothing scheduled")
	draw_text_f(cv, m.f_tiny, sub, rx + 14 * S, ry, argb(dim, 0xff))
	ry += int(m.f_tiny.line_h) + 6 * S
	// now / next
	if u.cur == now_day && connected {
		live, nx := -1, -1
		for o in dl {
			e := d.evs[o.ev]
			if e.all do continue
			if hm(e.s) <= now_m && hm(e.e) > now_m && live < 0 do live = o.ev
			if hm(e.s) > now_m && nx < 0 do nx = o.ev
		}
		tag, name, txt, hint := "", "", "", ""
		tc := acc
		if live >= 0 { e := d.evs[live]; tag, name, txt = "NOW", e.title, fmt.tprintf(" · until %s", e.e); if e.meet != "" do hint = "j join" }
		else if nx >= 0 {
			e := d.evs[nx]
			dm := hm(e.s) - now_m
			tag, name = "NEXT", e.title
			txt = fmt.tprintf(" · in %s", dm >= 60 ? fmt.tprintf("%d h %d min", dm / 60, dm % 60) : fmt.tprintf("%d min", dm))
			if e.meet != "" do hint = "j join"
			if dm <= 10 do tc = t.yellow
		}
		if tag != "" {
			bx, bw := rx + 14 * S, rr - rx - 28 * S
			bh := int(m.f_small.line_h) + 14 * S
			ry += 2 * S
			fill_rect(cv, bx, ry, bw, bh, argb(sel, 0xff))
			text_in(cv, m.f_bold12, tag, bx + 10 * S, ry, bh, argb(tc, 0xff))
			tx := bx + 10 * S + tw(m.f_bold12, tag) + 8 * S
			hw := hint != "" ? tw(m.f_small, hint) + 8 * S : 0
			if hint != "" do text_in(cv, m.f_small, hint, bx + bw - 10 * S - tw(m.f_small, hint), ry, bh, argb(dim, 0xff))
			// the title gives way, "· in 51 min" stays
			txt = strings.concatenate({ellipsize(m.f_small, name, bx + bw - 10 * S - hw - tx - tw(m.f_small, txt)), txt}, context.temp_allocator)
			text_in(cv, m.f_small, txt, tx, ry, bh, argb(fg, 0xff))
			ry += bh + 8 * S
		}
	}
	if !connected {
		bx, bw := rx + 14 * S, rr - rx - 28 * S
		setup := d.conn == "setup"
		title := setup ? "Set up Google Calendar" : "Connect Google Calendar"
		para := setup ? "Once: in Google Cloud, enable the Google Calendar API and create an OAuth client ID (Desktop app), then download its JSON and press ↵ here again: k4 takes it from Downloads and signs you in." : "Sign in once in your browser. k4 keeps the token in the system keyring and syncs every 5 minutes and each time this opens."
		lines := wrap_text(m.f_small, para, bw - 24 * S)
		bh := 24 * S + int(m.f_bold13.line_h) + 6 * S + len(lines) * (int(m.f_small.line_h) + 2 * S)
		ry += 4 * S
		fill_rect(cv, bx, ry, bw, bh, argb(sel, 0xff))
		yy := ry + 12 * S
		draw_text_f(cv, m.f_bold13, title, bx + 12 * S, yy, argb(fg, 0xff))
		yy += int(m.f_bold13.line_h) + 6 * S
		for l in lines { draw_text_f(cv, m.f_small, l, bx + 12 * S, yy, argb(dim, 0xff)); yy += int(m.f_small.line_h) + 2 * S }
		ry += bh + 8 * S
		fill_rect(cv, rx, ry, rr - rx, 30 * S, argb(acc, 0xff))
		text_in(cv, m.f_bold12, setup ? "Open Google Cloud" : "Connect Google account", rx + 14 * S, ry, 30 * S, argb(bg, 0xff))
		text_in(cv, m.f_small, "opens browser", rr - 14 * S - tw(m.f_small, "opens browser"), ry, 30 * S, argb(bg, 0xff))
		chit(a, rx, ry, rr - rx, 30 * S, .Connect, 0)
		ry += 30 * S
		text_in(cv, m.f_small, "Not now", rx + 14 * S, ry, 30 * S, argb(fg, 0xff))
		chit(a, rx, ry, rr - rx, 30 * S, .Not_Now, 0)
		return
	}
	// the day's events, a "now" line among them on today
	bottom := body[1] + body[3]
	if len(dl) == 0 {
		draw_text_f(cv, m.f_small, "Nothing scheduled. Press n to add something.", rx + 14 * S, ry + 10 * S, argb(dim, 0xff))
		return
	}
	rh := 6 * S + int(m.f_body.line_h) + 2 * S + int(m.f_tiny.line_h) + 6 * S
	nh := int(msize(a, 10, false, S).line_h) + 4 * S
	// rows and where the now line goes
	Row :: struct { now: bool, i: int }
	rows := make([dynamic]Row, 0, len(dl) + 1, context.temp_allocator)
	placed := u.cur != now_day
	for o, i in dl {
		e := d.evs[o.ev]
		if !placed && !e.all && hm(e.e) > now_m { append(&rows, Row{now = true}); placed = true }
		append(&rows, Row{i = i})
	}
	if !placed do append(&rows, Row{now = true})
	// keep the selected event in view
	selr := -1
	for r, i in rows do if !r.now && r.i == u.ei && u.list do selr = i
	if selr >= 0 {
		if selr < u.scroll_day do u.scroll_day = selr
		for {
			h := 0
			for r in rows[u.scroll_day:selr + 1] do h += r.now ? nh : rh
			if ry + h <= bottom || u.scroll_day >= selr do break
			u.scroll_day += 1
		}
	} else do u.scroll_day = 0
	for r in rows[min(u.scroll_day, len(rows)):] {
		h := r.now ? nh : rh
		if ry + h > bottom do break
		if r.now {
			f := msize(a, 10, false, S)
			lbl := fmt.tprintf("now %d:%02d", now_m / 60, now_m % 60)
			text_in(cv, f, lbl, rx + 14 * S, ry, nh, argb(acc, 0xff))
			lx := rx + 14 * S + tw(f, lbl) + 6 * S
			fill_rect(cv, lx, ry + nh / 2, rr - 14 * S - lx, S, argb(acc, 0xff))
		} else {
			cal_event_row(a, cv, S, d, dl[r.i], u.cur, rx, ry, rr - rx, rh, u.list && r.i == u.ei, 84, true)
			chit(a, rx, ry, rr - rx, rh, .Event, r.i)
		}
		ry += h
	}
}

@(private)
plural_n :: proc(n: int, word: string) -> string { return n == 1 ? fmt.tprintf("1 %s", word) : fmt.tprintf("%d %ss", n, word) }

// Words wrapped to a width (the connect box's paragraph).
wrap_text :: proc(f: ^Font, s: string, w: int) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	line := ""
	for word in strings.fields(s, context.temp_allocator) {
		try := line == "" ? word : strings.concatenate({line, " ", word}, context.temp_allocator)
		if tw(f, try) > w && line != "" { append(&out, line); line = word }
		else do line = try
	}
	if line != "" do append(&out, line)
	return out[:]
}

@(private)
cal_draw_agenda :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	d := &m.sections[m.open].cd
	u := &m.calu
	connected := cal_connected(d)
	x, x1 := body[0], body[0] + body[2]
	y := body[1] + 4 * S
	bottom := body[1] + body[3] - 8 * S
	if !connected {
		draw_text_f(cv, m.f_small, "Connect Google Calendar to see your agenda. Press ↵.", x + 16 * S, y + 16 * S, argb(t.fg_dim, 0xff))
		return
	}
	rows, evs := cal_agenda(d, u.cur)
	u.ai = clamp(u.ai, 0, max(len(evs) - 1, 0))
	now_day, _ := cal_now()
	hh := 10 * S + int(m.f_bold12.line_h) + 4 * S
	eh := 30 * S
	emh := 8 * S + int(m.f_small.line_h)
	height :: proc(r: Cal_Ag, hh, eh, emh: int) -> int { return r.head ? hh + (r.empty ? emh : 0) : eh }
	// which row holds the selected event; scroll to it
	selr := -1
	n := -1
	for r, i in rows do if !r.head { n += 1; if n == u.ai { selr = i; break } }
	if selr >= 0 {
		if selr - 1 < u.scroll_ag do u.scroll_ag = max(selr - 1, 0)
		for {
			h := 0
			for r in rows[u.scroll_ag:selr + 1] do h += height(r, hh, eh, emh)
			if y + h <= bottom || u.scroll_ag >= selr do break
			u.scroll_ag += 1
		}
	}
	n = -1
	for r, i in rows {
		if !r.head do n += 1
		if i < u.scroll_ag do continue
		h := height(r, hh, eh, emh)
		if y + h > bottom do break
		if r.head {
			lbl := short_day(r.day)
			if r.day == now_day do lbl = strings.concatenate({"Today · ", lbl}, context.temp_allocator)
			else if r.day == now_day + 1 do lbl = strings.concatenate({"Tomorrow · ", lbl}, context.temp_allocator)
			draw_text_f(cv, m.f_bold12, lbl, x + 16 * S, y + 10 * S, argb(r.day == now_day ? t.accent : t.fg, 0xff))
			draw_text_f(cv, m.f_tiny, fmt.tprintf("w%d", iso_week(r.day)), x + 16 * S + tw(m.f_bold12, lbl) + 10 * S, y + 10 * S + (int(m.f_bold12.line_h) - int(m.f_tiny.line_h)), argb(t.fg_dim, 0xff))
			if r.empty do draw_text_f(cv, m.f_small, "Nothing scheduled", x + 136 * S, y + hh + 4 * S, argb(t.fg_dim, 0xff))
		} else {
			cal_event_row(a, cv, S, d, r.occ, r.day, x, y, x1 - x, eh, n == u.ai, 110, false)
			chit(a, x, y, x1 - x, eh, .Agenda, n)
		}
		y += h
	}
}

@(private)
cal_draw_detail :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int, f17b: ^Font) {
	m := a.menu
	t := a.theme
	d := &m.sections[m.open].cd
	u := &m.calu
	if u.det < 0 || u.det >= len(d.evs) do return
	e := d.evs[u.det]
	x, x1 := body[0] + 18 * S, body[0] + body[2] - 18 * S
	y := body[1] + 14 * S
	fill_rect(cv, x, y + (int(f17b.line_h) - 10 * S) / 2, 10 * S, 10 * S, argb(cal_tone(t, d, e.cal), 0xff))
	draw_text_f(cv, f17b, ellipsize(f17b, e.title, x1 - x - 20 * S), x + 20 * S, y, argb(t.fg, 0xff))
	y += int(f17b.line_h) + 10 * S
	// info: When, Calendar, Where, Video, Guests, Notes, Reminder
	d0 := day_of(e.date)
	when_: string
	if e.all do when_ = e.days > 1 ? fmt.tprintf("%s – %s · all day", short_day(d0), short_day(d0 + e.days - 1)) : fmt.tprintf("%s · all day", short_day(d0))
	else {
		dur := hm(e.e) - hm(e.s)
		when_ = fmt.tprintf("%s · %s–%s · %s", short_day(d0), e.s, e.e, dur >= 60 && dur % 60 == 0 ? fmt.tprintf("%d h", dur / 60) : (dur >= 60 ? fmt.tprintf("%.1f h", f64(dur) / 60) : fmt.tprintf("%d min", dur)))
	}
	info := make([dynamic][2]string, 0, 8, context.temp_allocator)
	append(&info, [2]string{"When", when_})
	if c := cal_by_id(d, e.cal); c != nil do append(&info, [2]string{"Calendar", c.ro ? fmt.tprintf("%s · read-only", c.name) : c.name})
	if e.loc != "" do append(&info, [2]string{"Where", e.loc})
	if e.meet != "" do append(&info, [2]string{"Video", e.meet})
	if len(e.guests) > 0 {
		gs := make([dynamic]string, 0, len(e.guests), context.temp_allocator)
		for g in e.guests {
			st := g[1]
			if g[0] == "You" && e.org != "" do switch cal_rsvp_now(m, e) { case "Yes": st = "going"; case "Maybe": st = "maybe"; case "No": st = "not going" }
			append(&gs, st != "" ? fmt.tprintf("%s  ·  %s", g[0], st) : g[0])
		}
		append(&info, [2]string{"Guests", strings.join(gs[:], "\n", context.temp_allocator)})
	}
	if e.notes != "" do append(&info, [2]string{"Notes", e.notes})
	if !e.all do append(&info, [2]string{"Reminder", "10 min before · notification and bar indicator"})
	acts := cal_acts(m, d, e)
	lh := int(f32(m.f_small.line_h) * 1.15)
	acts_top := body[1] + body[3] - 8 * S - len(acts) * 30 * S - 7 * S
	for kv in info {
		lines := strings.split(kv[1], "\n", context.temp_allocator)
		if y + lh > acts_top do break
		draw_text_f(cv, m.f_small, kv[0], x, y, argb(t.fg_dim, 0xff))
		for l in lines {
			if y + lh > acts_top do break
			draw_text_f(cv, m.f_small, ellipsize(m.f_small, l, x1 - x - 96 * S), x + 96 * S, y, argb(t.fg, 0xff))
			y += lh
		}
		y += 5 * S
	}
	// actions, under a rule
	y = acts_top
	fill_rect(cv, body[0], y, body[2], S, argb(t.selection, 0xff))
	y += 7 * S
	u.di = clamp(u.di, 0, max(len(acts) - 1, 0))
	for act, i in acts {
		on := i == u.di
		l, mt: string
		switch act {
		case .Rsvp: l, mt = "Going", fmt.tprintf("‹ %s ›", cal_rsvp_now(m, e))
		case .Join: l, mt = "Join video call", "j"
		case .Open: l, mt = "Open in Google Calendar", "o · browser"
		case .Copy: l, mt = "Copy meeting link", ""
		case .Delete: l, mt = e.org != "" ? "Remove from my calendar" : "Delete event", u.arm ? "press ↵ again" : "asks first"
		}
		fc := on ? t.bg : (act == .Delete && u.arm ? t.red : t.fg)
		if on { fill_rect(cv, body[0], y, body[2], 30 * S, argb(t.accent, 0xff)); mark_sel(a, body[0], y, body[2], 30 * S) }
		text_in(cv, m.f_body, l, x, y, 30 * S, argb(fc, 0xff))
		text_in(cv, m.f_small, mt, x1 - tw(m.f_small, mt), y, 30 * S, argb(on ? t.bg : t.fg_dim, 0xff))
		chit(a, body[0], y, body[2], 30 * S, .Act, i)
		y += 30 * S
	}
}

@(private)
cal_draw_add :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	d := &m.sections[m.open].cd
	u := &m.calu
	x, x1 := body[0] + 18 * S, body[0] + body[2] - 18 * S
	y := body[1] + 16 * S
	draw_text_f(cv, m.f_bold11, "NEW EVENT", x, y, argb(t.fg_dim, 0xff))
	y += int(m.f_bold11.line_h) + 10 * S
	ih := 38 * S
	rounded_rect(cv, x, y, x1 - x, ih, 0, argb(t.bg, 0xff), f32(S), argb(t.accent, 0xff))
	f := msize(a, 14, false, S)
	q := string(a.query[:])
	if q == "" do text_in(cv, f, "Lunch with Elin fri 12", x + 12 * S, y, ih, argb(t.fg_dim, 0xff))
	else do text_in(cv, f, q, x + 12 * S, y, ih, argb(t.fg, 0xff), x1 - 12 * S)
	qs := shape(f, q)
	cur := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	caret := x + 12 * S + int(qs.cp_x[min(cur, len(qs.cp_x) - 1)])
	fill_rect(cv, caret, y + (ih - int(f.line_h)) / 2, max(S, 2), int(f.line_h), argb(t.accent, 0xff))
	a.caret = {caret, y + (ih - int(f.line_h)) / 2, max(S, 2), int(f.line_h)}
	y += ih + 10 * S
	offline := d.conn == "offline"
	hint := offline ? "Offline: it is saved here and sent to Google when you are back online." : "Google quick add: a day (fri, tomorrow) and a time (12, 14:30, 3pm) are picked out of the text."
	for l in wrap_text(m.f_tiny, hint, x1 - x) { draw_text_f(cv, m.f_tiny, l, x, y, argb(offline ? t.yellow : t.fg_dim, 0xff)); y += int(m.f_tiny.line_h) + 3 * S }
	y += 8 * S
	p := cal_quick(q, u.cur)
	cals := cal_writable(d)
	u.acal = clamp(u.acal, 0, max(len(cals) - 1, 0))
	when_ := p.time != "" ? fmt.tprintf("%s · %s–%s", short_day(p.day), p.time, quick_end(p.time)) : fmt.tprintf("%s · all day", short_day(p.day))
	title := p.title != "" ? p.title : "—"
	calname := len(cals) > 0 ? fmt.tprintf("‹ %s ›", cals[u.acal].name) : "—"
	remind := p.time != "" ? "10 min before" : "09:00 that day"
	rows := [4][2]string{{"Title", title}, {"When", when_}, {"Calendar", calname}, {"Reminder", remind}}
	for r, i in rows {
		if i == 2 do fill_rect(cv, body[0], y, body[2], 30 * S, argb(t.selection, 0xff))
		text_in(cv, m.f_small, r[0], x, y, 30 * S, argb(t.fg_dim, 0xff))
		text_in(cv, m.f_body, ellipsize(m.f_body, r[1], x1 - x - 110 * S), x + 96 * S, y, 30 * S, argb(t.fg, 0xff))
		if i == 2 && len(cals) > 0 do fill_rect(cv, x1 - 8 * S, y + 11 * S, 8 * S, 8 * S, argb(token(t, cals[u.acal].tone, t.fg_dim), 0xff))
		y += 30 * S
	}
}

@(private)
cal_draw_cals :: proc(a: ^App, cv: ^Canvas, S: int, body: [4]int) {
	m := a.menu
	t := a.theme
	d := &m.sections[m.open].cd
	u := &m.calu
	x, x1 := body[0] + 18 * S, body[0] + body[2] - 18 * S
	y := body[1] + 8 * S
	head :: proc(cv: ^Canvas, m: ^Menu, t: logic.Theme, s: string, x, y, S: int) -> int {
		draw_text_f(cv, m.f_bold11, s, x, y + 8 * S, argb(t.fg_dim, 0xff))
		return 8 * S + int(m.f_bold11.line_h) + 4 * S
	}
	y += head(cv, m, t, "CALENDARS · SHOWN IN THE BAR AND THE GRID", x, y, S)
	u.ci = clamp(u.ci, 0, len(d.cals) + 1)
	for i in 0 ..< len(d.cals) + 2 {
		if i == len(d.cals) do y += head(cv, m, t, "GOOGLE ACCOUNT", x, y + 6 * S, S) + 6 * S
		on := i == u.ci
		fc := on ? t.bg : t.fg
		if on { fill_rect(cv, body[0], y, body[2], 30 * S, argb(t.accent, 0xff)); mark_sel(a, body[0], y, body[2], 30 * S) }
		lx := x
		right := x1
		switch {
		case i < len(d.cals):
			c := d.cals[i]
			fill_rect(cv, lx, y + 11 * S, 8 * S, 8 * S, argb(on ? t.bg : token(t, c.tone, t.fg_dim), 0xff))
			lx += 18 * S
			right -= draw_switch(a, cv, S, right, y, 30 * S, c.on, on) + 10 * S
			text_in(cv, m.f_small, c.acct, right - tw(m.f_small, c.acct), y, 30 * S, argb(on ? t.bg : t.fg_dim, 0xff))
			text_in(cv, m.f_body, c.name, lx, y, 30 * S, argb(fc, 0xff))
		case i == len(d.cals):
			meta := d.conn == "offline" ? d.status : fmt.tprintf("%s · every 5 min", d.status)
			text_in(cv, m.f_small, meta, right - tw(m.f_small, meta), y, 30 * S, argb(on ? t.bg : t.fg_dim, 0xff))
			text_in(cv, m.f_body, "Sync now", lx, y, 30 * S, argb(fc, 0xff))
		case:
			text_in(cv, m.f_small, "asks first", right - tw(m.f_small, "asks first"), y, 30 * S, argb(on ? t.bg : t.fg_dim, 0xff))
			text_in(cv, m.f_body, "Disconnect Google account…", lx, y, 30 * S, argb(fc, 0xff))
		}
		chit(a, body[0], y, body[2], 30 * S, .Cal_Row, i)
		y += 30 * S
	}
}

// ---------- the pointer ----------

cal_click :: proc(a: ^App, h: Hit) {
	m := a.menu
	d := &m.sections[m.open].cd
	u := &m.calu
	m.toast = ""
	switch Cal_Hit(h.a) {
	case .Tab_Month: u.view, u.list = .Month, false
	case .Tab_Agenda: u.view, u.list = .Agenda, false
	case .Prev: u.cur = shift_month(u.cur, -1)
	case .Next: u.cur = shift_month(u.cur, 1)
	case .Day: u.cur, u.list, u.ei = h.b, false, 0
	case .Event:
		dl := cal_day(d, u.cur)
		if u.list && u.ei == h.b && h.b < len(dl) do cal_detail(m, dl[h.b].ev, .Month)
		else do u.list, u.ei = true, h.b
	case .Agenda:
		_, evs := cal_agenda(d, u.cur)
		if u.ai == h.b && h.b < len(evs) do cal_detail(m, evs[h.b].occ.ev, .Agenda)
		else do u.ai = h.b
	case .Act:
		if u.det >= 0 && u.det < len(d.evs) {
			acts := cal_acts(m, d, d.evs[u.det])
			u.di = h.b
			if h.b < len(acts) do cal_act(a, acts[h.b])
		}
	case .Cal_Row: u.ci = h.b; cal_cal_row(a, h.b)
	case .Connect: cal_run(a, a.menu.sections[a.menu.open].cd.conn == "setup" ? "Looking for the OAuth client…" : "Opening the Google sign-in…", "connect")
	case .Not_Now: cal_run(a, "", "later")
	}
}

// ---------- --dump ----------

cal_dump :: proc(a: ^App, b: ^strings.Builder) {
	m := a.menu
	d := &m.sections[m.open].cd
	u := &m.calu
	cal_open(a)
	y, mo, dd := civil_from_days(u.cur)
	fmt.sbprintfln(b, "calendar %v%s · %04d-%02d-%02d · %s · %s", u.view, u.list ? " (events)" : "", y, mo, dd, d.conn, d.status)
	fmt.sbprintfln(b, "hints %s", hints_text(cal_hints(m, d)))
	switch u.view {
	case .Month:
		for o, i in cal_day(d, u.cur) {
			e := d.evs[o.ev]
			fmt.sbprintfln(b, "%s %s · %s · %s%s", u.list && i == u.ei ? "*" : " ", cal_time(e), e.title, cal_meta(d, o), cal_past(e, u.cur) ? " (past)" : "")
		}
	case .Agenda:
		rows, _ := cal_agenda(d, u.cur)
		n := -1
		for r in rows {
			if r.head { fmt.sbprintfln(b, "== %s%s", short_day(r.day), r.empty ? " · nothing" : ""); continue }
			n += 1
			e := d.evs[r.occ.ev]
			fmt.sbprintfln(b, "%s %s · %s", n == u.ai ? "*" : " ", cal_time(e), e.title)
		}
	case .Detail:
		if u.det >= 0 && u.det < len(d.evs) {
			e := d.evs[u.det]
			fmt.sbprintfln(b, "event %s", e.title)
			for act, i in cal_acts(m, d, e) do fmt.sbprintfln(b, "%s %v%s", i == u.di ? "*" : " ", act, act == .Rsvp ? fmt.tprintf(" %s", cal_rsvp_now(m, e)) : (act == .Delete && u.arm ? " armed" : ""))
		}
	case .Add:
		p := cal_quick(string(a.query[:]), u.cur)
		py, pm, pd := civil_from_days(p.day)
		fmt.sbprintfln(b, "new %q · %04d-%02d-%02d · %s", p.title, py, pm, pd, p.time != "" ? p.time : "all day")
	case .Cals:
		for c, i in d.cals do fmt.sbprintfln(b, "%s %s %s", i == u.ci ? "*" : " ", c.name, c.on ? "shown" : "hidden")
	}
}

@(private)
hints_text :: proc(h: [][2]string) -> string {
	parts := make([dynamic]string, 0, len(h), context.temp_allocator)
	for x in h do append(&parts, fmt.tprintf("%s %s", x[0], x[1]))
	return strings.join(parts[:], " · ", context.temp_allocator)
}
