package k4

import "core:c/libc"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:time"

// --pihole: the Pi-hole popup (the Kestrel design's KPihole board), under the bar item or alone:
// 420×640. The head: PI-HOLE, a filter for the query log, the host. Fixed at the top: the status
// (a shield with its state, blocking on / off with the countdown / DNS down, the versions), today's
// queries · blocked · share · clients over the share's line, the PAUSE row (5 min, 30 min, until
// resumed; ← → picks, ↵ pauses; Resume while paused) and UNBOUND (resolves, DNSSEC, the probe's
// time, cache hits, recursion, SERVFAIL, uptime; Restart). Then one list that scrolls: the recent
// queries (blocked in red with why: ↵ allows; an allowed one: ⌃B blocks), top clients (↵ shows
// their queries), the adlists (↵ turns one on/off), Update gravity (its lines stream under it) and
// your allow / deny entries (Del removes). Typing filters by domain or device. Setup states in
// place of all that: paste the app password (⌃V, ↵), a changed certificate (trust it or not).
// Data: k4-pihole window-data (pihole.py window_data, its doc lists the lines); the runner's verbs:
// pause N, resume, allow D, block D, unlist TYPE KIND D, list-toggle ADDRESS, gravity (streamed),
// restart-unbound, restart-ftl, ssh-setup, admin [PATH], setup-password (the secret), set-host,
// trust, keep-cert.

PH_W, PH_H :: 420, 640

Ph_Query :: struct { domain, tag, dev, at, type: string, blocked: bool }
Ph_Client :: struct { name: string, count: int }
Ph_List :: struct { addr, name: string, count: int, on: bool }
Ph_Entry :: struct { type, kind, domain, note: string }
Ph_Fp :: struct { label, when_, fp: string }

Pihole :: struct {
	using pn: Panel,
	arena: vmem.Arena,
	state, host, sub, ukind: string, // state: ok, down, setup, cert
	left: int,           // blocking's seconds left as loaded (-1: off until resumed, 0: on)
	left_at: time.Tick,  // when that was read (the countdown runs from it)
	total, blocked, active, clients, ums, uhit, urec, usf, uup: int,
	pct: f64,
	queries: [dynamic]Ph_Query,
	cls: [dynamic]Ph_Client,
	lists: [dynamic]Ph_List,
	entries: [dynamic]Ph_Entry,
	fps: [dynamic]Ph_Fp,
	grav_domains, lists_on: int,
	grav_ago: string,
	grav: [dynamic]string, // the gravity run's lines (streamed)
	grav_running: bool,
	sel: string,          // the picked row's id (pause, restart, q:N, c:N, l:N, grav, e:N, s1…)
	pz: int,              // the pause length picked: 5 min, 30 min, until resumed
	q: [dynamic]u8,       // the filter
	pw: [dynamic]u8,      // the app password being pasted (setup), or a host
	host_mode: bool,      // setup: the field takes a host instead
	field: bool,          // the keys go to the field
	top: int,             // the list's scroll, px (S=1)
}

pihole_setup :: proc(a: ^App, data: string) {
	m := new(Pihole)
	_ = vmem.arena_init_growing(&m.arena)
	m.mode = {draw = ph_draw, key = ph_key, click = ph_click, scroll = ph_scroll, loaded = ph_loaded, tick = ph_tick, stream = ph_stream, dump = ph_dump}
	panel_init(a, &m.pn, "pihole", data)
	m.refresh_ms = 15000
	a.width, a.height = PH_W, PH_H
}

@(private = "file")
PH :: proc(a: ^App) -> ^Pihole { return (^Pihole)(a.pn) }

@(private = "file")
ph_loaded :: proc(a: ^App, data: string) {
	m := PH(a)
	if !strings.has_prefix(data, "S\t") && !strings.contains(data, "\nS\t") do return // (no status: the loader failed or had nothing; keep what is shown)
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al := context.allocator) -> string { return s == "-" ? "" : strings.clone(s, al) }
	num :: proc(s: string) -> int { n, _ := strconv.parse_int(s); return n }
	m.queries = make([dynamic]Ph_Query, al); m.cls = make([dynamic]Ph_Client, al); m.lists = make([dynamic]Ph_List, al)
	m.entries = make([dynamic]Ph_Entry, al); m.fps = make([dynamic]Ph_Fp, al)
	m.state, m.ukind = "ok", "nossh"
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			m.state, m.host, m.sub = c(fget(f, 1), al), c(fget(f, 3), al), c(fget(f, 4), al)
			m.left, m.left_at = num(fget(f, 2)), time.tick_now()
		case "N":
			m.total, m.blocked, m.active, m.clients = num(fget(f, 1)), num(fget(f, 2)), num(fget(f, 4)), num(fget(f, 5))
			m.pct, _ = strconv.parse_f64(fget(f, 3))
		case "U":
			m.ukind = c(fget(f, 1), al)
			m.ums, m.uhit, m.urec, m.usf, m.uup = num(fget(f, 2)), num(fget(f, 3)), num(fget(f, 4)), num(fget(f, 5)), num(fget(f, 6))
		case "Q": append(&m.queries, Ph_Query{domain = c(fget(f, 1), al), blocked = fget(f, 2) == "1", tag = c(fget(f, 3), al), dev = c(fget(f, 4), al), at = c(fget(f, 5), al), type = c(fget(f, 6), al)})
		case "C": append(&m.cls, Ph_Client{name = c(fget(f, 1), al), count = num(fget(f, 2))})
		case "L": append(&m.lists, Ph_List{addr = c(fget(f, 1), al), name = c(fget(f, 2), al), count = num(fget(f, 3)), on = fget(f, 4) == "1"})
		case "G": m.grav_domains, m.grav_ago, m.lists_on = num(fget(f, 1)), c(fget(f, 2), al), num(fget(f, 3))
		case "E": append(&m.entries, Ph_Entry{type = c(fget(f, 1), al), kind = c(fget(f, 2), al), domain = c(fget(f, 3), al), note = c(fget(f, 4), al)})
		case "F": append(&m.fps, Ph_Fp{label = c(fget(f, 1), al), when_ = c(fget(f, 2), al), fp = c(fget(f, 3), al)})
		}
	}
	if m.sel == "" do m.sel = m.state == "setup" ? "s1" : (m.state == "cert" ? "c1" : (m.ukind == "dnssec" || m.ukind == "noresolve" ? "restart" : "pause"))
}

// Blocking's seconds left now (-1: off until resumed, 0: on).
@(private = "file")
ph_left :: proc(m: ^Pihole) -> int {
	if m.left <= 0 do return m.left
	gone := int(time.duration_seconds(time.tick_since(m.left_at)))
	return max(m.left - gone, 1)
}

