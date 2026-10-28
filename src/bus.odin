package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --bus: Bus departures (the Kestrel design's Bus popup, under the bar's bus module): 420×560,
// the next hour at one remembered stop, soonest first, the minutes counting down between loads.
// A row: the mode's glyph, the line in a box (accent for buses, yellow for trains, red when
// cancelled), the destination, the time (the planned one struck through when it moved) and the
// platform, and the minutes left with a tag under them (+3 late, timetable, next: 3 at 14:20).
// ↵ sets a reminder 5 min before it leaves, g groups by platform (direction where there are none), s picks another stop (typing
// searches, the last 5 when empty, ↵ uses it), r loads again, Esc closes. Without a Trafiklab key
// it asks for one (pasted here, kept in the keyring). The data comes from k4-bus (panel lines R
// and L, panel.odin), again every 30 s while open:
//   S <ok|nokey|badkey|nostop|offline> <stop id> <stop name> <fetched, unix> <fetched HH:MM>
//     <the first departure after the hour, e.g. "line 7 at 15:18">
//   D <line> <destination> <BUS|TRAIN|…> <scheduled HH:MM> <real-time HH:MM or -> <delay s>
//     <cancelled 1|0> <platform> <real-time 1|0> <leaves, unix>
//   F <stop id> <name> <modes, e.g. BUS,TRAIN> <departures an hour> <recent 1|0>
// The runner's verbs: search TEXT (prints k4:stop ID<TAB>NAME<TAB>MODES<TAB>PER HOUR lines),
// pick ID NAME, key ($K4_INPUT), refresh, remind LINE DESTINATION UNIX.
// K4_BUS_NOW=unix pins the clock (tests).

BUS_W, BUS_H :: 420, 560

Bus_Dep :: struct { line, dest, mode, sched, real, platform: string, delay: int, cancelled, live: bool, at: i64 }
Bus_Stop :: struct { id, name, modes, per_hour: string, recent: bool }
Bus_View :: enum { Departures, Pick, Key }

Bus :: struct {
	using pn: Panel,
	state, stop_id, stop_name, fetched_hm, next_after: string,
	fetched: i64,
	deps: [dynamic]Bus_Dep,
	stops: [dynamic]Bus_Stop, // the recent ones (F lines)
	found: [dynamic]Bus_Stop, // the search's answer
	view: Bus_View,
	chosen: bool, // the view was picked by a key, not by the state
	grouped: bool,
	cur: int,
	q: [dynamic]u8,
	search_at: time.Tick, // a search waits for typing to pause
	searching: bool,
}

bus_setup :: proc(a: ^App, data: string) {
	b := new(Bus)
	b.mode = {draw = bus_draw, key = bus_key, click = bus_click, scroll = bus_scroll, loaded = bus_loaded, ran = bus_ran, tick = bus_tick, dump = bus_dump}
	panel_init(a, &b.pn, "bus", data)
	b.refresh_ms = 30000
	a.width, a.height = BUS_W, BUS_H
}

@(private = "file")
B :: proc(a: ^App) -> ^Bus { return (^Bus)(a.pn) }

@(private = "file")
bus_now :: proc() -> i64 {
	if v, ok := strconv.parse_i64(os.get_env("K4_BUS_NOW", context.temp_allocator)); ok do return v
	return time.to_unix_seconds(time.now())
}

@(private = "file")
stop_free :: proc(l: ^[dynamic]Bus_Stop) {
	for &s in l { delete(s.id); delete(s.name); delete(s.modes); delete(s.per_hour) }
	clear(l)
}

