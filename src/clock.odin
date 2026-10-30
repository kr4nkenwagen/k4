package k4

import "core:c/libc"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --clock: k4's Clock (k4-clock, clock.py), the Kestrel design's KClock board, 760×560 (--popup
// from the bar clock: 420×560). The head: CLOCK › TAB, the time to the second, the date, the place,
// the zone, the week. Four tabs (Tab, Alt+1–4):
//   World      the cities, here first: a 24 h strip each (green 08–18 there, the hour now lit),
//              the time there, day or night, today or tomorrow. ← → moves a cursor through the
//              hours to compare (↵ makes a calendar event then); ↵ copies a city's time; typing
//              finds a city to add; Del removes one.
//   Timers     newest first: a ring for what has gone, the time left, its name, when it ends.
//              Typing "10m", "1h30 bread" and ↵ starts one, or a chip; Space pauses, + − a minute.
//   Alarms     the time, the name, the days, when it rings next, on or off (Space). Typing
//              "6:45 weekdays gym" and ↵ sets one.
//   Stopwatch  big digits, laps (the best green, the slowest red): Space, l, r.
// A timer that is done or an alarm that rings: a banner on top (Esc stops; + one more minute,
// s snoozes 9 min) and the corners in its colour. Del and ^Z undo. Timers and alarms ring with
// the window closed: clock.py keeps systemd timers for them.
// Data (k4-clock data; the panel's R and L lines too), again every 2 s while open:
//   N <now unix> <home city> <zone> <week> <home utc offset>
//   C <city> <country> <utc offset> <home 1|0> <a DST change soon> <zone> · Z <city> <country> <utc offset>  (to add)
//   T <id> <name> <total s> <end unix, 0 paused> <left s when paused> <done unix>
//   A <id> <h> <m> <days Mon..Sun 0|1> <on 1|0> <name> <next unix>
//   W <running 1|0> <started unix> <before s> <laps s,…> · G <timer|alarm> <id> <name> <since> <HH:MM> · U <kind>
// The runner's verbs: timer add S [NAME] | timer toggle|remove ID | timer plus ID ±S, alarm add H M
// DAYS [NAME] | alarm toggle|remove ID, city add|remove NAME, watch toggle|lap|reset, stop, snooze,
// more, undo, copy TEXT, event HH.

CLOCK_W, CLOCK_PW, CLOCK_H :: 760, 420, 560

Clock_City :: struct { name, country, dst: string, off: i64, home: bool }
Clock_Zone :: struct { name, country: string, off: i64 }
Clock_Timer :: struct { id, label: string, total, end, left, done: f64 }
Clock_Alarm :: struct { id, label, days: string, h, m: int, on: bool, next: i64 }
Clock_Tab :: enum { World, Timers, Alarms, Watch }

Clock :: struct {
	using pn: Panel,
	arena:   vmem.Arena,
	home, zone, week: string,
	home_off: i64,
	cities:  [dynamic]Clock_City,
	zones:   [dynamic]Clock_Zone,
	timers:  [dynamic]Clock_Timer,
	alarms:  [dynamic]Clock_Alarm,
	sw_run:  bool,
	sw_t0, sw_base: f64,
	laps:    [dynamic]f64,
	ring_kind, ring_id, ring_label, ring_at: string,
	ring_since: f64,
	undo:    string,
	// what you do
	tab:     Clock_Tab,
	sel:     int,
	field:   bool,
	q:       [dynamic]u8,
	cmp:     int, // the compare cursor: hours from now
	cmp_on:  bool,
	f20b, f26b, f28b, f40b, f58b, f22b, f30b: ^Font,
}

clock_setup :: proc(a: ^App, data: string) {
	m := new(Clock)
	_ = vmem.arena_init_growing(&m.arena)
	m.mode = {draw = clock_draw, key = clock_key, click = clock_click, scroll = clock_scroll, loaded = clock_loaded, tick = clock_tick, dump = clock_dump}
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	m.f20b, m.f22b, m.f26b, m.f28b, m.f30b, m.f40b, m.f58b = bld(a, 20), bld(a, 22), bld(a, 26), bld(a, 28), bld(a, 30), bld(a, 40), bld(a, 58)
	panel_init(a, &m.pn, "clock", data)
	m.refresh_ms = 2000
	a.width, a.height = m.popup ? CLOCK_PW : CLOCK_W, CLOCK_H
	switch os.get_env("K4_CLOCK_TAB", context.temp_allocator) {
	case "timers": m.tab = .Timers
	case "alarms": m.tab = .Alarms
	case "watch", "stopwatch": m.tab = .Watch
	}
}

@(private = "file")
CK :: proc(a: ^App) -> ^Clock { return (^Clock)(a.pn) }

// Now (K4_CLOCK_NOW in tests), in seconds.
@(private = "file")
ck_now :: proc() -> f64 {
	if v, ok := strconv.parse_f64(os.get_env("K4_CLOCK_NOW", context.temp_allocator)); ok do return v
	return f64(time.to_unix_nanoseconds(time.now())) / 1e9
}

@(private = "file")
clock_loaded :: proc(a: ^App, data: string) {
	m := CK(a)
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al := context.allocator) -> string { return strings.clone(s, al) }
	f64_ :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(s); return v }
	i64_ :: proc(s: string) -> i64 { v, _ := strconv.parse_i64(s); return v }
	m.cities, m.zones = make([dynamic]Clock_City, al), make([dynamic]Clock_Zone, al)
	m.timers, m.alarms, m.laps = make([dynamic]Clock_Timer, al), make([dynamic]Clock_Alarm, al), make([dynamic]f64, al)
	m.ring_kind, m.undo, m.sw_run = "", "", false
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "N": m.home, m.zone, m.week, m.home_off = c(fget(f, 2), al), c(fget(f, 3), al), c(fget(f, 4), al), i64_(fget(f, 5))
		case "C": append(&m.cities, Clock_City{name = c(fget(f, 1), al), country = c(fget(f, 2), al), off = i64_(fget(f, 3)), home = fget(f, 4) == "1", dst = c(fget(f, 5), al)})
		case "Z": append(&m.zones, Clock_Zone{name = c(fget(f, 1), al), country = c(fget(f, 2), al), off = i64_(fget(f, 3))})
		case "T": append(&m.timers, Clock_Timer{id = c(fget(f, 1), al), label = c(fget(f, 2), al), total = f64_(fget(f, 3)), end = f64_(fget(f, 4)), left = f64_(fget(f, 5)), done = f64_(fget(f, 6))})
		case "A":
			h, _ := strconv.parse_int(fget(f, 2)); mi, _ := strconv.parse_int(fget(f, 3))
			append(&m.alarms, Clock_Alarm{id = c(fget(f, 1), al), h = h, m = mi, days = c(fget(f, 4), al), on = fget(f, 5) == "1", label = c(fget(f, 6), al), next = i64_(fget(f, 7))})
		case "W":
			m.sw_run, m.sw_t0, m.sw_base = fget(f, 1) == "1", f64_(fget(f, 2)), f64_(fget(f, 3))
			for l in strings.split(fget(f, 4), ",", context.temp_allocator) do if l != "" do append(&m.laps, f64_(l))
		case "G": m.ring_kind, m.ring_id, m.ring_label, m.ring_since, m.ring_at = c(fget(f, 1), al), c(fget(f, 2), al), c(fget(f, 3), al), f64_(fget(f, 4)), c(fget(f, 5), al)
		case "U": m.undo = c(fget(f, 1), al)
		}
	}
	m.sel = clamp(m.sel, 0, max(ck_len(m) - 1, 0))
}