@(private = "file")
ph_tick :: proc(a: ^App) -> int {
	m := PH(a)
	if m.left > 0 do return 1000 // the countdown
	return -1
}

@(private = "file")
ph_stream :: proc(a: ^App, line: string) {
	m := PH(a)
	if line == "k4:end" { m.grav_running = false; panel_reload(a); return }
	l := strings.trim_space(line)
	if l != "" && !strings.has_prefix(l, "k4:") do append(&m.grav, strings.clone(l))
}

@(private = "file")
ph_mmss :: proc(s: int) -> string { return fmt.tprintf("%d:%02d", s / 60, s % 60) }

@(private = "file")
ph_num :: proc(n: int) -> string { // 18 240
	s := fmt.tprint(n)
	if len(s) <= 3 do return s
	sb := strings.builder_make(context.temp_allocator)
	for r, i in s {
		if i > 0 && (len(s) - i) % 3 == 0 do strings.write_byte(&sb, ' ')
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

@(private = "file")
ph_back_at :: proc(left: int) -> string {
	t := libc.time_t(time.time_to_unix(time.now()) + i64(left))
	tm := libc.localtime(&t)
	return fmt.tprintf("%d:%02d", tm.tm_hour, tm.tm_min)
}

// ---------- the rows: what ↑↓ walks through ----------

Ph_Row :: struct { id: string, kind: u8, i: int } // kind: 'p' pause, 'r' restart, 'q' query, 'c' client, 'l' list, 'g' gravity, 'e' entry, 's' setup row

@(private = "file")
ph_filter :: proc(m: ^Pihole) -> string { return strings.to_lower(strings.trim_space(string(m.q[:])), context.temp_allocator) }

@(private = "file")
ph_shown :: proc(m: ^Pihole) -> []int { // the queries the filter lets through
	f := ph_filter(m)
	out := make([dynamic]int, 0, len(m.queries), context.temp_allocator)
	for x, i in m.queries do if f == "" || strings.contains(strings.to_lower(x.domain, context.temp_allocator), f) || strings.contains(strings.to_lower(x.dev, context.temp_allocator), f) do append(&out, i)
	return out[:]
}

@(private = "file")
ph_rows :: proc(m: ^Pihole) -> []Ph_Row {
	out := make([dynamic]Ph_Row, 0, 160, context.temp_allocator)
	switch m.state {
	case "setup": for id in ([]string{"s1", "s2"}) do append(&out, Ph_Row{id = id, kind = 's'}); return out[:]
	case "cert": for id in ([]string{"c1", "c2", "c3"}) do append(&out, Ph_Row{id = id, kind = 's'}); return out[:]
	}
	append(&out, Ph_Row{id = "pause", kind = 'p'}, Ph_Row{id = "restart", kind = 'r'})
	for i in ph_shown(m) do append(&out, Ph_Row{id = fmt.tprintf("q:%d", i), kind = 'q', i = i})
	if ph_filter(m) != "" do return out[:]
	for _, i in m.cls do append(&out, Ph_Row{id = fmt.tprintf("c:%d", i), kind = 'c', i = i})
	for _, i in m.lists do append(&out, Ph_Row{id = fmt.tprintf("l:%d", i), kind = 'l', i = i})
	append(&out, Ph_Row{id = "grav", kind = 'g'})
	for _, i in m.entries do append(&out, Ph_Row{id = fmt.tprintf("e:%d", i), kind = 'e', i = i})
	return out[:]
}

@(private = "file")
ph_cur :: proc(m: ^Pihole) -> (Ph_Row, int) {
	rows := ph_rows(m)
	for r, i in rows do if r.id == m.sel do return r, i
	if len(rows) > 0 do return rows[0], 0
	return {}, -1
}

// ---------- the keys ----------

@(private = "file")
ph_unbound_act :: proc(a: ^App, m: ^Pihole) {
	switch {
	case m.ukind == "nossh": panel_run(a, "ssh-setup")
	case m.state == "down" && (m.ukind == "ok" || m.ukind == "nostats"): panel_run(a, "restart-ftl")
	case: panel_run(a, "restart-unbound")
	}
}

@(private = "file")
ph_enter :: proc(a: ^App, m: ^Pihole) {
	r, _ := ph_cur(m)
	switch r.kind {
	case 'p':
		if m.state == "down" do return
		if ph_left(m) != 0 { panel_run(a, "resume"); return }
		secs := [3]string{"300", "1800", "0"}
		panel_run(a, "pause", secs[m.pz])
	case 'r': ph_unbound_act(a, m)
	case 'q':
		x := m.queries[r.i]
		if m.state == "down" { panel_say(&m.pn, "Pi-hole isn’t answering · try again when it’s back", a.theme.yellow); return }
		if x.blocked do panel_run(a, "allow", x.domain)
		else do panel_say(&m.pn, fmt.tprintf("⌃B blocks %s", x.domain))
	case 'c': clear(&m.q); append(&m.q, ..transmute([]u8)m.cls[r.i].name); m.sel = "q:0"; if sh := ph_shown(m); len(sh) > 0 do m.sel = fmt.tprintf("q:%d", sh[0])
	case 'l': panel_run(a, "list-toggle", m.lists[r.i].addr)
	case 'g':
		if m.grav_running { panel_say(&m.pn, "Gravity is already updating"); return }
		clear(&m.grav); m.grav_running = true
		panel_stream(a, "gravity")
	case 'e': panel_say(&m.pn, "Del removes it")
	case 's':
		switch r.id {
		case "s1": panel_run(a, "admin")
		case "s2": m.host_mode, m.field = true, true; clear(&m.pw); panel_say(&m.pn, "Type the host or IP, then ↵")
		case "c1": panel_run(a, "trust")
		case "c2": panel_run(a, "admin", "settings/system")
		case "c3": panel_run(a, "keep-cert")
		}
	}
}

@(private = "file")
ph_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := PH(a)
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	plain := text != "" && k == .None && !ctrl && !alt
	rows := ph_rows(m)
	r, ci := ph_cur(m)
	if ctrl && (low == 'c' || low == 'g') { panel_close(a); return true }
	setup := m.state == "setup"
	if setup { // the password (or a host): typed or pasted straight in; ↵ connects
		switch {
		case ctrl && low == 'v': append(&m.pw, ..transmute([]u8)strings.trim_space(msg_clipboard())); panel_say(&m.pn, m.host_mode ? "↵ uses this host" : "Pasted · ↵ connects"); return true
		case k == .Backspace && len(m.pw) > 0: pop(&m.pw); return true
		case k == .Enter && len(m.pw) > 0:
			if m.host_mode do panel_run(a, "set-host", secret = strings.clone(string(m.pw[:]), context.temp_allocator))
			else do panel_run(a, "setup-password", secret = strings.clone(string(m.pw[:]), context.temp_allocator))
			clear(&m.pw); m.host_mode = false
			return true
		case plain: append(&m.pw, ..transmute([]u8)text); return true
		}
	}
	if m.field && !setup {
		switch {
		case k == .Down || k == .Enter:
			m.field = false
			if sh := ph_shown(m); len(sh) > 0 do m.sel = fmt.tprintf("q:%d", sh[0])
		case k == .Escape: clear(&m.q); m.field = false
		case k == .Backspace: if len(m.q) > 0 do pop(&m.q); else do m.field = false
		case ctrl && low == 'v': append(&m.q, ..transmute([]u8)strings.trim_space(msg_clipboard()))
		case plain: append(&m.q, ..transmute([]u8)text)
		case: return false
		}
		m.top = 0
		return true
	}
	switch {
	case k == .Down: if ci >= 0 do m.sel = rows[min(ci + 1, len(rows) - 1)].id
	case k == .Up:
		if ci == 0 && !setup && m.state != "cert" do m.field = true
		else if ci > 0 do m.sel = rows[ci - 1].id
	case k == .Page_Down: if ci >= 0 do m.sel = rows[min(ci + 8, len(rows) - 1)].id
	case k == .Page_Up: if ci >= 0 do m.sel = rows[max(ci - 8, 0)].id
	case (k == .Left || k == .Right) && r.kind == 'p' && ph_left(m) == 0 && m.state != "down": m.pz = clamp(m.pz + (k == .Right ? 1 : -1), 0, 2)
	case k == .Enter: ph_enter(a, m)
	case ctrl && low == 'b':
		if r.kind != 'q' { panel_say(&m.pn, "Pick a query to block"); return true }
		x := m.queries[r.i]
		if x.blocked do panel_say(&m.pn, "Already blocked · ↵ allows it")
		else do panel_run(a, "block", x.domain)
	case k == .Delete:
		if r.kind == 'e' { e := m.entries[r.i]; panel_run(a, "unlist", e.type, e.kind, e.domain) }
		else do panel_say(&m.pn, "Del removes your allow and deny entries")
	case k == .Escape:
		if len(m.q) > 0 { clear(&m.q); m.top = 0 }
		else do panel_close(a)
	case k == .Backspace: panel_close(a)
	case plain && text != " " && !setup && m.state != "cert": m.field = true; append(&m.q, ..transmute([]u8)text); m.top = 0
	case: return false
	}
	return true
}

@(private = "file")
ph_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := PH(a)
	h := hit_at(a, x, y) or_return
	#partial switch h.kind {
	case .Row:
		rows := ph_rows(m)
		if h.a >= 0 && h.a < len(rows) { m.sel, m.field = rows[h.a].id, false; ph_enter(a, m) }
	case .Chip:
		switch {
		case h.a == 9: m.field = true
		case h.a >= 20 && h.a < 23: m.sel, m.pz, m.field = "pause", h.a - 20, false; ph_enter(a, m)
		case h.a == 30: m.sel = "restart"; ph_unbound_act(a, m)
		}
	}
	return true
}