@(private = "file")
bus_loaded :: proc(a: ^App, data: string) {
	b := B(a)
	for &d in b.deps { delete(d.line); delete(d.dest); delete(d.mode); delete(d.sched); delete(d.real); delete(d.platform) }
	clear(&b.deps)
	stop_free(&b.stops)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			for p in ([]^string{&b.state, &b.stop_id, &b.stop_name, &b.fetched_hm, &b.next_after}) do delete(p^)
			b.state, b.stop_id, b.stop_name = strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3))
			b.fetched, _ = strconv.parse_i64(fget(f, 4))
			b.fetched_hm, b.next_after = strings.clone(fget(f, 5)), strings.clone(fget(f, 6))
		case "D":
			d := Bus_Dep{line = strings.clone(fget(f, 1)), dest = strings.clone(fget(f, 2)), mode = strings.clone(fget(f, 3)), sched = strings.clone(fget(f, 4)), real = strings.clone(fget(f, 5)), platform = strings.clone(fget(f, 8))}
			d.delay, _ = strconv.parse_int(fget(f, 6))
			d.cancelled, d.live = fget(f, 7) == "1", fget(f, 9) == "1"
			d.at, _ = strconv.parse_i64(fget(f, 10))
			append(&b.deps, d)
		case "F": append(&b.stops, Bus_Stop{strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), fget(f, 5) == "1"})
		}
	}
	if b.state == "" do b.state = "nostop"
	if !b.chosen || b.state == "nokey" || b.state == "badkey" { // the state picks the view, unless a key did
		switch b.state {
		case "nokey", "badkey": b.view = .Key
		case "nostop": b.view = .Pick
		case: b.view = .Departures
		}
	}
	b.cur = clamp(b.cur, 0, max(bus_n(b) - 1, 0))
}

@(private = "file")
bus_ran :: proc(a: ^App, verb, line: string) -> bool {
	b := B(a)
	if !strings.has_prefix(line, "k4:stop ") do return false
	f := fields(line[8:])
	append(&b.found, Bus_Stop{strings.clone(fget(f, 0)), strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), false})
	return true
}

@(private = "file")
bus_tick :: proc(a: ^App) -> int {
	b := B(a)
	if b.searching && time.tick_diff(time.tick_now(), b.search_at) <= 0 {
		b.searching = false
		stop_free(&b.found)
		panel_say(&b.pn, "")
		if len(b.q) > 0 do panel_run(a, "search", string(b.q[:]))
	}
	if b.searching do return 100
	return b.view == .Departures ? 1000 : -1 // the minutes and "updated N s ago" move
}

// The group a departure belongs to with g: its platform, or its direction where the stop has no platforms.
@(private = "file")
bus_group :: proc(d: Bus_Dep) -> string { return d.platform != "" ? d.platform : strings.concatenate({"→ ", d.dest}, context.temp_allocator) }

// The departures in the order shown: soonest first, or by platform or direction (g).
@(private = "file")
bus_order :: proc(b: ^Bus) -> []int {
	out := make([dynamic]int, 0, len(b.deps), context.temp_allocator)
	if !b.grouped { for _, i in b.deps do append(&out, i); return out[:] }
	plats := make([dynamic]string, 0, 8, context.temp_allocator)
	for d in b.deps {
		seen := false
		for p in plats do if p == bus_group(d) do seen = true
		if !seen do append(&plats, bus_group(d))
	}
	for p in plats do for d, i in b.deps do if bus_group(d) == p do append(&out, i)
	return out[:]
}

@(private = "file")
bus_list :: proc(b: ^Bus) -> []Bus_Stop { return len(b.q) > 0 ? b.found[:] : b.stops[:] }
@(private = "file")
bus_n :: proc(b: ^Bus) -> int {
	switch b.view {
	case .Departures: return len(b.deps)
	case .Pick: return len(bus_list(b))
	case .Key: return 1
	}
	return 0
}

@(private = "file")
bus_pick_view :: proc(b: ^Bus) {
	b.view, b.chosen, b.cur = .Pick, true, 0
	clear(&b.q)
	panel_say(&b.pn, "")
}

// The next one of the same line that runs, after a cancelled one: "3 at 14:20".
@(private = "file")
bus_next_same :: proc(b: ^Bus, d: Bus_Dep) -> string {
	for x in b.deps do if x.line == d.line && !x.cancelled && x.at > d.at do return fmt.tprintf("%s at %s", x.line, x.real != "" && x.real != "-" ? x.real : x.sched)
	return ""
}