@(private = "file")
ck_len :: proc(m: ^Clock) -> int {
	switch m.tab {
	case .World: return len(m.cities)
	case .Timers: return len(m.timers)
	case .Alarms: return len(m.alarms)
	case .Watch: return 0
	}
	return 0
}

// ---------- words ----------

@(private = "file")
ck_pad :: proc(n: int) -> string { return fmt.tprintf("%02d", n) }

// "10:32" of seconds into a day (any number: it wraps).
@(private = "file")
ck_hm :: proc(s: i64) -> string {
	d := ((s % 86400) + 86400) % 86400
	return fmt.tprintf("%02d:%02d", d / 3600, d / 60 % 60)
}

// "4:00", "27:41", "1:30:00".
clock_dur :: proc(secs: f64) -> string {
	s := max(int(math.ceil(secs)), 0)
	h, mi, x := s / 3600, s / 60 % 60, s % 60
	if h > 0 do return fmt.tprintf("%d:%02d:%02d", h, mi, x)
	return fmt.tprintf("%d:%02d", mi, x)
}

clock_in_words :: proc(secs: i64) -> string {
	s := max(secs, 0)
	d, h, mi := s / 86400, s / 3600 % 24, s / 60 % 60
	if d > 0 do return fmt.tprintf("in %d d %d h", d, h)
	return h > 0 ? fmt.tprintf("in %d h %d min", h, mi) : fmt.tprintf("in %d min", mi)
}

// The stopwatch: "00:04:52" and ".61".
@(private = "file")
ck_sw :: proc(el: f64) -> (string, string) {
	e := max(el, 0)
	mi := int(e / 60)
	x := e - f64(mi * 60)
	return fmt.tprintf("%02d:%02d:%02d", mi / 60, mi % 60, int(x)), fmt.tprintf(".%02d", int((x - math.floor(x)) * 100))
}

@(private = "file")
ck_rel :: proc(off: i64, home: bool) -> string {
	if off == 0 do return home ? "local" : "same time"
	h := f64(abs(off)) / 3600
	hs := h == math.floor(h) ? fmt.tprintf("%d", int(h)) : fmt.tprintf("%.1f", h)
	return fmt.tprintf("%s%s h", off > 0 ? "+" : "−", hs)
}

// The local time now at home, and its day (days since 1970, weekday Mon=0).
@(private = "file")
ck_local :: proc(m: ^Clock) -> (secs: i64, day: i64, wd: int) {
	t := i64(ck_now()) + m.home_off
	day = t >= 0 ? t / 86400 : (t - 86399) / 86400
	return t, day, int((day + 3) % 7) // (1970-01-01 was a Thursday)
}

@(private = "file")
ck_date :: proc(m: ^Clock) -> string {
	t, _, wd := ck_local(m)
	_, mo, d := time.date(time.unix(t, 0))
	days := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.tprintf("%s %d %s", days[wd], d, months[int(mo) - 1])
}

// ---------- parsing what is typed (the window's field and the launcher) ----------

// "10m", "1h30 bread", "90s eggs", "4:30", "25" (minutes), "timer 3m tea" → seconds, the name.
clock_parse_dur :: proc(q: string) -> (secs: int, label: string, ok: bool) {
	t := strings.to_lower(strings.trim_space(q), context.temp_allocator)
	words := make([dynamic]string, 0, 8, context.temp_allocator)
	hit, after_h := false, false
	i := 0
	for i < len(t) {
		ch := t[i]
		if ch == ' ' { i += 1; continue }
		if ch >= '0' && ch <= '9' {
			j := i
			for j < len(t) && (t[j] >= '0' && t[j] <= '9' || t[j] == '.') do j += 1
			num, _ := strconv.parse_f64(t[i:j])
			if !hit && j + 2 < len(t) + 1 && j < len(t) && t[j] == ':' { // 4:30
				k := j + 1
				for k < len(t) && t[k] >= '0' && t[k] <= '9' do k += 1
				ss, _ := strconv.parse_int(t[j + 1:k])
				secs += int(num) * 60 + ss
				hit, i = true, k
				continue
			}
			k := j
			for k < len(t) && t[k] == ' ' do k += 1
			u := k
			for u < len(t) && t[u] >= 'a' && t[u] <= 'z' do u += 1
			unit := t[k:u]
			switch unit {
			case "h", "hr", "hrs", "hour", "hours": secs += int(num * 3600); hit, after_h, i = true, true, u; continue
			case "m", "min", "mins", "minute", "minutes": secs += int(num) * 60; hit, after_h, i = true, false, u; continue
			case "s", "sec", "secs", "second", "seconds": secs += int(num); hit, after_h, i = true, false, u; continue
			}
			if after_h || !hit { secs += int(num) * 60; hit, after_h, i = true, false, j; continue } // "1h30", "25"
			append(&words, t[i:j]); i = j
			continue
		}
		j := i
		for j < len(t) && t[j] != ' ' do j += 1
		if t[i:j] != "timer" do append(&words, t[i:j])
		i = j
	}
	if !hit || secs <= 0 do return 0, "", false
	return secs, strings.join(words[:], " ", context.temp_allocator), true
}

// "7:30", "6:45 weekdays gym", "9 weekends" → hour, minute, days (Mon..Sun), how often, the name.
clock_parse_alarm :: proc(q: string) -> (h, mi: int, days, rep, label: string, ok: bool) {
	t := strings.to_lower(strings.trim_space(q), context.temp_allocator)
	j := 0
	for j < len(t) && j < 2 && t[j] >= '0' && t[j] <= '9' do j += 1
	if j == 0 do return
	h, _ = strconv.parse_int(t[:j])
	if j < len(t) && (t[j] == ':' || t[j] == '.') do j += 1
	k := j
	for k < len(t) && k - j < 2 && t[k] >= '0' && t[k] <= '9' do k += 1
	if k - j == 2 do mi, _ = strconv.parse_int(t[j:k])
	else if k > j do return
	else do k = j
	if k < len(t) && t[k] != ' ' do return
	if h > 23 || mi > 59 do return
	rest := t[k:]
	days, rep = "0000000", "once"
	kinds := [?][3]string{{"weekdays", "1111100", "weekdays"}, {"weekday", "1111100", "weekdays"}, {"weekends", "0000011", "weekends"}, {"weekend", "0000011", "weekends"}, {"every day", "1111111", "every day"}, {"everyday", "1111111", "every day"}, {"daily", "1111111", "every day"}}
	for kd in kinds do if strings.contains(rest, kd[0]) {
		days, rep = kd[1], kd[2]
		rest, _ = strings.replace(rest, kd[0], " ", 1, context.temp_allocator)
		break
	}
	label = strings.join(strings.fields(rest, context.temp_allocator), " ", context.temp_allocator)
	return h, mi, days, rep, label, true
}

// Seconds from now (local seconds into the week: weekday wd, s into the day) to an alarm's next ring.
clock_alarm_in :: proc(h, mi: int, days: string, wd: int, s: i64) -> i64 {
	for d in 0 ..< 8 {
		w := (wd + d) % 7
		at := i64(d) * 86400 + i64(h * 3600 + mi * 60) - s
		if at <= 0 do continue
		if strings.contains(days, "1") && (w >= len(days) || days[w] != '1') do continue
		return at
	}
	return 0
}

// The local wall clock now: weekday (Mon=0), seconds into the day (the launcher's rows).
clock_local_now :: proc() -> (wd: int, s: i64) {
	if os.get_env("K4_NOW", context.temp_allocator) != "" { // tests (cal.odin's)
		day, mins := cal_now()
		return int(((day + 3) % 7 + 7) % 7), i64(mins * 60)
	}
	t := libc.time(nil)
	tm := libc.localtime(&t)
	return int((tm.tm_wday + 6) % 7), i64(tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec)
}