@(private = "file")
ph_scroll :: proc(a: ^App, n: int) -> bool { m := PH(a); m.top = max(m.top + n * 38, 0); return true }

// ---------- drawing ----------

@(private = "file")
ph_btn :: proc(a: ^App, cv: ^Canvas, m: ^Pihole, S, x, y: int, label: string, on: bool, H: HUD, hit: int) -> int {
	soft := mix(H.fg, H.bg, 0.2)
	bw := tw(m.f11b, label) + 18 * S
	if on do fill_rect(cv, x, y, bw, 22 * S, argb(H.acc, 0xff))
	rounded_rect(cv, x, y, bw, 22 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
	text_in(cv, m.f11b, label, x + 9 * S, y, 22 * S, argb(on ? H.bg : soft, 0xff))
	hit_add(a, x, y, bw, 22 * S, .Chip, hit, 0)
	return bw
}

@(private = "file")
ph_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := PH(a)
	H := panel_ground(a, cv)
	t := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	sel := mix(H.bg, H.acc, 0.07)
	w, h := cv.w, cv.h
	px := 14 * S
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff))
	down, setup, cert := m.state == "down", m.state == "setup", m.state == "cert"
	left := ph_left(m)

	// the head: PI-HOLE, the filter, the host
	hh := 46 * S
	cw := tw(m.f12b, "PI-HOLE") + 16 * S
	fill_rect(cv, px, (hh - 22 * S) / 2, cw, 22 * S, argb(H.acc, 0xff))
	text_in(cv, m.f12b, "PI-HOLE", px + 8 * S, (hh - 22 * S) / 2, 22 * S, argb(H.bg, 0xff))
	host := setup ? "not set up" : (cert || down ? fmt.tprintf("%s · no contact", m.host) : m.host)
	hw := tw(m.f11, host)
	text_in(cv, m.f11, host, w - px - hw, 0, hh, argb(cert || down ? t.red : H.dim, 0xff))
	qx := px + cw + 10 * S
	q := string(m.q[:])
	if !setup && !cert {
		if q == "" do text_in(cv, m.f13, "Filter queries…", qx, 0, hh, argb(H.faint, 0xff))
		text_in(cv, m.f13, ellipsize(m.f13, q, w - qx - hw - 2 * px), qx, 0, hh, argb(H.fg, 0xff))
		if m.field do fill_rect(cv, qx + (q != "" ? tw(m.f13, q) + S : 0), (hh - 16 * S) / 2, 2 * S, 16 * S, argb(H.acc, 0xff))
		hit_add(a, qx, 0, w - qx - hw - 2 * px, hh, .Chip, 9, 0)
	}
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))

	// the foot: the message, else the keys; kestrel at the right
	fh := 36 * S
	fy := h - fh
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	text_in(cv, m.f11, "kestrel", w - px - tw(m.f11, "kestrel"), fy, fh, argb(H.acc, 0xff))
	if m.toast != "" {
		text_in(cv, m.f11, ellipsize(m.f11, m.toast, w - 2 * px - 80 * S), px, fy, fh, argb(m.tone != 0 ? m.tone : H.acc, 0xff))
	} else {
		kx := px
		for k in ph_hints(m) {
			kw := tw(m.f10, k[0]) + 12 * S
			if kx + kw + 5 * S + tw(m.f11, k[1]) > w - px - 70 * S do break
			fill_rect(cv, kx, fy + (fh - 17 * S) / 2, kw, 17 * S, argb(H.panel, 0xff))
			rounded_rect(cv, kx, fy + (fh - 17 * S) / 2, kw, 17 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, m.f10, k[0], kx + 6 * S, fy + (fh - 17 * S) / 2, 17 * S, argb(soft, 0xff))
			kx += kw + 5 * S
			text_in(cv, m.f11, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(m.f11, k[1]) + 12 * S
		}
	}

	rows := ph_rows(m)
	ri :: proc(rows: []Ph_Row, id: string) -> int { for r, i in rows do if r.id == id do return i; return -1 }
	y := hh + S
	if setup || cert { ph_draw_setup(a, cv, m, S, H, y, fy, rows); return }

	// the status: the shield, blocking on / off / DNS down
	y += 12 * S
	sc, shp, title, cd := t.green, Shape.Shield_On, "Blocking on", ""
	sub := m.sub
	if left != 0 {
		sc, shp, title = t.yellow, .Shield_Off, "Blocking off"
		cd = left > 0 ? ph_mmss(left) : ""
		sub = left > 0 ? fmt.tprintf("back on at %s", ph_back_at(left)) : "until you resume · nothing turns it back on"
	}
	if down do sc, shp, title = t.red, .Shield_Broken, "DNS down"
	fill_rect(cv, px, y, 36 * S, 36 * S, argb(sc, 0x14))
	rounded_rect(cv, px, y, 36 * S, 36 * S, 0, 0, f32(S), argb(sc, 0xff))
	shape_draw(cv, shp, px + 8 * S, y + 8 * S, 20 * S, sc)
	tx := px + 48 * S
	text_in(cv, m.f15b, title, tx, y, 20 * S, argb(sc, 0xff))
	if cd != "" do text_in(cv, m.f15b, cd, tx + tw(m.f15b, title) + 10 * S, y, 20 * S, argb(t.yellow, 0xff))
	text_in(cv, m.f11, ellipsize(m.f11, sub, w - tx - px), tx, y + 21 * S, 15 * S, argb(H.dim, 0xff))
	y += 36 * S + 10 * S
	// today's numbers, the share's line (dimmed when it's down: the last known)
	dimf :: proc(c, bg: u32, down: bool) -> u32 { return down ? mix(bg, c, 0.4) : c }
	stats := [4][2]string{{ph_num(m.total), "queries today"}, {ph_num(m.blocked), "blocked"}, {fmt.tprintf("%.1f%%", m.pct), "share"}, {fmt.tprint(m.active), "clients"}}
	colw := (w - 2 * px) / 4
	for s_, i in stats {
		sx := px + i * colw
		if i > 0 { fill_rect(cv, sx, y, S, 32 * S, argb(dimf(H.line, H.bg, down), 0xff)); sx += 10 * S }
		vc := i == 2 ? (left != 0 || down ? H.dim : H.acc) : H.fg
		text_in(cv, m.f15b, s_[0], sx, y, 18 * S, argb(dimf(vc, H.bg, down), 0xff))
		text_in(cv, m.f10, s_[1], sx, y + 19 * S, 13 * S, argb(dimf(H.dim, H.bg, down), 0xff))
	}
	y += 32 * S + 10 * S
	fill_rect(cv, px, y, w - 2 * px, 3 * S, argb(dimf(H.line, H.bg, down), 0xff))
	fill_rect(cv, px, y, int(f64(w - 2 * px) * min(m.pct, 100) / 100), 3 * S, argb(dimf(left != 0 || down ? H.dim : H.acc, H.bg, down), 0xff))
	y += 3 * S + 10 * S

	// PAUSE
	cur, _ := ph_cur(m)
	psel := !m.field && cur.kind == 'p'
	if psel { fill_rect(cv, 0, y, w, 34 * S, argb(sel, 0xff)); fill_rect(cv, 0, y, 3 * S, 34 * S, argb(left != 0 ? t.yellow : H.acc, 0xff)) }
	hit_add(a, 0, y, w, 34 * S, .Row, ri(rows, "pause"), 0)
	plabel := left != 0 ? "PAUSED" : "PAUSE"
	spaced(cv, m.f10b, plabel, px, y, 34 * S, left != 0 ? t.yellow : H.dim, S)
	bx := px + 60 * S
	switch {
	case down: text_in(cv, m.f12, "Pausing needs Pi-hole to answer", bx, y, 34 * S, argb(H.dim, 0xff))
	case left != 0:
		text_in(cv, m.f13b, "Resume blocking", bx, y, 34 * S, argb(t.yellow, 0xff))
		rm := left > 0 ? fmt.tprintf("or wait %s", ph_mmss(left)) : "off until now"
		text_in(cv, m.f10, "↵", w - px - tw(m.f10, "↵"), y, 34 * S, argb(H.dim, 0xff))
		text_in(cv, m.f11, rm, w - px - tw(m.f10, "↵") - 8 * S - tw(m.f11, rm), y, 34 * S, argb(H.dim, 0xff))
	case:
		for l, i in ([3]string{"5 min", "30 min", "Until resumed"}) do bx += ph_btn(a, cv, m, S, bx, y + 6 * S, l, psel && i == m.pz, H, 20 + i) + 6 * S
	}
	y += 34 * S

	// UNBOUND
	fill_rect(cv, 0, y, w, S, argb(H.line, 0xff))
	uy := y + 8 * S
	if m.ukind == "dnssec" || m.ukind == "noresolve" do fill_rect(cv, 0, y + S, 3 * S, 46 * S, argb(t.red, 0xff))
	spaced(cv, m.f10b, "UNBOUND", px, uy, 22 * S, H.dim, S)
	cx := px + 60 * S
	chip :: proc(cv: ^Canvas, f: ^Font, s: string, x, y, h: int, c: u32) -> int { text_in(cv, f, s, x, y, h, argb(c, 0xff)); return tw(f, s) + 8 * S_ph }
	S_ph = S
	line2, l2c := fmt.tprintf("cache hits %d%% · recursion %d ms · SERVFAIL %d · up %s", m.uhit, m.urec, m.usf, ph_uptime(m.uup)), H.dim
	btn := "Restart"
	switch m.ukind {
	case "nossh":
		cx += chip(cv, m.f11b, "not watched", cx, uy, 22 * S, H.dim)
		line2, btn = fmt.tprintf("k4 reads unbound over ssh · %s isn’t set up for it yet", m.host), "Set up ssh"
	case "noresolve":
		cx += chip(cv, m.f11b, "not resolving", cx, uy, 22 * S, t.red)
		line2, l2c = "Pi-hole has no resolver behind it · lookups fail", t.red
	case "dnssec":
		cx += chip(cv, m.f11, "● resolves", cx, uy, 22 * S, t.green)
		cx += chip(cv, m.f11b, "DNSSEC failing", cx, uy, 22 * S, t.red)
		cx += chip(cv, m.f11, fmt.tprintf("%d ms", m.ums), cx, uy, 22 * S, H.fg)
		line2, l2c = "a broken-signature test domain resolved · it should fail", t.red
	case:
		cx += chip(cv, m.f11, "● resolves", cx, uy, 22 * S, t.green)
		cx += chip(cv, m.f11, "DNSSEC ok", cx, uy, 22 * S, t.green)
		cx += chip(cv, m.f11, fmt.tprintf("%d ms", m.ums), cx, uy, 22 * S, H.fg)
		if m.ukind == "nostats" do line2 = "resolves and validates · its stats need k4-pihole setup-host"
		if down do line2, l2c, btn = "unbound answers, so it’s Pi-hole’s FTL", soft, "Restart FTL"
	}
	usel := !m.field && cur.kind == 'r'
	bw := tw(m.f11b, btn) + 18 * S
	ph_btn(a, cv, m, S, w - px - bw, uy, btn, usel, H, 30)
	hit_add(a, 0, uy, w - px - bw - 4 * S, 22 * S, .Row, ri(rows, "restart"), 0)
	text_in(cv, m.f10, ellipsize(m.f10, line2, w - px - 60 * S - px), px + 60 * S, uy + 26 * S, 13 * S, argb(l2c, 0xff))
	y = uy + 26 * S + 13 * S + 10 * S
	fill_rect(cv, 0, y, w, S, argb(H.line, 0xff))
	y += S

	// the list that scrolls
	ph_draw_list(a, cv, m, S, H, y, fy, rows)
}