@(private = "file")
bus_enter :: proc(a: ^App) {
	b := B(a)
	switch b.view {
	case .Departures:
		o := bus_order(b)
		if b.cur >= len(o) do return
		d := b.deps[o[b.cur]]
		if d.cancelled {
			n := bus_next_same(b, d)
			panel_say(&b.pn, fmt.tprintf("Line %s at %s is cancelled%s", d.line, d.sched, n != "" ? fmt.tprintf(" · next %s", n) : ""), a.theme.red)
			return
		}
		panel_run(a, "remind", d.line, d.dest, fmt.tprint(d.at))
	case .Pick:
		l := bus_list(b)
		if b.cur >= len(l) { if len(b.q) == 0 do panel_say(&b.pn, "Type a stop’s name"); return }
		s := l[b.cur]
		b.view, b.chosen = .Departures, false
		clear(&b.q)
		panel_run(a, "pick", s.id, s.name)
	case .Key:
		if len(b.input) == 0 { panel_say(&b.pn, "Paste the key first", a.theme.yellow); return }
		panel_run(a, "key", secret = strings.clone(panel_text(&b.pn), context.temp_allocator))
		panel_clear(&b.pn)
	}
}

bus_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	b := B(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	switch b.view {
	case .Departures:
		switch {
		case k == .Down: b.cur = min(b.cur + 1, max(len(b.deps) - 1, 0))
		case k == .Up: b.cur = max(b.cur - 1, 0)
		case k == .Enter: bus_enter(a)
		case text == "s": bus_pick_view(b)
		case text == "g":
			b.grouped, b.cur = !b.grouped, 0
			panel_say(&b.pn, b.grouped ? "Grouped by platform or direction" : "Soonest first")
		case text == "r": panel_say(&b.pn, ""); panel_run(a, "refresh")
		case k == .Escape: panel_close(a)
		case: return false
		}
	case .Pick:
		switch {
		case k == .Down: b.cur = min(b.cur + 1, max(bus_n(b) - 1, 0))
		case k == .Up: b.cur = max(b.cur - 1, 0)
		case k == .Enter: bus_enter(a)
		case k == .Backspace:
			if len(b.q) > 0 { _, n := utf8.decode_last_rune(b.q[:]); resize(&b.q, len(b.q) - n); b.cur = 0; b.searching = len(b.q) > 0; b.search_at = time.tick_add(time.tick_now(), 400 * time.Millisecond) }
		case k == .Escape:
			if len(b.q) > 0 do clear(&b.q)
			else if b.stop_id != "" && b.state != "nostop" { b.view, b.chosen = .Departures, false }
			else do panel_close(a)
		case text != "" && k == .None && !ctrl:
			append(&b.q, ..transmute([]u8)text)
			b.cur = 0
			b.searching = true
			b.search_at = time.tick_add(time.tick_now(), 400 * time.Millisecond)
			if a.opts.dump || a.opts.dry_run != "" do b.search_at = time.tick_now() // tests: at once
			bus_tick(a)
		case: return false
		}
	case .Key:
		switch {
		case k == .Enter: bus_enter(a)
		case k == .Tab: b.pn.reveal = !b.pn.reveal
		case k == .Backspace: panel_bs(&b.pn)
		case k == .Escape: panel_close(a)
		case text != "" && k == .None && !ctrl: panel_type(&b.pn, text)
		case: return false
		}
	}
	return true
}

bus_scroll :: proc(a: ^App, n: int) -> bool { b := B(a); b.cur = clamp(b.cur + n, 0, max(bus_n(b) - 1, 0)); return true }

bus_click :: proc(a: ^App, x, y, button: int) -> bool {
	b := B(a)
	h, ok := hit_at(a, x, y)
	if !ok || h.kind != .Row do return false
	if h.a == b.cur do bus_enter(a)
	else do b.cur = h.a
	return true
}

@(private = "file")
bus_mins :: proc(d: Bus_Dep, now: i64) -> (s: string, m: int) {
	if d.at - now < 60 do return "nu", 0
	m = int((d.at - now + 59) / 60)
	return fmt.tprintf("%d min", m), m
}

@(private = "file")
bus_fade :: proc(c, bg: u32, f: bool) -> u32 { return f ? mix(c, bg, 0.4) : c }

// A row's frame: picked (a faint accent fill, an accent outline, a 3 px edge) or not.
@(private = "file")
bus_row :: proc(a: ^App, cv: ^Canvas, S, x0, y, w, h: int, H: HUD, on: bool) {
	if !on do return
	fill_rect(cv, x0, y, w, h, argb(H.acc, 0x12))
	rounded_rect(cv, x0, y, w, h, 0, 0, f32(S), argb(H.acc, 0xff))
	fill_rect(cv, x0, y, 3 * S, h, argb(H.acc, 0xff))
	mark_sel(a, x0, y, w, h)
}