// ---------- keys ----------

@(private = "file")
ck_set_tab :: proc(m: ^Clock, t: Clock_Tab) {
	m.tab, m.sel, m.field, m.cmp_on, m.cmp = t, 0, false, false, 0
	clear(&m.q)
}

// The timer that is done (ringing), if any.
@(private = "file")
ck_done :: proc(m: ^Clock) -> int {
	for x, i in m.timers do if x.done > 0 do return i
	return -1
}

@(private = "file")
ck_left :: proc(x: Clock_Timer) -> f64 { return x.done > 0 ? 0 : (x.end > 0 ? max(x.end - ck_now(), 0) : x.left) }

// The field's city: the first that starts with what is typed.
@(private = "file")
ck_zone_hit :: proc(m: ^Clock) -> int {
	q := strings.to_lower(strings.trim_space(string(m.q[:])), context.temp_allocator)
	if q == "" do return -1
	for z, i in m.zones do if strings.has_prefix(strings.to_lower(z.name, context.temp_allocator), q) do return i
	return -1
}

@(private = "file")
ck_enter :: proc(a: ^App) {
	m := CK(a)
	q := strings.trim_space(string(m.q[:]))
	switch m.tab {
	case .World:
		if m.field {
			if i := ck_zone_hit(m); i >= 0 { panel_run(a, "city", "add", m.zones[i].name); clear(&m.q); m.field = false; m.sel = len(m.cities) }
			else do panel_say(&m.pn, q == "" ? "Type a city" : "No city found", a.theme.yellow)
			return
		}
		lt, _, _ := ck_local(m)
		if m.cmp_on { panel_run(a, "event", fmt.tprint((lt / 3600 % 24 + i64(m.cmp) + 24 * 4) % 24)); return }
		if m.sel < len(m.cities) {
			c := m.cities[m.sel]
			panel_run(a, "copy", fmt.tprintf("%s %s", c.name, ck_hm(lt - m.home_off + c.off)))
		}
	case .Timers:
		if m.field {
			secs, label, ok := clock_parse_dur(q)
			if !ok { panel_say(&m.pn, "Type a length, like 10m", a.theme.yellow); return }
			args := make([dynamic]string, 0, 4, context.temp_allocator)
			append(&args, "add", fmt.tprint(secs))
			if label != "" do append(&args, label)
			panel_run(a, "timer", ..args[:])
			clear(&m.q); m.field, m.sel = false, 0
			return
		}
		if m.sel < len(m.timers) do panel_run(a, "timer", "toggle", m.timers[m.sel].id)
	case .Alarms:
		if m.field {
			h, mi, days, _, label, ok := clock_parse_alarm(q)
			if !ok { panel_say(&m.pn, "Type a time, like 7:30", a.theme.yellow); return }
			args := make([dynamic]string, 0, 5, context.temp_allocator)
			append(&args, "add", fmt.tprint(h), fmt.tprint(mi), days)
			if label != "" do append(&args, label)
			panel_run(a, "alarm", ..args[:])
			clear(&m.q); m.field = false
			return
		}
		if m.sel < len(m.alarms) do panel_run(a, "alarm", "toggle", m.alarms[m.sel].id)
	case .Watch: panel_run(a, "watch", "lap")
	}
}

@(private = "file")
clock_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := CK(a)
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	plain := text != "" && k == .None && !ctrl && !alt
	n := ck_len(m)
	ringing := m.ring_kind != "" || ck_done(m) >= 0
	if ctrl && (low == 'c' || low == 'g') { panel_close(a); return true }
	if ctrl && low == 'z' { panel_run(a, "undo"); return true }
	if ringing && !m.field {
		switch {
		case k == .Escape: panel_run(a, "stop"); return true
		case text == "s" && m.ring_kind == "alarm": panel_run(a, "snooze"); return true
		case (text == "+" || text == "=") && m.ring_kind != "alarm": panel_run(a, "more"); return true
		}
	}
	if k == .Tab || k == .Back_Tab { ck_set_tab(m, Clock_Tab((int(m.tab) + (k == .Tab ? 1 : 3)) % 4)); return true }
	if alt && ch >= '1' && ch <= '4' { ck_set_tab(m, Clock_Tab(int(ch - '1'))); return true }
	if m.field {
		switch {
		case k == .Enter: ck_enter(a)
		case k == .Down: if n > 0 do m.field = false
		case k == .Escape:
			if len(m.q) > 0 do clear(&m.q)
			else do m.field = false
		case k == .Backspace: if len(m.q) > 0 do pop(&m.q)
		case ctrl && low == 'v': append(&m.q, ..transmute([]u8)msg_clipboard())
		case plain: append(&m.q, ..transmute([]u8)text)
		case: return false
		}
		return true
	}
	if plain && len(text) == 1 && text[0] >= '1' && text[0] <= '4' && (m.tab == .World || m.tab == .Watch) {
		ck_set_tab(m, Clock_Tab(int(text[0] - '1')))
		return true
	}
	if m.tab == .Watch {
		switch {
		case text == " ": panel_run(a, "watch", "toggle")
		case text == "l" || k == .Enter:
			if !m.sw_run do panel_say(&m.pn, "Start it first · Space")
			else do panel_run(a, "watch", "lap")
		case text == "r" || k == .Delete: panel_run(a, "watch", "reset")
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	switch {
	case k == .Down: m.sel = min(m.sel + 1, max(n - 1, 0))
	case k == .Up:
		if m.sel == 0 do m.field = true
		else do m.sel -= 1
	case m.tab == .World && (k == .Right || k == .Left):
		m.cmp += k == .Right ? 1 : -1
		m.cmp_on = true
	case k == .Enter: ck_enter(a)
	case text == " " && m.tab == .Timers: if m.sel < len(m.timers) do panel_run(a, "timer", "toggle", m.timers[m.sel].id)
	case text == " " && m.tab == .Alarms: if m.sel < len(m.alarms) do panel_run(a, "alarm", "toggle", m.alarms[m.sel].id)
	case (text == "+" || text == "=") && m.tab == .Timers: if m.sel < len(m.timers) do panel_run(a, "timer", "plus", m.timers[m.sel].id, "60")
	case text == "-" && m.tab == .Timers: if m.sel < len(m.timers) do panel_run(a, "timer", "plus", m.timers[m.sel].id, "-60")
	case k == .Delete || (ctrl && k == .Backspace):
		switch m.tab {
		case .Timers: if m.sel < len(m.timers) do panel_run(a, "timer", "remove", m.timers[m.sel].id)
		case .Alarms: if m.sel < len(m.alarms) do panel_run(a, "alarm", "remove", m.alarms[m.sel].id)
		case .World:
			if m.sel < len(m.cities) && !m.cities[m.sel].home do panel_run(a, "city", "remove", m.cities[m.sel].name)
			else do panel_say(&m.pn, "Here stays", a.theme.yellow)
		case .Watch:
		}
		m.sel = max(m.sel - 1, 0)
	case k == .Escape:
		if m.cmp_on { m.cmp_on, m.cmp = false, 0 }
		else do panel_close(a)
	case plain && text != " ": m.field = true; append(&m.q, ..transmute([]u8)text)
	case: return false
	}
	return true
}

@(private = "file")
clock_scroll :: proc(a: ^App, n: int) -> bool {
	m := CK(a)
	m.sel = clamp(m.sel - n, 0, max(ck_len(m) - 1, 0))
	return true
}

// Hits: .Row a row (a), .Tab a tab (a), .Chip a chip (a: 0–4), a banner's button (10, 11), the field (9).
@(private = "file")
clock_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := CK(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: m.sel, m.field = h.a, false
	case .Tab: ck_set_tab(m, Clock_Tab(h.a))
	case .Chip:
		switch h.a {
		case 0 ..= 4:
			chips := ck_chips()
			args := make([dynamic]string, 0, 3, context.temp_allocator)
			append(&args, "add", fmt.tprint(chips[h.a].secs))
			if chips[h.a].label != "" do append(&args, chips[h.a].label)
			panel_run(a, "timer", ..args[:])
		case 9: m.field = true
		case 10: panel_run(a, m.ring_kind == "alarm" ? "snooze" : "more")
		case 11: panel_run(a, "stop")
		}
	case: return false
	}
	return true
}