@(private = "file") S_ph: int // (the chip helper's scale)

@(private = "file")
ph_uptime :: proc(s: int) -> string {
	if s <= 0 do return "?"
	if s >= 86400 do return fmt.tprintf("%d d %d h", s / 86400, s / 3600 % 24)
	return fmt.tprintf("%d h %d min", s / 3600, s / 60 % 60)
}

@(private = "file")
ph_hints :: proc(m: ^Pihole) -> [][2]string {
	keys :: proc(k: ..[2]string) -> [][2]string { out := make([][2]string, len(k), context.temp_allocator); copy(out, k); return out }
	r, _ := ph_cur(m)
	left := ph_left(m)
	switch {
	case m.field: return keys({"↓", "Results"}, {"Esc", "Clear"}, {"⌫", "Edit"})
	case m.state == "setup": return keys({"⌃V", "Paste"}, {"↵", "Connect"}, {"↑↓", "Move"}, {"Esc", "Close"})
	case m.state == "cert": return keys({"↑↓", "Move"}, {"↵", "Choose"}, {"Esc", "Close"})
	case r.kind == 'p' && left != 0: return keys({"↵", "Resume"}, {"↑↓", "Move"}, {"type", "Filter"}, {"Esc", "Close"})
	case r.kind == 'p' && m.state == "down": return keys({"↑↓", "Move"}, {"type", "Filter"}, {"Esc", "Close"})
	case r.kind == 'p': return keys({"← →", "How long"}, {"↵", "Pause"}, {"↑↓", "Move"}, {"Esc", "Close"})
	case r.kind == 'r': return keys({"↵", m.ukind == "nossh" ? "Set up ssh" : (m.state == "down" ? "Restart FTL" : "Restart")}, {"↑↓", "Move"}, {"type", "Filter"}, {"Esc", "Close"})
	case r.kind == 'q' && m.queries[r.i].blocked: return keys({"↵", "Allow"}, {"↑↓", "Move"}, {"type", "Filter"}, {"Esc", "Close"})
	case r.kind == 'q': return keys({"⌃B", "Block"}, {"↑↓", "Move"}, {"type", "Filter"}, {"Esc", "Close"})
	case r.kind == 'l': return keys({"↵", "On / off"}, {"↑↓", "Move"}, {"Esc", "Close"})
	case r.kind == 'g': return keys({"↵", "Update"}, {"↑↓", "Move"}, {"Esc", "Close"})
	case r.kind == 'e': return keys({"Del", "Remove"}, {"↑↓", "Move"}, {"Esc", "Close"})
	case r.kind == 'c': return keys({"↵", "Its queries"}, {"↑↓", "Move"}, {"Esc", "Close"})
	}
	return keys({"↑↓", "Move"}, {"↵", "Open"}, {"Esc", "Close"})
}