bus_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	b := B(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	now := bus_now()
	crumb := b.view == .Pick ? "BUS › STOP" : "BUS"
	right, rc := "", H.dim
	switch b.view {
	case .Key: right = "Trafiklab"
	case .Pick:
	case .Departures:
		if b.state == "offline" do right, rc = "offline", th.yellow
		else if b.fetched > 0 do right = fmt.tprintf("updated %d s ago", max(now - b.fetched, 0))
	}
	title := b.view == .Key ? "Set up" : (b.view == .Departures ? b.stop_name : "")
	hh, px, tx := panel_head(a, cv, S, H, crumb, title, false, tw(b.f10, right))
	text_in(cv, b.f10, right, w - px - tw(b.f10, right), 0, hh, argb(rc, 0xff))
	if b.view == .Pick { // the search field in the head
		q := string(b.q[:])
		if q == "" do text_in(cv, b.f13, "Find a stop…", tx + 4 * S, 0, hh, argb(H.faint, 0xff))
		else do text_in(cv, b.f13, ellipsize(b.f13, q, w - px - tx - 10 * S), tx, 0, hh, argb(H.fg, 0xff))
		fill_rect(cv, tx + (q != "" ? tw(b.f13, q) + S : 0), (hh - 16 * S) / 2, 2 * S, 16 * S, argb(H.acc, 0xff))
	}
	y := hh + S
	fy := h - 30 * S
	x0, x1 := 8 * S, w - 8 * S
	switch b.view {
	case .Key: // the notice holds the steps and the field
		bad := b.state == "badkey"
		nc := bad ? H.hot : H.acc
		nx, nw := px, w - 2 * px
		lines: []string = bad ? {"The key is still not saved."} : {"1 · Sign in at developer.trafiklab.se (free).", "2 · Make a project and add “Trafiklab Realtime APIs”.", "3 · Copy its key and paste it below. It goes in the keyring, never in a file."}
		wrapped := make([dynamic]string, 0, 8, context.temp_allocator)
		for l in lines do for x in wrap_text(b.f11, l, nw - 24 * S) do append(&wrapped, x)
		err := bad ? wrap_text(b.f10, "Check that the project has “Trafiklab Realtime APIs” added, then paste the key again.", nw - 24 * S) : nil
		nh := 10 * S + int(b.f12b.line_h) + 6 * S + len(wrapped) * 16 * S + 6 * S + 30 * S + 6 * S + len(err) * 14 * S + (len(err) > 0 ? 4 * S : 0) + int(b.f10.line_h) + 10 * S
		ny := y + 10 * S
		fill_rect(cv, nx, ny, nw, nh, argb(nc, 0x0d))
		rounded_rect(cv, nx, ny, nw, nh, 0, 0, f32(S), argb(nc, 0xff))
		fill_rect(cv, nx, ny, 3 * S, nh, argb(nc, 0xff))
		yy := ny + 10 * S
		text_in(cv, b.f12b, bad ? "Trafiklab did not accept this key" : "Departures need a free Trafiklab key", nx + 12 * S, yy, int(b.f12b.line_h), argb(nc, 0xff))
		yy += int(b.f12b.line_h) + 6 * S
		for l in wrapped { text_in(cv, b.f11, l, nx + 12 * S, yy, 16 * S, argb(soft, 0xff)); yy += 16 * S }
		yy += 6 * S
		fw := nw - 24 * S
		fill_rect(cv, nx + 12 * S, yy, fw, 30 * S, argb(H.bg, 0xff))
		rounded_rect(cv, nx + 12 * S, yy, fw, 30 * S, 0, 0, f32(S), argb(nc, 0xff))
		k := panel_masked(&b.pn)
		ts := "Tab shows"
		if k == "" do text_in(cv, b.f12, "paste the key", nx + 22 * S, yy, 30 * S, argb(H.faint, 0xff))
		else do text_in(cv, b.f12, ellipsize(b.f12, k, fw - 30 * S - tw(b.f10, ts)), nx + 22 * S, yy, 30 * S, argb(H.fg, 0xff))
		fill_rect(cv, nx + 22 * S + (k != "" ? tw(b.f12, ellipsize(b.f12, k, fw - 30 * S - tw(b.f10, ts))) + 2 * S : 0), yy + 8 * S, 2 * S, 14 * S, argb(H.acc, 0xff))
		text_in(cv, b.f10, ts, nx + 12 * S + fw - 10 * S - tw(b.f10, ts), yy, 30 * S, argb(H.dim, 0xff))
		yy += 30 * S + 6 * S
		for l in err { text_in(cv, b.f10, l, nx + 12 * S, yy, 14 * S, argb(H.hot, 0xff)); yy += 14 * S }
		if len(err) > 0 do yy += 4 * S
		text_in(cv, b.f10, "↵ saves it in the keyring · then pick a stop", nx + 12 * S, yy, int(b.f10.line_h), argb(H.dim, 0xff))
		panel_foot(a, cv, S, H, {{"↵", "Save"}, {"Tab", "Show"}, {"Esc", "Later"}}, false)
	case .Pick:
		l := bus_list(b)
		q := strings.to_lower(string(b.q[:]), context.temp_allocator)
		y += 6 * S + 8 * S
		if len(b.q) > 0 do panel_group(a, cv, S, 16 * S, y, int(b.f10b.line_h), H, "STOPS", b.searching || panel_busy(&b.pn) ? "searching…" : fmt.tprintf("%d found · Trafiklab", len(l)))
		else do panel_group(a, cv, S, 16 * S, y, int(b.f10b.line_h), H, "RECENT", "type to search all stops")
		y += int(b.f10b.line_h) + 4 * S
		if len(l) == 0 && !(b.searching || panel_busy(&b.pn)) {
			msg := len(b.q) > 0 ? fmt.tprintf("No stop matches “%s”.", string(b.q[:])) : "None yet: type a stop’s name."
			text_in(cv, b.f11, msg, 16 * S, y + 8 * S, 16 * S, argb(H.dim, 0xff))
		}
		for s, i in l {
			rh := 44 * S
			ry := y + S
			if ry + rh > fy - 4 * S do break
			on := i == b.cur
			bus_row(a, cv, S, x0, ry, x1 - x0, rh, H, on)
			// the busy bar and the mode tags, from the right
			rx := x1 - 10 * S - 36 * S
			ph, _ := strconv.parse_f32(s.per_hour)
			panel_meter(cv, rx, ry + (rh - 4 * S) / 2, 36 * S, 4 * S, ph / 40, on ? H.acc : soft, H.line)
			modes := strings.split(s.modes != "" ? s.modes : "BUS", ",", context.temp_allocator)
			#reverse for m in modes {
				mw := tw(b.f9b, m) + 8 * S
				rx -= 10 * S + mw
				panel_tag(cv, b.f9b, rx, ry + (rh - 13 * S) / 2, mw, 13 * S, S, m, m == "TRAIN" ? th.yellow : H.acc)
				rx += 0
			}
			lx := x0 + 10 * S
			nw := rx - 10 * S - lx
			nm := ellipsize(b.f12b, s.name, nw)
			ly := ry + (rh - int(b.f12b.line_h) - 3 * S - int(b.f10.line_h)) / 2
			at := q != "" ? strings.index(strings.to_lower(nm, context.temp_allocator), q) : -1
			if at >= 0 { // the match in the accent
				xx := lx
				text_in(cv, b.f12b, nm[:at], xx, ly, int(b.f12b.line_h), argb(H.fg, 0xff)); xx += tw(b.f12b, nm[:at])
				text_in(cv, b.f12b, nm[at:at + len(q)], xx, ly, int(b.f12b.line_h), argb(H.acc, 0xff)); xx += tw(b.f12b, nm[at:at + len(q)])
				text_in(cv, b.f12b, nm[at + len(q):], xx, ly, int(b.f12b.line_h), argb(H.fg, 0xff))
			} else do text_in(cv, b.f12b, nm, lx, ly, int(b.f12b.line_h), argb(H.fg, 0xff))
			sub := s.per_hour != "" && s.per_hour != "0" ? fmt.tprintf("%s departures an hour", s.per_hour) : "recent"
			if s.id == b.stop_id do sub = strings.concatenate({sub, " · current"}, context.temp_allocator)
			text_in(cv, b.f10, ellipsize(b.f10, sub, nw), lx, ly + int(b.f12b.line_h) + 3 * S, int(b.f10.line_h), argb(H.dim, 0xff))
			hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
			y = ry + rh + S
		}
		panel_foot(a, cv, S, H, {{"type", "Search"}, {"↑↓", "Move"}, {"↵", "Use stop"}, {"Esc", "Back"}}, false)
	case .Departures:
		stale := b.state == "offline"
		if stale do y += 10 * S + panel_notice(a, cv, S, px, y + 10 * S, w - 2 * px, H, b.fetched_hm != "" ? fmt.tprintf("Offline · last updated %s", b.fetched_hm) : "Offline", "Times below are from then and may have changed. k4 tries again every 30 s.", th.yellow)
		y += 6 * S
		if len(b.deps) == 0 {
			msg := b.next_after != "" ? fmt.tprintf("No departures in the next hour. The first one after that is %s.", b.next_after) : "No departures in the next hour."
			for l in wrap_text(b.f11, msg, w - 32 * S) { text_in(cv, b.f11, l, 16 * S, y + 8 * S, 16 * S, argb(H.dim, 0xff)); y += 16 * S }
		}
		order := bus_order(b)
		plat := "\x00"
		for di, i in order {
			d := b.deps[di]
			if b.grouped && bus_group(d) != plat { // a heading per platform (or direction): its destinations
				plat = bus_group(d)
				dests := make([dynamic]string, 0, 4, context.temp_allocator)
				for x in b.deps do if bus_group(x) == plat {
					seen := false
					for e in dests do if e == x.dest do seen = true
					if !seen do append(&dests, x.dest)
				}
				if y + 22 * S > fy - 4 * S do break
				panel_group(a, cv, S, 16 * S, y + 8 * S, int(b.f10b.line_h), H, strings.to_upper(plat, context.temp_allocator), strings.join(dests[:], " · ", context.temp_allocator))
				y += 8 * S + int(b.f10b.line_h) + 4 * S
			}
			rh := 44 * S
			ry := y + S
			if ry + rh > fy - 4 * S do break
			on := i == b.cur
			bus_row(a, cv, S, x0, ry, x1 - x0, rh, H, on)
			train := d.mode == "TRAIN"
			c := d.cancelled
			lc := c ? H.hot : (train ? th.yellow : H.acc)
			// the glyph, the line box
			gx := x0 + 10 * S
			g := train ? "󰔬" : "󰃧"
			text_in(cv, b.f12, g, gx, ry, rh, argb(bus_fade(c ? H.hot : (train ? th.yellow : H.dim), H.bg, stale), 0xff))
			bx := gx + 14 * S + 10 * S
			bw := max(30 * S, tw(b.f12b, d.line) + 10 * S)
			fill_rect(cv, bx, ry + (rh - 22 * S) / 2, bw, 22 * S, argb(lc, 0x1a))
			rounded_rect(cv, bx, ry + (rh - 22 * S) / 2, bw, 22 * S, 0, 0, f32(S), argb(mix(H.bg, lc, 0.5), 0xff))
			text_in(cv, b.f12b, d.line, bx + (bw - tw(b.f12b, d.line)) / 2, ry + (rh - 22 * S) / 2, 22 * S, argb(bus_fade(lc, H.bg, stale), 0xff))
			// the minutes and the tag under them
			ms, m := bus_mins(d, now)
			delayed := d.delay >= 60 && !c
			if c do ms = "cancelled"
			else if !d.live do ms = strings.concatenate({"≈ ", ms}, context.temp_allocator)
			mc := c ? H.hot : (m == 0 ? H.acc : (delayed ? th.yellow : H.fg))
			mf := c ? b.f11b : b.f15b
			tag, tc := "", H.dim
			switch {
			case c: if n := bus_next_same(b, d); n != "" do tag = fmt.tprintf("next: %s", n)
			case delayed: tag, tc = fmt.tprintf("+%d late", (d.delay + 30) / 60), th.yellow
			case !d.live: tag = "timetable"
			}
			rx := x1 - 10 * S
			col := max(64 * S, max(tw(mf, ms), tw(b.f9b, tag)))
			my := ry + (rh - int(mf.line_h) - (tag != "" ? 2 * S + int(b.f9b.line_h) : 0)) / 2
			text_in(cv, mf, ms, rx - tw(mf, ms), my, int(mf.line_h), argb(bus_fade(mc, H.bg, stale), 0xff))
			if tag != "" do text_in(cv, b.f9b, tag, rx - tw(b.f9b, tag), my + int(mf.line_h) + 2 * S, int(b.f9b.line_h), argb(bus_fade(tc, H.bg, stale), 0xff))
			// the destination, then the time and the platform
			lx := bx + bw + 10 * S
			lw := rx - col - 10 * S - lx
			ly := ry + (rh - int(b.f12b.line_h) - 3 * S - int(b.f10.line_h)) / 2
			text_in(cv, b.f12b, ellipsize(b.f12b, d.dest, lw), lx, ly, int(b.f12b.line_h), argb(bus_fade(c ? H.hot : H.fg, H.bg, stale), 0xff))
			sy := ly + int(b.f12b.line_h) + 3 * S
			moved := d.real != "" && d.real != "-" && d.real != d.sched
			sc := bus_fade(c ? mix(H.hot, H.bg, 0.3) : H.dim, H.bg, stale)
			xx := lx
			text_in(cv, b.f10, d.sched, xx, sy, int(b.f10.line_h), argb(sc, 0xff))
			if c || moved do fill_rect(cv, xx, sy + int(b.f10.line_h) / 2, tw(b.f10, d.sched), S, argb(sc, 0xff))
			xx += tw(b.f10, d.sched)
			rest := moved ? fmt.tprintf(" → %s", d.real) : ""
			if d.platform != "" do rest = fmt.tprintf("%s · %s", rest, d.platform)
			text_in(cv, b.f10, ellipsize(b.f10, rest, lx + lw - xx), xx, sy, int(b.f10.line_h), argb(sc, 0xff))
			hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
			y = ry + rh + S
		}
		panel_foot(a, cv, S, H, {{"↑↓", "Move"}, {"↵", "Remind"}, {"s", "Stop"}, {"g", b.grouped ? "Ungroup" : "Group"}, {"r", "Refresh"}}, false)
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

bus_dump :: proc(a: ^App) -> string {
	b := B(a)
	sb := strings.builder_make(context.temp_allocator)
	now := bus_now()
	fmt.sbprintfln(&sb, "bus %s · %v · %s%s%s", b.state, b.view, b.stop_name, len(b.q) > 0 ? fmt.tprintf(" · “%s”", string(b.q[:])) : "", b.grouped ? " · grouped" : "")
	switch b.view {
	case .Departures:
		plat := "\x00"
		for di, i in bus_order(b) {
			d := b.deps[di]
			if b.grouped && bus_group(d) != plat { plat = bus_group(d); fmt.sbprintfln(&sb, "  [%s]", plat) }
			ms, _ := bus_mins(d, now)
			tag := ""
			switch {
			case d.cancelled: if n := bus_next_same(b, d); n != "" do tag = fmt.tprintf(" · next: %s", n)
			case d.delay >= 60: tag = fmt.tprintf(" · +%d late", (d.delay + 30) / 60)
			case !d.live: tag = " · timetable"
			}
			fmt.sbprintfln(&sb, "%s %s %s · %s%s%s", i == b.cur ? "*" : " ", d.line, d.dest, d.cancelled ? "cancelled" : ms, tag, d.platform != "" ? fmt.tprintf(" · %s", d.platform) : "")
		}
		if len(b.deps) == 0 do fmt.sbprintfln(&sb, "empty%s", b.next_after != "" ? fmt.tprintf(" · next %s", b.next_after) : "")
	case .Pick: for s, i in bus_list(b) do fmt.sbprintfln(&sb, "%s %s%s", i == b.cur ? "*" : " ", s.name, s.recent ? " · recent" : "")
	case .Key: fmt.sbprintfln(&sb, "key %s", panel_masked(&b.pn))
	}
	panel_dump_toast(&b.pn, &sb)
	return strings.to_string(sb)
}