// Redraws: 10 a second for a running stopwatch shown, 4 for a ringing banner, else each second.
@(private = "file")
clock_tick :: proc(a: ^App) -> int {
	m := CK(a)
	if m.tab == .Watch && m.sw_run do return 100
	if m.ring_kind != "" || ck_done(m) >= 0 do return 250
	return 1000 - int(time.to_unix_nanoseconds(time.now()) / 1_000_000 % 1000) + 5
}

// ---------- drawing ----------

@(private = "file")
Ck_Chip :: struct { name: string, secs: int, label: string }

@(private = "file")
ck_chips :: proc() -> []Ck_Chip {
	@(static) chips := [5]Ck_Chip{{"3 min", 180, "Eggs"}, {"5 min", 300, ""}, {"10 min", 600, ""}, {"25 min", 1500, "Focus"}, {"1 h", 3600, ""}}
	return chips[:]
}

// A ring (a timer's): what has gone in c from the top, clockwise, the rest the track.
@(private = "file")
ck_ring :: proc(cv: ^Canvas, cx, cy, ro, ri: f32, frac: f32, c, track: u32) {
	x0, x1 := max(int(cx - ro) - 1, 0), min(int(cx + ro) + 2, cv.w)
	y0, y1 := max(int(cy - ro) - 1, 0), min(int(cy + ro) + 2, cv.h)
	for y in y0 ..< y1 do for x in x0 ..< x1 {
		dx, dy := f32(x) + 0.5 - cx, f32(y) + 0.5 - cy
		d := math.sqrt(dx * dx + dy * dy)
		cov := clamp(ro - d + 0.5, 0, 1) * clamp(d - ri + 0.5, 0, 1)
		if cov <= 0 do continue
		ang := math.atan2(dx, -dy) / (2 * math.PI)
		if ang < 0 do ang += 1
		col := ang <= frac ? c : track
		blend(&cv.px[y * cv.w + x], argb(col, 0xff), cov)
	}
}