// The list under the fixed part: queries, clients, adlists and gravity, your entries; the picked
// row kept in view.
@(private = "file")
ph_draw_list :: proc(a: ^App, cv: ^Canvas, m: ^Pihole, S: int, H: HUD, y0, y1: int, rows: []Ph_Row) {
	t := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	sel := mix(H.bg, H.acc, 0.07)
	w := cv.w
	px := 14 * S
	down := m.state == "down"
	f := ph_filter(m)
	cur, _ := ph_cur(m)
	// lay the blocks out first (heights in px at S), then draw what fits
	Blk :: struct { kind: u8, id: string, i, h: int, text, count, right: string, cc: u32 }
	bl := make([dynamic]Blk, 0, 200, context.temp_allocator)
	shown := ph_shown(m)
	head :: proc(bl: ^[dynamic]Blk, S: int, text, count, right: string, cc: u32) { append(bl, Blk{kind = 'H', h = 30 * S, text = text, count = count, right = right, cc = cc}) }
	head(&bl, S, f != "" ? fmt.tprintf("Queries matching “%s”", string(m.q[:])) : "Recent queries", f != "" ? fmt.tprintf("%d of %d", len(shown), len(m.queries)) : fmt.tprint(len(m.queries)),
		down ? "last known" : "newest first", f != "" ? H.acc : H.dim)
	for i in shown do append(&bl, Blk{kind = 'q', id = fmt.tprintf("q:%d", i), i = i, h = 38 * S})
	if f != "" && len(shown) == 0 do append(&bl, Blk{kind = 'T', h = 50 * S, text = "Nothing in the last 100 queries matches. Older queries live in Pi-hole’s web admin › Query log."})
	if f == "" {
		append(&bl, Blk{kind = 'T', h = 28 * S, text = "type to filter by domain or device"})
		if len(m.cls) > 0 {
			head(&bl, S, "Top clients today", "", fmt.tprintf("%d active · %d seen", m.active, m.clients), H.dim)
			for _, i in m.cls do append(&bl, Blk{kind = 'c', id = fmt.tprintf("c:%d", i), i = i, h = 30 * S})
		}
		dom := 0
		for l in m.lists do if l.on do dom += l.count
		head(&bl, S, "Adlists", ph_num(dom), fmt.tprintf("gravity %s", m.grav_ago), H.dim)
		for _, i in m.lists do append(&bl, Blk{kind = 'l', id = fmt.tprintf("l:%d", i), i = i, h = 30 * S})
		append(&bl, Blk{kind = 'g', id = "grav", h = 30 * S})
		if len(m.grav) > 0 do append(&bl, Blk{kind = 'G', h = (20 + 14 * min(len(m.grav), 5)) * S + 10 * S})
		head(&bl, S, "Your allow and deny", fmt.tprint(len(m.entries)), "Del removes", H.dim)
		for e, i in m.entries do append(&bl, Blk{kind = 'e', id = fmt.tprintf("e:%d", i), i = i, h = e.note != "" ? 38 * S : 30 * S})
	}
	// the picked row in view
	total, sy, sh := 0, -1, 0
	for b in bl { if b.id != "" && b.id == cur.id && !m.field { sy, sh = total, b.h }; total += b.h }
	view := y1 - y0 - 8 * S
	top := m.top * S
	if sy >= 0 {
		if sy < top do top = max(sy - 30 * S, 0)
		if sy + sh > top + view do top = sy + sh - view + 8 * S
	}
	top = clamp(top, 0, max(total - view, 0))
	m.top = top / S
	clip := Canvas{cv.px[y0 * cv.w:], cv.w, y1 - y0}
	ri :: proc(rows: []Ph_Row, id: string) -> int { for r, i in rows do if r.id == id do return i; return -1 }
	yy := -top
	for b in bl {
		if yy + b.h < 0 { yy += b.h; continue }
		if yy > clip.h do break
		on := b.id != "" && b.id == cur.id && !m.field
		if on { fill_rect(&clip, 0, yy, w, b.h, argb(sel, 0xff)) }
		if b.id != "" && yy >= 0 && yy + b.h <= clip.h do hit_add(a, 0, y0 + yy, w, b.h, .Row, ri(rows, b.id), 0)
		switch b.kind {
		case 'H':
			hy := yy + 12 * S
			hx := px + spaced_w(m.f10b, strings.to_upper(b.text, context.temp_allocator), S)
			spaced(&clip, m.f10b, strings.to_upper(b.text, context.temp_allocator), px, hy, 15 * S, H.dim, S)
			if b.count != "" {
				cw := tw(m.f10, b.count) + 10 * S
				fill_rect(&clip, hx + 8 * S, hy, cw, 15 * S, argb(sel, 0xff))
				text_in(&clip, m.f10, b.count, hx + 13 * S, hy, 15 * S, argb(b.cc, 0xff))
			}
			text_in(&clip, m.f10, b.right, w - px - tw(m.f10, b.right), hy, 15 * S, argb(H.faint, 0xff))
		case 'T': // a hint
			for l, k in wrap_text(m.f11, b.text, w - 2 * px) do text_in(&clip, m.f11, l, px, yy + 6 * S + k * 17 * S, 17 * S, argb(H.faint, 0xff))
		case 'q':
			x := m.queries[b.i]
			op :: proc(c, bg: u32, down: bool) -> u32 { return down ? mix(bg, c, 0.5) : c }
			if on do fill_rect(&clip, 0, yy, 3 * S, b.h, argb(x.blocked ? t.red : H.acc, 0xff))
			mine := x.tag == "YOUR ALLOW"
			mark, mc := x.blocked ? "×" : (mine ? "✓" : "·"), x.blocked ? t.red : (mine ? t.green : H.faint)
			text_in(&clip, m.f12b, mark, px + (14 * S - tw(m.f12b, mark)) / 2, yy + 4 * S, 16 * S, argb(op(mc, H.bg, down), 0xff))
			lx := px + 23 * S
			meta := on ? (x.blocked ? "↵ allow" : "⌃B block") : ""
			mw := meta != "" ? tw(m.f11b, meta) + 8 * S : 0
			lab := ellipsize(m.f12, x.domain, w - lx - px - mw - 70 * S)
			text_in(&clip, m.f12, lab, lx, yy + 4 * S, 16 * S, argb(op(x.blocked ? t.red : H.fg, H.bg, down), 0xff))
			if x.tag != "" {
				tc := x.blocked ? mix(H.bg, t.red, 0.8) : (mine ? t.green : H.faint)
				tagx := lx + tw(m.f12, lab) + 7 * S
				tgw := tw(m.f9b, x.tag) + 8 * S
				rounded_rect(&clip, tagx, yy + 6 * S, tgw, 12 * S, 0, 0, f32(S), argb(op(tc, H.bg, down), 0xff))
				text_in(&clip, m.f9b, x.tag, tagx + 4 * S, yy + 6 * S, 12 * S, argb(op(tc, H.bg, down), 0xff))
			}
			text_in(&clip, m.f10, ellipsize(m.f10, fmt.tprintf("%s · %s · %s", x.dev, x.at, x.type), w - lx - px - mw), lx, yy + 21 * S, 13 * S, argb(op(H.dim, H.bg, down), 0xff))
			if meta != "" do text_in(&clip, m.f11b, meta, w - px - tw(m.f11b, meta), yy, b.h, argb(x.blocked ? t.green : t.red, 0xff))
		case 'c':
			c := m.cls[b.i]
			if on do fill_rect(&clip, 0, yy, 3 * S, b.h, argb(H.acc, 0xff))
			lx := px + 23 * S
			text_in(&clip, m.f12, c.name, lx, yy, b.h, argb(H.fg, 0xff))
			n := ph_num(c.count)
			nx := w - px - tw(m.f11, n)
			text_in(&clip, m.f11, n, nx, yy, b.h, argb(soft, 0xff))
			bx := nx - 9 * S - 70 * S
			fill_rect(&clip, bx, yy + (b.h - 3 * S) / 2, 70 * S, 3 * S, argb(H.line, 0xff))
			top_n := len(m.cls) > 0 ? max(m.cls[0].count, 1) : 1
			fill_rect(&clip, bx, yy + (b.h - 3 * S) / 2, 70 * S * c.count / top_n, 3 * S, argb(H.acc, 0xff))
		case 'l':
			l := m.lists[b.i]
			if on do fill_rect(&clip, 0, yy, 3 * S, b.h, argb(H.acc, 0xff))
			tc := l.on ? t.green : H.faint
			tgx, tgy := px + 23 * S, yy + (b.h - 12 * S) / 2
			rounded_rect(&clip, tgx, tgy, 24 * S, 12 * S, 0, 0, f32(S), argb(tc, 0xff))
			fill_rect(&clip, l.on ? tgx + 24 * S - 10 * S : tgx + 2 * S, tgy + 2 * S, 8 * S, 8 * S, argb(tc, 0xff))
			meta := on ? fmt.tprintf("%s · ↵", l.on ? "on" : "off") : ph_num(l.count)
			text_in(&clip, m.f11, meta, w - px - tw(m.f11, meta), yy, b.h, argb(on ? H.acc : (l.on ? soft : H.faint), 0xff))
			lx := tgx + 33 * S
			text_in(&clip, m.f12, ellipsize(m.f12, l.name, w - lx - px - tw(m.f11, meta) - 10 * S), lx, yy, b.h, argb(l.on ? H.fg : H.dim, 0xff))
		case 'g':
			if on do fill_rect(&clip, 0, yy, 3 * S, b.h, argb(H.acc, 0xff))
			run := m.grav_running
			mark := run ? "◐" : "↻"
			text_in(&clip, m.f12b, mark, px + (14 * S - tw(m.f12b, mark)) / 2, yy, b.h, argb(run ? H.acc : H.dim, 0xff))
			text_in(&clip, m.f12, run ? "Updating gravity…" : "Update gravity", px + 23 * S, yy, b.h, argb(run ? H.acc : H.fg, 0xff))
			meta := run ? fmt.tprintf("%d lines", len(m.grav)) : (len(m.grav) > 0 ? "done · just now" : fmt.tprintf("%s · %s", ph_num(m.grav_domains), m.grav_ago))
			text_in(&clip, m.f11, meta, w - px - tw(m.f11, meta), yy, b.h, argb(run ? H.acc : H.dim, 0xff))
		case 'G': // gravity's lines as they come: 20 segments, the last few lines
			bx, by := 37 * S, yy + 4 * S
			bw, bh := w - bx - px, b.h - 10 * S
			fill_rect(&clip, bx, by, bw, bh, argb(H.panel, 0xff))
			rounded_rect(&clip, bx, by, bw, bh, 0, 0, f32(S), argb(H.line, 0xff))
			expect := max(6 * m.lists_on + 8, len(m.grav) + 1)
			done := m.grav_running ? len(m.grav) * 20 / expect : 20
			segw := (bw - 20 * S - 19 * 2 * S) / 20
			for k in 0 ..< 20 do fill_rect(&clip, bx + 10 * S + k * (segw + 2 * S), by + 8 * S, segw, 3 * S, argb(k < done ? H.acc : H.line, 0xff))
			from := max(len(m.grav) - 5, 0)
			for l, k in m.grav[from:] {
				last := from + k == len(m.grav) - 1 && m.grav_running
				ly := by + 16 * S + k * 14 * S
				text_in(&clip, m.f10, last ? "›" : "✓", bx + 10 * S, ly, 14 * S, argb(last ? H.acc : t.green, 0xff))
				text_in(&clip, m.f10, ellipsize(m.f10, l, bw - 38 * S), bx + 28 * S, ly, 14 * S, argb(last ? H.fg : H.dim, 0xff))
			}
		case 'e':
			e := m.entries[b.i]
			if on do fill_rect(&clip, 0, yy, 3 * S, b.h, argb(H.acc, 0xff))
			allow := e.type == "allow"
			tag := allow ? "ALLOW" : "DENY"
			tc := allow ? t.green : t.red
			lx := px + 23 * S
			ty := e.note != "" ? yy + 4 * S : yy + (b.h - 16 * S) / 2
			tgw := tw(m.f9b, tag) + 8 * S
			rounded_rect(&clip, lx, ty + 2 * S, tgw, 12 * S, 0, 0, f32(S), argb(tc, 0xff))
			text_in(&clip, m.f9b, tag, lx + 4 * S, ty + 2 * S, 12 * S, argb(tc, 0xff))
			meta := on ? "Del" : (e.kind == "regex" ? "regex" : "")
			text_in(&clip, m.f12, ellipsize(m.f12, e.domain, w - lx - tgw - 7 * S - px - 40 * S), lx + tgw + 7 * S, ty, 16 * S, argb(H.fg, 0xff))
			if e.note != "" do text_in(&clip, m.f10, ellipsize(m.f10, fmt.tprintf("%s · %s", e.kind, e.note), w - lx - px), lx, yy + 21 * S, 13 * S, argb(H.dim, 0xff))
			if meta != "" do text_in(&clip, on ? m.f11b : m.f11, meta, w - px - tw(m.f11b, meta), yy, b.h, argb(on ? t.red : H.dim, 0xff))
		}
		yy += b.h
	}
}