@(private = "file")
clock_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := CK(a)
	H := panel_ground(a, cv)
	tn := msg_tones(a, H)
	w := cv.w
	now := ck_now()
	lt, _, _ := ck_local(m)
	done := ck_done(m)
	ring_c: u32 = 0
	if m.ring_kind == "alarm" do ring_c = H.acc
	else if done >= 0 || m.ring_kind == "timer" do ring_c = tn.yellow
	blink := u8(ring_c != 0 && int(now * 2) % 2 == 1 ? 0x5a : 0xff)
	// the head: CLOCK › TAB, the time, the date
	hh := 40 * S
	names := [4]string{"WORLD", "TIMERS", "ALARMS", "STOPWATCH"}
	crumb := fmt.tprintf("CLOCK › %s", names[m.tab])
	cw := tw(m.f11b, crumb) + 12 * S
	px := 14 * S
	fill_rect(cv, px, (hh - 19 * S) / 2, cw, 19 * S, argb(H.acc, 0xff))
	text_in(cv, m.f11b, crumb, px + 6 * S, (hh - 19 * S) / 2, 19 * S, argb(H.bg, 0xff))
	sub := m.popup ? ck_date(m) : fmt.tprintf("%s · %s · %s · w%s", ck_date(m), m.home, m.zone, m.week)
	sx := w - px - tw(m.f10, sub)
	text_in(cv, m.f10, sub, sx, 0, hh, argb(H.dim, 0xff))
	nowl := fmt.tprintf("%s:%02d", ck_hm(lt), lt % 60)
	text_in(cv, m.f15b, nowl, sx - 10 * S - tw(m.f15b, nowl), 0, hh, argb(H.fg, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	y := hh + S
	// the tabs
	th := 34 * S
	tx := 10 * S
	labels := [4]string{"World", "Timers", "Alarms", "Stopwatch"}
	run := 0
	for x in m.timers do if x.end > 0 && x.done == 0 do run += 1
	on_al := 0
	for x in m.alarms do if x.on do on_al += 1
	counts := [4]string{fmt.tprint(len(m.cities)), len(m.timers) > 0 ? fmt.tprint(len(m.timers)) : "", fmt.tprint(on_al), m.sw_run ? "●" : ""}
	for l, i in labels {
		on := int(m.tab) == i
		hot := (i == 1 && done >= 0) || (i == 2 && m.ring_kind == "alarm")
		kl := m.popup ? "" : fmt.tprintf("Alt+%d", i + 1)
		n := m.popup && !hot ? "" : counts[i]
		tp := (m.popup ? 8 : 12) * S
		nw := n != "" ? tw(m.f10, n) + 8 * S : 0
		tbw := tp * 2 + (kl != "" ? tw(m.f9, kl) + 6 * S : 0) + tw(m.f11b, l) + (nw > 0 ? nw + 6 * S : 0)
		if on {
			fill_rect(cv, tx, y, tbw, th, argb(H.acc, 0x0f))
			fill_rect(cv, tx, y + th - 2 * S, tbw, 2 * S, argb(H.acc, 0xff))
		}
		hit_add(a, tx, y, tbw, th, .Tab, i, 0)
		lx := tx + tp
		if kl != "" { text_in(cv, m.f9, kl, lx, y, th, argb(on ? H.acc : H.faint, 0xff)); lx += tw(m.f9, kl) + 6 * S }
		text_in(cv, m.f11b, l, lx, y, th, argb(on ? H.fg : H.dim, 0xff))
		lx += tw(m.f11b, l) + 6 * S
		if nw > 0 {
			nc := hot ? (m.ring_kind == "alarm" ? H.acc : tn.yellow) : 0
			by := y + (th - 15 * S) / 2
			if hot do fill_rect(cv, lx, by, nw, 15 * S, argb(nc, blink))
			rounded_rect(cv, lx, by, nw, 15 * S, 0, 0, f32(S), argb(hot ? nc : (on ? mix(H.bg, H.acc, 0.6) : H.line), 0xff))
			text_in(cv, m.f10, n, lx + 4 * S, by, 15 * S, argb(hot ? H.bg : (on ? H.acc : H.dim), 0xff))
		}
		tx += tbw + 2 * S
	}
	fill_rect(cv, 0, y + th - S, w, S, argb(H.line, 0xff))
	y += th
	// the foot
	hints: [][2]string
	switch {
	case m.field: hints = msg_keys({"↵", m.tab == .World ? "Add" : (m.tab == .Alarms ? "Set" : "Start")}, {"↓", "List"}, {"Tab", "Next tab"}, {"Esc", len(m.q) > 0 ? "Clear" : "List"})
	case m.tab == .World: hints = msg_keys({"↑↓", "City"}, {"← →", "Compare hours"}, {"↵", m.cmp_on ? "Make event" : "Copy time"}, {"Del", "Remove"}, {"type", "Add city"})
	case m.tab == .Timers: hints = msg_keys({"↑↓", "Timer"}, {"␣", "Pause"}, {"+ −", "1 min"}, {"Del", "Remove"}, {"type", "New"})
	case m.tab == .Alarms: hints = msg_keys({"↑↓", "Alarm"}, {"␣", "On / off"}, {"Del", "Delete"}, {"type", "New"})
	case: hints = msg_keys({"␣", m.sw_run ? "Stop" : "Start"}, {"l", "Lap"}, {"r", "Reset"}, {"Tab", "Next tab"})
	}
	if ring_c != 0 {
		all := make([dynamic][2]string, 0, 6, context.temp_allocator)
		append(&all, [2]string{"Esc", "Stop"}, m.ring_kind == "alarm" ? [2]string{"s", "Snooze"} : [2]string{"+", "+1 min"})
		for h in hints[:min(3, len(hints))] do append(&all, h)
		hints = all[:]
	}
	if m.popup && len(hints) > 4 do hints = hints[:4]
	fy := panel_foot(a, cv, S, H, hints, false)
	// the banner: an alarm ringing, a timer done
	if ring_c != 0 {
		bx, bw := 12 * S, w - 24 * S
		by := y + 10 * S
		bh := 54 * S
		fill_rect(cv, bx, by, bw, bh, argb(ring_c, 0x14))
		rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(ring_c, 0xff))
		fill_rect(cv, bx, by, 4 * S, bh, argb(ring_c, 0xff))
		big, title, sub_: string
		if m.ring_kind == "alarm" {
			big, title, sub_ = m.ring_at, fmt.tprintf("%s · ringing", m.ring_label), "louder over 30 s · stops by itself after 10 min"
		} else {
			lab := m.ring_label
			if lab == "" && done >= 0 do lab = m.timers[done].label != "" ? m.timers[done].label : "Timer"
			since := m.ring_since > 0 ? m.ring_since : (done >= 0 ? m.timers[done].done : now)
			big, title, sub_ = "0:00", fmt.tprintf("%s · done", lab), fmt.tprintf("rang at %s · ringing on all outputs", ck_hm(i64(since) + m.home_off))
		}
		bigf := m.popup ? m.f20b : m.f26b
		text_in(cv, bigf, big, bx + 14 * S, by, bh, argb(ring_c, blink))
		lx := bx + 14 * S + tw(bigf, big) + 14 * S
		// the buttons, right to left
		rx := bx + bw - 14 * S
		stop_w := panel_btn_w(a, S, "Stop", "Esc")
		rx -= stop_w
		panel_btn(a, cv, S, rx, by + (bh - 30 * S) / 2, 30 * S, H, "Stop", "Esc", .Plain, 11)
		b1 := m.ring_kind == "alarm" ? "Snooze 9 min" : "+1 min"
		k1 := m.ring_kind == "alarm" ? "s" : "+"
		b1w := panel_btn_w(a, S, b1, k1)
		rx -= b1w + 8 * S
		if m.ring_kind == "alarm" do panel_btn(a, cv, S, rx, by + (bh - 30 * S) / 2, 30 * S, H, b1, k1, .Prime, 10)
		else {
			fill_rect(cv, rx, by + (bh - 30 * S) / 2, b1w, 30 * S, argb(tn.yellow, 0xff))
			text_in(cv, m.f10b, b1, rx + 8 * S, by + (bh - 30 * S) / 2, 30 * S, argb(H.bg, 0xff))
			text_in(cv, m.f10, k1, rx + 8 * S + tw(m.f10b, b1) + 6 * S, by + (bh - 30 * S) / 2, 30 * S, argb(H.bg, 0xff))
			hit_add(a, rx, by + (bh - 30 * S) / 2, b1w, 30 * S, .Chip, 10, 0)
		}
		tw_ := rx - 12 * S - lx
		text_in(cv, m.f13b, ellipsize(m.f13b, title, tw_), lx, by + 10 * S, 18 * S, argb(H.fg, 0xff))
		text_in(cv, m.f10, ellipsize(m.f10, sub_, tw_), lx, by + 29 * S, 14 * S, argb(tn.soft, 0xff))
		y = by + bh
	}
	// the field (and the timers' chips)
	if m.tab != .Watch {
		fx, fw := 12 * S, w - 24 * S
		fyy := y + 10 * S
		fh := 36 * S
		fill_rect(cv, fx, fyy, fw, fh, argb(H.panel, 0xff))
		rounded_rect(cv, fx, fyy, fw, fh, 0, 0, f32(S), argb(m.field ? mix(H.bg, H.acc, 0.5) : H.line, 0xff))
		fill_rect(cv, fx, fyy, 3 * S, fh, argb(H.acc, 0xff))
		text_in(cv, m.f13b, "›", fx + 10 * S, fyy, fh, argb(H.acc, 0xff))
		qx := fx + 10 * S + tw(m.f13b, "›") + 8 * S
		q := string(m.q[:])
		ph, pl := "", ""
		pc := H.dim
		switch m.tab {
		case .World:
			ph = "Add a city…"
			if i := ck_zone_hit(m); i >= 0 { pl, pc = fmt.tprintf("↵ add %s · %s", m.zones[i].name, ck_hm(lt - m.home_off + m.zones[i].off)), H.acc }
			else if strings.trim_space(q) != "" do pl = "no city found"
		case .Timers:
			ph = m.popup ? "10m, 1h30 bread…" : "New timer · “10m”, “1h30 bread”, “90s eggs”"
			if s, l, ok := clock_parse_dur(q); ok { pl, pc = fmt.tprintf("↵ start %s%s", clock_dur(f64(s)), l != "" ? fmt.tprintf(" · %s", l) : ""), H.acc }
			else if strings.trim_space(q) != "" do pl = "try 10m or 1h30"
		case .Alarms:
			ph = m.popup ? "7:30 weekdays…" : "New alarm · “7:30”, “6:45 weekdays gym”, “9 weekends”"
			if h, mi, days, rep, _, ok := clock_parse_alarm(q); ok {
				_, _, wd := ck_local(m)
				in_ := clock_alarm_in(h, mi, days, wd, (lt % 86400 + 86400) % 86400)
				pl, pc = fmt.tprintf("↵ set %02d:%02d · %s · %s", h, mi, rep, clock_in_words(in_)), H.acc
			} else if strings.trim_space(q) != "" do pl = "try 7:30 or 6:45 weekdays"
		case .Watch:
		}
		plw := pl != "" ? tw(m.f10, pl) : 0
		if pl != "" do text_in(cv, m.f10, pl, fx + fw - 10 * S - plw, fyy, fh, argb(pc, 0xff))
		if q == "" do text_in(cv, m.f12, ellipsize(m.f12, ph, fw - (qx - fx) - 20 * S - plw), qx, fyy, fh, argb(H.faint, 0xff))
		qt := ellipsize(m.f12, q, fw - (qx - fx) - 20 * S - plw)
		text_in(cv, m.f12, qt, qx, fyy, fh, argb(H.fg, 0xff))
		if m.field do fill_rect(cv, qx + (q != "" ? tw(m.f12, qt) + S : 0), fyy + 10 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
		hit_add(a, fx, fyy, fw, fh, .Chip, 9, 0)
		y = fyy + fh
		if m.tab == .Timers {
			cx := fx
			cy := y + 6 * S
			for ch, i in ck_chips()[:m.popup ? 4 : 5] {
				ww := tw(m.f10, ch.name) + 16 * S
				panel_dashed(cv, cx, cy, ww, 22 * S, S, argb(H.faint, 0xff))
				text_in(cv, m.f10, ch.name, cx + 8 * S, cy, 22 * S, argb(tn.soft, 0xff))
				hit_add(a, cx, cy, ww, 22 * S, .Chip, i, 0)
				cx += ww + 6 * S
			}
			y = cy + 22 * S
		}
	}
	body := [4]int{0, y + 8 * S, w, fy - y - 16 * S}
	switch m.tab {
	case .World: ck_draw_world(a, cv, S, H, body)
	case .Timers: ck_draw_timers(a, cv, S, H, body)
	case .Alarms: ck_draw_alarms(a, cv, S, H, body)
	case .Watch: ck_draw_watch(a, cv, S, H, body)
	}
	frame(cv, 0, 0, w, cv.h, S, argb(H.line, 0xff), argb(ring_c != 0 ? ring_c : H.acc, 0xff), 24)
}

// The cities: name, a strip of hours, the time there.
@(private = "file")
ck_draw_world :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: [4]int) {
	m := CK(a)
	tn := msg_tones(a, H)
	lt, _, _ := ck_local(m)
	utc := lt - m.home_off
	cityw, timew := (m.popup ? 118 : 170) * S, (m.popup ? 78 : 110) * S
	px := 14 * S
	nh := m.popup ? 12 : 24
	home_h := int((lt / 3600 % 24 + 24) % 24)
	start := home_h - (m.popup ? 3 : 6)
	sx0 := r[0] + px + cityw
	sw := r[2] - 2 * px - cityw - timew
	y := r[1]
	// the axis
	text_in(cv, m.f9, "earlier", sx0, y, 12 * S, argb(H.faint, 0xff))
	mid := fmt.tprintf("now · %s", ck_hm(lt))
	text_in(cv, m.f9, mid, sx0 + (sw - tw(m.f9, mid)) / 2, y, 12 * S, argb(H.faint, 0xff))
	text_in(cv, m.f9, "later", sx0 + sw - tw(m.f9, "later"), y, 12 * S, argb(H.faint, 0xff))
	y += 16 * S
	rh := (m.popup ? 50 : 54) * S
	late_c := mix(H.bg, 0x000000, 0.3)
	for c, i in m.cities {
		if y + rh > r[1] + r[3] - 40 * S do break
		on := i == m.sel && !m.field
		if on {
			fill_rect(cv, r[0], y, r[2], rh, argb(H.acc, 0x14))
			fill_rect(cv, r[0], y, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, r[0], y, r[2], rh)
		}
		hit_add(a, r[0], y, r[2], rh, .Row, i, 0)
		off := c.off - m.home_off
		loc := utc + c.off
		lh := int((loc / 3600 % 24 + 24) % 24)
		night := lh < 6 || lh >= 21
		// the name and where
		nx := r[0] + px
		name := ellipsize(m.f13b, c.name, cityw - 10 * S - (c.home && !m.popup ? 40 * S : 0))
		text_in(cv, m.f13b, name, nx, y + 10 * S, 17 * S, argb(H.fg, 0xff))
		if c.home && !m.popup {
			hx := nx + tw(m.f13b, name) + 6 * S
			rounded_rect(cv, hx, y + 12 * S, tw(m.f9b, "HERE") + 8 * S, 13 * S, 0, 0, f32(S), argb(mix(H.bg, H.acc, 0.4), 0xff))
			text_in(cv, m.f9b, "HERE", hx + 4 * S, y + 12 * S, 13 * S, argb(H.acc, 0xff))
		}
		rl := ck_rel(off, c.home)
		sub := m.popup ? rl : (c.country != "" ? fmt.tprintf("%s · %s", c.country, rl) : rl)
		sc := H.dim
		if c.dst != "" && on && !m.popup { sub, sc = fmt.tprintf("%s · %s", rl, c.dst), tn.yellow }
		text_in(cv, m.f10, ellipsize(m.f10, sub, cityw - 10 * S), nx, y + 29 * S, 14 * S, argb(sc, 0xff))
		// the strip
		cellw := f32(sw - (nh - 1) * S) / f32(nh)
		sy := y + (rh - 22 * S) / 2
		for j in 0 ..< nh {
			hh := ((start + j + int(off / 3600)) % 24 + 24) % 24
			if off % 3600 != 0 do hh = int(((i64(start + j) * 3600 + off) / 3600 % 24 + 24) % 24)
			work, late := hh >= 8 && hh < 18, hh < 7 || hh >= 22
			is_now := start + j == home_h
			is_cmp := m.cmp_on && start + j == home_h + m.cmp
			cx := sx0 + int(f32(j) * (cellw + f32(S)))
			cwid := int(f32(j + 1) * (cellw + f32(S))) - int(f32(j) * (cellw + f32(S))) - S
			col := H.line
			alpha: u8 = 0xff
			switch {
			case is_cmp: col = H.acc
			case is_now: col, alpha = H.acc, 0x80
			case work: col, alpha = tn.green, 0x48
			case late: col = late_c
			}
			fill_rect(cv, cx, sy, cwid, 22 * S, argb(col, alpha))
			if is_cmp || j % 3 == 0 {
				t := ck_pad(hh)
				fc := is_cmp ? H.bg : (work ? tn.soft : H.faint)
				text_in(cv, m.f8, t, cx + (cwid - tw(m.f8, t)) / 2, sy, 22 * S, argb(fc, 0xff))
			}
		}
		// the time there
		tx := r[0] + r[2] - px
		tf := m.popup ? m.f15b : m.f20b
		tt := ck_hm(loc)
		text_in(cv, tf, tt, tx - tw(tf, tt), y + 7 * S, 24 * S, argb(night ? tn.soft : H.fg, 0xff))
		dd := (loc >= 0 ? loc / 86400 : (loc - 86399) / 86400) - (lt >= 0 ? lt / 86400 : (lt - 86399) / 86400)
		day := dd > 0 ? "tomorrow" : (dd < 0 ? "yesterday" : "today")
		dl := fmt.tprintf("%s %s", night ? "☾" : "☀", day)
		text_in(cv, m.f10, dl, tx - tw(m.f10, dl), y + 32 * S, 14 * S, argb(dd != 0 ? tn.yellow : H.dim, 0xff))
		y += rh
	}
	// the note: how to compare, or what the cursor says
	note := "Green is 08–18 where the city is. ← → move a cursor through the hours to compare; ↵ on a city copies its time."
	nc := H.dim
	if m.cmp_on {
		at := home_h + m.cmp
		parts := make([dynamic]string, 0, 4, context.temp_allocator)
		for c in m.cities {
			if c.home do continue
			if len(parts) >= (m.popup ? 2 : 4) do break
			hh := (((i64(at) * 3600 + c.off - m.home_off) / 3600) % 24 + 24) % 24
			append(&parts, fmt.tprintf("%s %02d:00", c.name, hh))
		}
		note = fmt.tprintf("At %02d:00 here (%s%d h): %s.  ↵ makes a calendar event at that time.", (at % 24 + 24) % 24, m.cmp >= 0 ? "+" : "", m.cmp, strings.join(parts[:], " · ", context.temp_allocator))
		nc = tn.soft
	}
	lines := wrap_text(m.f11, note, r[2] - 2 * px - 20 * S)
	nh_ := len(lines) * 17 * S + 16 * S
	ny := y + 10 * S
	panel_dashed(cv, r[0] + px, ny, r[2] - 2 * px, nh_, S, argb(H.faint, 0xff))
	for l, i in lines do text_in(cv, m.f11, l, r[0] + px + 10 * S, ny + 8 * S + i * 17 * S, 17 * S, argb(nc, 0xff))
}

// The timers: a card each, the newest first.
@(private = "file")
ck_draw_timers :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: [4]int) {
	m := CK(a)
	tn := msg_tones(a, H)
	now := ck_now()
	if len(m.timers) == 0 {
		lines := wrap_text(m.f12, "No timers. Type “10m”, “1h30 bread” or “25m focus” and press ↵, or pick a chip.", r[2] - 36 * S)
		for l, i in lines do text_in(cv, m.f12, l, r[0] + 18 * S, r[1] + 22 * S + i * 19 * S, 19 * S, argb(H.dim, 0xff))
		return
	}
	y := r[1]
	ch := 78 * S
	first := 0
	for (m.sel - first + 1) * (ch + 8 * S) > r[3] && first < m.sel do first += 1
	blink := u8(int(now * 2) % 2 == 1 ? 0x5a : 0xff)
	for i in first ..< len(m.timers) {
		x := m.timers[i]
		if y + ch > r[1] + r[3] do break
		left := ck_left(x)
		is_done := x.done > 0 || (x.end > 0 && left <= 0)
		on := i == m.sel && !m.field
		running := x.end > 0 && !is_done
		cx, cw := r[0] + 12 * S, r[2] - 24 * S
		bg := is_done ? mix(H.bg, tn.yellow, 0.07) : (on ? mix(H.bg, H.acc, 0.07) : H.panel)
		bd := is_done ? tn.yellow : (on ? mix(H.bg, H.acc, 0.6) : H.line)
		fill_rect(cv, cx, y, cw, ch, argb(bg, 0xff))
		rounded_rect(cv, cx, y, cw, ch, 0, 0, f32(S), argb(bd, 0xff))
		if is_done || on do fill_rect(cv, cx, y, 3 * S, ch, argb(is_done ? tn.yellow : H.acc, 0xff))
		if on do mark_sel(a, cx, y, cw, ch)
		hit_add(a, cx, y, cw, ch, .Row, i, 0)
		rc := is_done ? tn.yellow : (running ? H.acc : H.dim)
		frac := is_done ? 1 : 1 - f32(left / max(x.total, 1))
		rcx, rcy := f32(cx + 14 * S + 26 * S), f32(y + ch / 2)
		ck_ring(cv, rcx, rcy, f32(26 * S), f32(21 * S), frac, rc, H.line)
		glyph := is_done ? "!" : (running ? "▶" : "❚❚")
		text_in(cv, m.f13, glyph, int(rcx) - tw(m.f13, glyph) / 2, int(rcy) - 10 * S, 20 * S, argb(rc, 0xff))
		tx := cx + 14 * S + 52 * S + 16 * S
		bigf := m.popup ? m.f22b : m.f28b
		lc := is_done ? tn.yellow : (running ? H.fg : tn.soft)
		text_in(cv, bigf, is_done ? "0:00" : clock_dur(left), tx, y + 12 * S, 32 * S, argb(lc, is_done ? blink : 0xff))
		label := x.label != "" ? x.label : fmt.tprintf("%s timer", clock_dur(x.total))
		// the state, at the right
		st := is_done ? "DONE · ringing" : (running ? "running" : "paused")
		stc := is_done ? tn.yellow : (running ? tn.green : H.dim)
		ends := is_done ? fmt.tprintf("ended %s", ck_hm(i64(x.done > 0 ? x.done : x.end) + m.home_off)) : (running ? fmt.tprintf("ends %s", ck_hm(i64(x.end) + m.home_off)) : fmt.tprintf("%s total", clock_dur(x.total)))
		rx := cx + cw - 14 * S
		text_in(cv, m.f10b, st, rx - tw(m.f10b, st), y + 22 * S, 14 * S, argb(stc, 0xff))
		text_in(cv, m.f10, ends, rx - tw(m.f10, ends), y + 40 * S, 14 * S, argb(H.dim, 0xff))
		text_in(cv, m.f11, ellipsize(m.f11, label, rx - max(tw(m.f10b, st), tw(m.f10, ends)) - 16 * S - tx), tx, y + 47 * S, 16 * S, argb(tn.soft, 0xff))
		y += ch + 8 * S
	}
}