// Setup in place of it all: the app password (pasted) or a changed certificate.
@(private = "file")
ph_draw_setup :: proc(a: ^App, cv: ^Canvas, m: ^Pihole, S: int, H: HUD, y0, y1: int, rows: []Ph_Row) {
	t := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	sel := mix(H.bg, H.acc, 0.07)
	w := cv.w
	px := 14 * S
	cert := m.state == "cert"
	c := cert ? t.red : H.acc
	y := y0 + 14 * S
	fill_rect(cv, px, y, 36 * S, 36 * S, argb(c, 0x14))
	rounded_rect(cv, px, y, 36 * S, 36 * S, 0, 0, f32(S), argb(c, 0xff))
	shape_draw(cv, cert ? .Shield_Broken : .Key, px + 8 * S, y + 8 * S, 20 * S, c)
	tx := px + 48 * S
	text_in(cv, m.f15b, cert ? "Certificate changed" : "Connect Pi-hole", tx, y, 20 * S, argb(c, 0xff))
	text_in(cv, m.f11, ellipsize(m.f11, m.sub, w - tx - px), tx, y + 21 * S, 15 * S, argb(H.dim, 0xff))
	y += 36 * S + 10 * S
	body := cert ? "Pi-hole sent a certificate k4 hasn’t seen before. That’s expected after a Pi-hole update or a new self-signed cert; if neither happened, compare it with the web admin first." :
		"k4 needs an app password to read Pi-hole. In Pi-hole: Settings › Web interface / API › Configure app password, then paste it here. It goes to the keyring, never to a file."
	for l in wrap_text(m.f12, body, w - 2 * px) { text_in(cv, m.f12, l, px, y, 18 * S, argb(soft, 0xff)); y += 18 * S }
	y += 10 * S
	if !cert { // the field: what was pasted, masked (a host shows as typed)
		fill_rect(cv, px, y, w - 2 * px, 36 * S, argb(H.panel, 0xff))
		rounded_rect(cv, px, y, w - 2 * px, 36 * S, 0, 0, f32(S), argb(mix(H.bg, H.acc, 0.5), 0xff))
		fill_rect(cv, px, y, 3 * S, 36 * S, argb(H.acc, 0xff))
		text_in(cv, m.f12b, "›", px + 10 * S, y, 36 * S, argb(H.acc, 0xff))
		hint := m.host_mode ? "↵ uses this host" : "⌃V paste · ↵ connect"
		pw := string(m.pw[:])
		shown := m.host_mode ? pw : strings.repeat("•", min(len(pw), 24), context.temp_allocator)
		if pw == "" do shown = m.host_mode ? "Host or IP…" : "Paste the app password…"
		text_in(cv, m.f12, shown, px + 26 * S, y, 36 * S, argb(pw == "" ? H.faint : H.fg, 0xff))
		text_in(cv, m.f10, hint, w - px - 10 * S - tw(m.f10, hint), y, 36 * S, argb(H.dim, 0xff))
		y += 36 * S + 10 * S
	} else {
		for f in m.fps {
			isnew := f.label == "NEW"
			lines := ph_wrap_chars(m.f11, f.fp, w - 2 * px - 20 * S)
			bh := (16 + 16 * len(lines) + 4) * S
			fill_rect(cv, px, y, w - 2 * px, bh, argb(H.panel, 0xff))
			rounded_rect(cv, px, y, w - 2 * px, bh, 0, 0, f32(S), argb(isnew ? mix(H.bg, t.red, 0.6) : H.line, 0xff))
			spaced(cv, m.f10b, f.label, px + 10 * S, y + 6 * S, 12 * S, isnew ? t.red : H.dim, S)
			text_in(cv, m.f10, f.when_, w - px - 10 * S - tw(m.f10, f.when_), y + 6 * S, 12 * S, argb(H.dim, 0xff))
			for l, k in lines do text_in(cv, m.f11, l, px + 10 * S, y + 20 * S + k * 16 * S, 16 * S, argb(isnew ? H.fg : H.dim, 0xff))
			y += bh + 6 * S
		}
		y += 4 * S
	}
	cur, _ := ph_cur(m)
	labels := cert ? [][3]string{{"✓", "Trust the new certificate", "↵"}, {"↗", "Compare in the web admin", "Settings › System"}, {"×", "Keep the old one", "stay disconnected"}} :
		[][3]string{{"↗", "Open the web admin", m.host}, {"⇄", "A different host…", "IP or name"}}
	for l, i in labels {
		if i >= len(rows) do break
		on := rows[i].id == cur.id && !m.field
		if on { fill_rect(cv, px - 4 * S, y, w - 2 * px + 8 * S, 34 * S, argb(sel, 0xff)); fill_rect(cv, px - 4 * S, y, 3 * S, 34 * S, argb(H.acc, 0xff)) }
		mc := cert && i == 0 ? t.green : H.dim
		text_in(cv, m.f13, l[0], px + 6 * S, y, 34 * S, argb(mc, 0xff))
		text_in(cv, m.f13, l[1], px + 30 * S, y, 34 * S, argb(H.fg, 0xff))
		text_in(cv, m.f11, l[2], w - px - tw(m.f11, l[2]), y, 34 * S, argb(H.dim, 0xff))
		hit_add(a, px - 4 * S, y, w - 2 * px + 8 * S, 34 * S, .Row, i, 0)
		y += 34 * S
	}
	_ = y1
}