// The alarms: the time, the name and days, when next, the switch.
@(private = "file")
ck_draw_alarms :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: [4]int) {
	m := CK(a)
	tn := msg_tones(a, H)
	now := i64(ck_now())
	if len(m.alarms) == 0 {
		text_in(cv, m.f12, "No alarms. Type “7:30” or “6:45 weekdays gym” and press ↵.", r[0] + 18 * S, r[1] + 22 * S, 19 * S, argb(H.dim, 0xff))
		return
	}
	soonest := -1
	for x, i in m.alarms do if x.on && x.next > 0 && (soonest < 0 || x.next < m.alarms[soonest].next) do soonest = i
	lt, day, wd := ck_local(m)
	_ = lt
	y := r[1]
	rh := 62 * S
	first := 0
	for (m.sel - first + 1) * rh > r[3] && first < m.sel do first += 1
	dl := [7]string{"M", "T", "W", "T", "F", "S", "S"}
	wdn := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	for i in first ..< len(m.alarms) {
		x := m.alarms[i]
		if y + rh > r[1] + r[3] do break
		on := i == m.sel && !m.field
		if on {
			fill_rect(cv, r[0], y, r[2], rh, argb(H.acc, 0x12))
			fill_rect(cv, r[0], y, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, r[0], y, r[2], rh)
		}
		fill_rect(cv, r[0], y + rh - S, r[2], S, argb(H.line, 0x66))
		hit_add(a, r[0], y, r[2], rh, .Row, i, 0)
		px := r[0] + 14 * S
		tf := m.popup ? m.f20b : m.f26b
		t := fmt.tprintf("%02d:%02d", x.h, x.m)
		text_in(cv, tf, t, px, y, rh, argb(x.on ? H.fg : H.faint, 0xff))
		lx := px + (m.popup ? 70 : 96) * S + 14 * S
		// the right: the switch, when next
		rx := r[0] + r[2] - 14 * S
		sx := rx - 34 * S
		sy := y + (rh - 18 * S) / 2
		if x.on do fill_rect(cv, sx, sy, 34 * S, 18 * S, argb(H.acc, 0x26))
		rounded_rect(cv, sx, sy, 34 * S, 18 * S, 0, 0, f32(S), argb(x.on ? H.acc : H.faint, 0xff))
		fill_rect(cv, x.on ? sx + 34 * S - 15 * S : sx + 3 * S, sy + 3 * S, 12 * S, 12 * S, argb(x.on ? H.acc : H.faint, 0xff))
		next := "off"
		if x.on && x.next > 0 {
			nd := (x.next + m.home_off) / 86400 - day
			w := int((i64(wd) + nd) % 7)
			pre := nd == 0 ? "today" : (nd == 1 ? "tomorrow" : wdn[w])
			next = fmt.tprintf("%s · %s", pre, clock_in_words(x.next - now))
		}
		nw := tw(m.f10, next)
		if !m.popup || !x.on do text_in(cv, m.f10, next, sx - 14 * S - nw, y, rh, argb(i == soonest ? H.acc : H.dim, 0xff))
		else { next = clock_in_words(x.next - now); nw = tw(m.f10, next); text_in(cv, m.f10, next, sx - 14 * S - nw, y, rh, argb(i == soonest ? H.acc : H.dim, 0xff)) }
		lw := sx - 28 * S - nw - lx
		text_in(cv, m.f12b, ellipsize(m.f12b, x.label != "" ? x.label : "Alarm", lw), lx, y + 12 * S, 17 * S, argb(x.on ? tn.soft : H.dim, 0xff))
		dx := lx
		dy := y + 35 * S
		for d in 0 ..< 7 {
			set := d < len(x.days) && x.days[d] == '1'
			fg := set ? (x.on ? H.bg : H.dim) : H.faint
			if set do fill_rect(cv, dx, dy, 16 * S, 16 * S, argb(x.on ? H.acc : H.line, 0xff))
			rounded_rect(cv, dx, dy, 16 * S, 16 * S, 0, 0, f32(S), argb(set && x.on ? H.acc : H.line, 0xff))
			text_in(cv, m.f9b, dl[d], dx + (16 * S - tw(m.f9b, dl[d])) / 2, dy, 16 * S, argb(fg, 0xff))
			dx += 19 * S
		}
		rep := "some days"
		switch x.days {
		case "1111111": rep = "every day"
		case "1111100": rep = "weekdays"
		case "0000011": rep = "weekends"
		case "0000000", "": rep = "once"
		}
		text_in(cv, m.f10, rep, dx + 3 * S, dy, 16 * S, argb(H.dim, 0xff))
		y += rh
	}
}

// The stopwatch: big digits, then the laps (the newest first).
@(private = "file")
ck_draw_watch :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: [4]int) {
	m := CK(a)
	tn := msg_tones(a, H)
	el := m.sw_base + (m.sw_run ? ck_now() - m.sw_t0 : 0)
	main_, cs := ck_sw(el)
	bf, sf := m.popup ? m.f40b : m.f58b, m.popup ? m.f22b : m.f30b
	mc := m.sw_run ? H.fg : (el > 0 ? tn.soft : H.faint)
	cc := m.sw_run ? H.acc : H.dim
	tot := tw(bf, main_) + tw(sf, cs)
	y := r[1] + 18 * S
	bh := (m.popup ? 44 : 62) * S
	x := r[0] + (r[2] - tot) / 2
	text_in(cv, bf, main_, x, y, bh, argb(mc, 0xff))
	text_in(cv, sf, cs, x + tw(bf, main_), y + (bh - int(sf.line_h)) / 2 + (m.popup ? 6 : 9) * S, int(sf.line_h), argb(cc, 0xff))
	y += bh + 4 * S
	sub := m.sw_run ? "running · keeps going when the window closes · the bar shows it" : (el > 0 ? "stopped · Space resumes, r resets" : "Space starts")
	sub = ellipsize(m.f11, sub, r[2] - 32 * S)
	text_in(cv, m.f11, sub, r[0] + (r[2] - tw(m.f11, sub)) / 2, y, 16 * S, argb(H.dim, 0xff))
	y += 16 * S + 14 * S
	px := r[0] + 16 * S
	rx := r[0] + r[2] - 16 * S
	spaced(cv, m.f9, "LAP", px, y, 14 * S, H.faint, S)
	spaced(cv, m.f9, "SPLIT", px + 60 * S, y, 14 * S, H.faint, S)
	spaced(cv, m.f9, "TOTAL", rx - spaced_w(m.f9, "TOTAL", S), y, 14 * S, H.faint, S)
	y += 18 * S
	best, worst := -1, -1
	if len(m.laps) > 1 do for l, i in m.laps {
		if best < 0 || l < m.laps[best] do best = i
		if worst < 0 || l > m.laps[worst] do worst = i
	}
	row :: proc(cv: ^Canvas, m: ^Clock, S, px, rx, y: int, H: HUD, n, split, total, tag: string, c: u32, soft: u32) {
		fill_rect(cv, px - 16 * S, y, rx - px + 32 * S, S, argb(H.line, 0x66))
		text_in(cv, m.f12, n, px, y, 28 * S, argb(H.dim, 0xff))
		text_in(cv, m.f12b, split, px + 60 * S, y, 28 * S, argb(c, 0xff))
		if tag != "" do spaced(cv, m.f9b, tag, px + 60 * S + tw(m.f12b, split) + 10 * S, y + 8 * S, 12 * S, c, S)
		text_in(cv, m.f12, total, rx - tw(m.f12, total), y, 28 * S, argb(soft, 0xff))
	}
	sum := 0.0
	for l in m.laps do sum += l
	strip :: proc(s: string) -> string { return strings.has_prefix(s, "00:") ? s[3:] : s }
	if len(m.laps) > 0 || el > 0 {
		a1, b1 := ck_sw(el - sum)
		t1, t2 := ck_sw(el)
		row(cv, m, S, px, rx, y, H, fmt.tprint(len(m.laps) + 1), strip(strings.concatenate({a1, b1}, context.temp_allocator)), strings.concatenate({t1, t2}, context.temp_allocator), m.sw_run ? "NOW" : "", m.sw_run ? H.acc : tn.soft, tn.soft)
		y += 28 * S
	}
	acc := make([]f64, len(m.laps), context.temp_allocator)
	s := 0.0
	for l, i in m.laps { s += l; acc[i] = s }
	#reverse for l, i in m.laps {
		if y + 28 * S > r[1] + r[3] do break
		a1, b1 := ck_sw(l)
		t1, t2 := ck_sw(acc[i])
		c := i == best ? tn.green : (i == worst ? tn.red : H.fg)
		row(cv, m, S, px, rx, y, H, fmt.tprint(i + 1), strip(strings.concatenate({a1, b1}, context.temp_allocator)), strings.concatenate({t1, t2}, context.temp_allocator), i == best ? "BEST" : (i == worst ? "SLOWEST" : ""), c, tn.soft)
		y += 28 * S
	}
}

clock_dump :: proc(a: ^App) -> string {
	m := CK(a)
	sb := strings.builder_make(context.temp_allocator)
	lt, _, _ := ck_local(m)
	now := ck_now()
	fmt.sbprintfln(&sb, "clock %v · %s · %s", m.tab, ck_hm(lt), ck_date(m))
	if m.ring_kind != "" do fmt.sbprintfln(&sb, "ringing %s %s", m.ring_kind, m.ring_label)
	else if d := ck_done(m); d >= 0 do fmt.sbprintfln(&sb, "ringing timer %s", m.timers[d].label)
	if len(m.q) > 0 do fmt.sbprintfln(&sb, "%sfield %s", m.field ? "* " : "", string(m.q[:]))
	switch m.tab {
	case .World:
		for c, i in m.cities do fmt.sbprintfln(&sb, "%s %s %s · %s%s", i == m.sel && !m.field ? "*" : " ", c.name, ck_hm(lt - m.home_off + c.off), ck_rel(c.off - m.home_off, c.home), c.dst != "" ? fmt.tprintf(" · %s", c.dst) : "")
		if m.cmp_on do fmt.sbprintfln(&sb, "compare %+d h", m.cmp)
		if i := ck_zone_hit(m); i >= 0 && m.field do fmt.sbprintfln(&sb, "add %s", m.zones[i].name)
	case .Timers:
		for x, i in m.timers {
			left := ck_left(x)
			st := x.done > 0 ? "done" : (x.end > 0 ? "running" : "paused")
			fmt.sbprintfln(&sb, "%s %s %s · %s", i == m.sel && !m.field ? "*" : " ", x.done > 0 ? "0:00" : clock_dur(left), x.label != "" ? x.label : "timer", st)
		}
		if s, l, ok := clock_parse_dur(string(m.q[:])); ok do fmt.sbprintfln(&sb, "start %s %s", clock_dur(f64(s)), l)
	case .Alarms:
		for x, i in m.alarms do fmt.sbprintfln(&sb, "%s %02d:%02d %s · %s · %s", i == m.sel && !m.field ? "*" : " ", x.h, x.m, x.label != "" ? x.label : "Alarm", x.days, x.on ? clock_in_words(x.next - i64(now)) : "off")
		if h, mi, _, rep, l, ok := clock_parse_alarm(string(m.q[:])); ok do fmt.sbprintfln(&sb, "set %02d:%02d %s %s", h, mi, rep, l)
	case .Watch:
		el := m.sw_base + (m.sw_run ? now - m.sw_t0 : 0)
		a1, b1 := ck_sw(el)
		fmt.sbprintfln(&sb, "stopwatch %s%s %s · %d laps", a1, b1, m.sw_run ? "running" : "stopped", len(m.laps))
	}
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