// A fingerprint has no spaces to wrap at: it breaks wherever the line is full.
@(private = "file")
ph_wrap_chars :: proc(f: ^Font, s: string, w: int) -> []string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	start, last := 0, 0
	for _, i in s {
		if i > start && tw(f, s[start:i]) > w { append(&out, s[start:last]); start = last }
		last = i
	}
	if start < len(s) do append(&out, s[start:])
	return out[:]
}

// --dump: the window as text (tests).
ph_dump :: proc(a: ^App) -> string {
	m := PH(a)
	sb := strings.builder_make(context.temp_allocator)
	left := ph_left(m)
	fmt.sbprintfln(&sb, "pihole %s · %s", m.state, m.host)
	switch m.state {
	case "setup", "cert":
		fmt.sbprintfln(&sb, "setup %s · %s", m.state == "cert" ? "Certificate changed" : "Connect Pi-hole", m.sub)
		for f in m.fps do fmt.sbprintfln(&sb, "fp %s %s", f.label, f.fp)
		if len(m.pw) > 0 do fmt.sbprintfln(&sb, "field %s", m.host_mode ? string(m.pw[:]) : strings.repeat("•", len(m.pw), context.temp_allocator))
	case:
		title := m.state == "down" ? "DNS down" : (left != 0 ? (left > 0 ? fmt.tprintf("Blocking off %s", ph_mmss(left)) : "Blocking off") : "Blocking on")
		fmt.sbprintfln(&sb, "status %s · %d queries · %d blocked · %.1f%% · %d clients", title, m.total, m.blocked, m.pct, m.active)
		fmt.sbprintfln(&sb, "unbound %s · %d ms · %d%% hits", m.ukind, m.ums, m.uhit)
		fmt.sbprintfln(&sb, "find %s%s", string(m.q[:]), m.field ? "|" : "")
	}
	cur, _ := ph_cur(m)
	for r in ph_rows(m) {
		mark := r.id == cur.id && !m.field ? "*" : " "
		switch r.kind {
		case 'p':
			lens := [3]string{"5 min", "30 min", "until resumed"}
			fmt.sbprintfln(&sb, "%s pause %s", mark, left != 0 ? "resume" : lens[m.pz])
		case 'r': fmt.sbprintfln(&sb, "%s unbound %s", mark, m.ukind == "nossh" ? "set up ssh" : (m.state == "down" ? "restart FTL" : "restart"))
		case 'q': x := m.queries[r.i]; fmt.sbprintfln(&sb, "%s %s %s%s · %s", mark, x.blocked ? "×" : "·", x.domain, x.tag != "" ? fmt.tprintf(" [%s]", x.tag) : "", x.dev)
		case 'c': fmt.sbprintfln(&sb, "%s client %s %d", mark, m.cls[r.i].name, m.cls[r.i].count)
		case 'l': l := m.lists[r.i]; fmt.sbprintfln(&sb, "%s list %s %s", mark, l.on ? "on" : "off", l.name)
		case 'g': fmt.sbprintfln(&sb, "%s gravity %s%s", mark, m.grav_ago, m.grav_running ? " · running" : "")
		case 'e': e := m.entries[r.i]; fmt.sbprintfln(&sb, "%s %s %s", mark, e.type, e.domain)
		case 's': fmt.sbprintfln(&sb, "%s %s", mark, r.id)
		}
	}
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
