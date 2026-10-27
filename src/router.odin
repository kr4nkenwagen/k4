package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --router: the OpenWrt router (the Kestrel design's Router window). 980×600 centred, 680×560
// under the bar module. Six pages (Tab, Alt 1–6): Overview (memory, load and WAN tiles with
// sparklines, the radios, the newest clients), System (key/value, Reboot), WAN (in above the
// line, out below), Wireless (a switch per radio; off asks when this machine is on it; saved
// but not applied offers a reboot), Clients (filter; ↵ copies the IP, ^M the MAC) and Log
// (filter, ^S the level). Unreachable, no password, login failed and rebooting take the page.
// ^K sets the router password (kept in the keyring), ^R reboots, r refreshes. Data from
// k4-router: G S W H Q C lines, and
//   R <command>: "VERB ARGS" (its last line is the footer; k4:close closes)
//   L <command>: the data again (every 3 s)      O <command>: the log (T time level text)

ROUTER_W, ROUTER_H :: 980, 600
ROUTER_PW, ROUTER_PH :: 680, 560

Rt_Radio :: struct { id, band, channel, width, ssids: string, clients: int, on, mine, pending: bool }
Rt_Client :: struct { host, ip, mac, lease, band, tag: string }
Rt_Log :: struct { time, sev, text: string }

Rt_Async :: struct { proc_: os.Process, out: string, running: bool }

Router :: struct {
	page: int,
	status, host, user, scheme, err: string,
	last_seen, reboot_at, now: i64,
	have_sys, have_wan: bool,
	model, hostname, release, kernel: string,
	uptime: i64,
	mem_used, mem_total: f32,
	load: [3]f32,
	wan_up: bool,
	wan_ip: string,
	wan_uptime: i64,
	rx_rate, tx_rate, peak: f32,
	rx_total, tx_total: f64,
	down_since: i64,
	hist_mem, hist_load, hist_rx, hist_tx: [dynamic]f32,
	radios: [dynamic]Rt_Radio,
	clients: [dynamic]Rt_Client,
	logs: [dynamic]Rt_Log,
	log_loaded: bool,
	runner, loader, logger: string,
	sel: int,
	sev: int, // 0 all, 1 err, 2 warn, 3 notice
	band: string, // "" reboot radiooff
	asking_pw: bool, // ^K over a working connection
	pw: [dynamic]u8,
	show_pw: bool,
	loaded: bool,
	toast: string,
	toast_hot: bool,
	load_job, log_job: Rt_Async,
	load_at, log_at: time.Tick,
	f9b, f10, f10b, f11, f11b, f12, f12b, f13b, f14b, f20b: ^Font,
}

router_setup :: proc(a: ^App, data: string) {
	r := new(Router)
	a.router = r
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	r.f10, r.f11, r.f12 = reg(a, 10), reg(a, 11), reg(a, 12)
	r.f9b, r.f10b, r.f11b, r.f12b, r.f13b, r.f14b, r.f20b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 14), bld(a, 20)
	switch a.opts.open { case "system", "2": r.page = 1; case "wan", "3": r.page = 2; case "wireless", "4": r.page = 3; case "clients", "5": r.page = 4; case "log", "6": r.page = 5 }
	router_parse(r, data)
	r.load_at = time.tick_now()
	if r.page == 5 do router_load_log(r)
}

@(private = "file")
router_parse :: proc(r: ^Router, data: string) {
	clear(&r.hist_mem); clear(&r.hist_load); clear(&r.hist_rx); clear(&r.hist_tx)
	clear(&r.radios); clear(&r.clients)
	r.have_sys, r.have_wan = false, false
	text := data
	pf :: proc(s: string) -> f32 { v, _ := strconv.parse_f32(s); return v }
	pi :: proc(s: string) -> i64 { v, _ := strconv.parse_i64(s); return v }
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		g :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "R": r.runner = g(f, 1)
		case "L": r.loader = g(f, 1)
		case "O": r.logger = g(f, 1)
		case "G":
			r.status, r.host, r.user, r.scheme = g(f, 1), g(f, 2), g(f, 3), g(f, 4)
			r.last_seen, r.reboot_at, r.now, r.err = pi(g(f, 5)), pi(g(f, 6)), pi(g(f, 7)), g(f, 8)
			r.loaded = true
		case "S":
			r.have_sys = true
			r.model, r.hostname, r.release, r.kernel = g(f, 1), g(f, 2), g(f, 3), g(f, 4)
			r.uptime, r.mem_used, r.mem_total = pi(g(f, 5)), pf(g(f, 6)), pf(g(f, 7))
			r.load = {pf(g(f, 8)), pf(g(f, 9)), pf(g(f, 10))}
		case "W":
			r.have_wan = true
			r.wan_up, r.wan_ip, r.wan_uptime = g(f, 1) == "1", g(f, 2), pi(g(f, 3))
			r.rx_rate, r.tx_rate = pf(g(f, 4)), pf(g(f, 5))
			r.rx_total, r.tx_total = f64(pi(g(f, 6))), f64(pi(g(f, 7)))
			r.down_since, r.peak = pi(g(f, 8)), pf(g(f, 9))
		case "H":
			append(&r.hist_mem, pf(g(f, 1))); append(&r.hist_load, pf(g(f, 2))); append(&r.hist_rx, pf(g(f, 3))); append(&r.hist_tx, pf(g(f, 4)))
		case "Q":
			n, _ := strconv.parse_int(g(f, 6))
			append(&r.radios, Rt_Radio{id = g(f, 1), band = g(f, 2), channel = g(f, 3), width = g(f, 4), ssids = g(f, 5), clients = n, on = g(f, 7) == "1", mine = g(f, 8) == "1", pending = g(f, 9) == "1"})
		case "C":
			append(&r.clients, Rt_Client{host = g(f, 1), ip = g(f, 2), mac = g(f, 3), lease = g(f, 4), band = g(f, 5), tag = g(f, 6)})
		}
	}
	if r.status == "" do r.status = "unreach"
}

// ---------- helpers ----------

@(private = "file")
rt_rate :: proc(b: f32) -> string { return b >= 1e6 ? fmt.tprintf("%.1f MB/s", b / 1e6) : fmt.tprintf("%.0f KB/s", b / 1e3) }
@(private = "file")
rt_bytes :: proc(b: f64) -> string { return b >= 1e9 ? fmt.tprintf("%.0f GB", b / 1e9) : fmt.tprintf("%.0f MB", b / 1e6) }
@(private = "file")
rt_dur :: proc(s: i64) -> string {
	switch {
	case s >= 86400: return fmt.tprintf("%d d %d h", s / 86400, s % 86400 / 3600)
	case s >= 3600: return fmt.tprintf("%d h %d min", s / 3600, s % 3600 / 60)
	case s >= 60: return fmt.tprintf("%d min %d s", s / 60, s % 60)
	}
	return fmt.tprintf("%d s", s)
}
@(private = "file")
rt_clock :: proc(epoch: i64) -> string {
	if epoch <= 0 do return "?"
	t := time.unix(epoch, 0)
	h, m, s := time.clock_from_time(time.time_add(t, time.Duration(rt_utc_offset()) * time.Second))
	return fmt.tprintf("%02d:%02d:%02d", h, m, s)
}
@(private = "file")
rt_utc_offset :: proc() -> i64 { // local time from the TZ the date command knows
	@(static) off: i64 = -1
	if off != -1 do return off
	_, out, _, err := os.process_exec({command = {"date", "+%z"}}, context.temp_allocator)
	off = 0
	z := strings.trim_space(string(out))
	if err == nil && len(z) == 5 {
		h, _ := strconv.parse_i64(z[1:3]); m, _ := strconv.parse_i64(z[3:5])
		off = (h * 3600 + m * 60) * (z[0] == '-' ? -1 : 1)
	}
	return off
}

@(private = "file")
rt_block :: proc(r: ^Router) -> string { // what takes the page: unreach nopass fail rebooting, or ""
	if r.asking_pw do return "nopass"
	switch r.status {
	case "unreach", "nopass", "fail", "rebooting": return r.status
	}
	return ""
}

@(private = "file")
rt_busy :: proc(r: ^Router) -> bool { return r.have_sys && ((r.mem_total > 0 && r.mem_used / r.mem_total > 0.8) || r.load[0] > 2) }

@(private = "file")
rt_async_start :: proc(j: ^Rt_Async, cmd, tag: string) {
	if j.running do return
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	j.out = fmt.aprintf("%s/k4-router-%s.out", run != "" ? run : "/tmp", tag)
	p, err := os.process_start({command = {"sh", "-c", fmt.tprintf("%s > %s 2>/dev/null", cmd, sh_quote(j.out))}})
	if err != nil do return
	j.proc_, j.running = p, true
}

@(private = "file")
rt_async_done :: proc(j: ^Rt_Async) -> (text: string, done: bool) {
	if !j.running do return
	st, _ := os.process_wait(j.proc_, 0)
	if !st.exited do return
	j.running = false
	data, err := os.read_entire_file(j.out, context.temp_allocator)
	if err == nil do text = string(data)
	return text, true
}

@(private = "file")
router_load_log :: proc(r: ^Router) {
	if r.logger == "" do return
	r.log_at = time.tick_now()
	rt_async_start(&r.log_job, r.logger, "log")
}

@(private = "file")
rt_run :: proc(a: ^App, args: ..string) -> string {
	r := a.router
	if r.runner == "" { r.toast = fmt.aprintf("(%s)", strings.join(args, " ", context.temp_allocator)); r.toast_hot = false; return "" } // tests
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, r.runner)
	for x in args { strings.write_byte(&sb, ' '); strings.write_string(&sb, sh_quote(x)) }
	env: [dynamic]string
	env.allocator = context.temp_allocator
	if len(r.pw) > 0 { // the password goes in the environment, never on the command line
		envs, _ := os.environ(context.temp_allocator)
		for e in envs do append(&env, e)
		append(&env, strings.concatenate({"K4_INPUT=", string(r.pw[:])}, context.temp_allocator))
	}
	_, out, _, _ := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}, env = len(env) > 0 ? env[:] : nil}, context.temp_allocator)
	lines := strings.split_lines(strings.trim_space(string(out)), context.temp_allocator)
	last := len(lines) > 0 ? lines[len(lines) - 1] : ""
	if last == "k4:close" { a.exit = 0; a.done = true; return last }
	r.toast = strings.clone(last)
	r.toast_hot = strings.has_prefix(last, "Can") || strings.has_prefix(last, "Still") || strings.has_prefix(last, "The router") || strings.has_prefix(last, "Not logged") || strings.has_prefix(last, "Could not")
	r.load_at = {} // the change shows on the next poll
	return last
}

// Every tick: the data again every 3 s, the log while its page shows; true when something changed.
router_tick :: proc(a: ^App) -> bool {
	r := a.router
	changed := false
	if text, done := rt_async_done(&r.load_job); done && strings.contains(text, "\nG\t") {
		router_parse(r, text)
		changed = true
	}
	if text, done := rt_async_done(&r.log_job); done {
		clear(&r.logs)
		t := text
		for line in strings.split_lines_iterator(&t) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) >= 4 && f[0] == "T" do append(&r.logs, Rt_Log{strings.clone(f[1]), strings.clone(f[2]), strings.clone(f[3])})
		}
		r.log_loaded = true
		changed = true
	}
	if r.loader != "" && !r.load_job.running && time.tick_diff(r.load_at, time.tick_now()) > 3 * time.Second {
		r.load_at = time.tick_now()
		rt_async_start(&r.load_job, r.loader, "data")
	}
	if r.page == 5 && !r.log_job.running && time.tick_diff(r.log_at, time.tick_now()) > 3 * time.Second do router_load_log(r)
	if r.status == "rebooting" do changed = true // the count
	return changed
}

// ---------- lists ----------

@(private = "file")
rt_clients :: proc(a: ^App) -> []Rt_Client {
	r := a.router
	q := strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator)
	out := make([dynamic]Rt_Client, 0, len(r.clients), context.temp_allocator)
	for c in r.clients {
		if q != "" && !strings.contains(strings.to_lower(fmt.tprintf("%s %s %s", c.host, c.ip, c.mac), context.temp_allocator), q) do continue
		append(&out, c)
	}
	return out[:]
}

@(private = "file")
rt_logs :: proc(a: ^App) -> []Rt_Log {
	r := a.router
	q := strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator)
	rank :: proc(s: string) -> int { switch s { case "err": return 0; case "warn": return 1; case "notice": return 2 }; return 3 }
	out := make([dynamic]Rt_Log, 0, len(r.logs), context.temp_allocator)
	for l in r.logs {
		if r.sev > 0 && rank(l.sev) > r.sev - 1 do continue
		if q != "" && !strings.contains(strings.to_lower(l.text, context.temp_allocator), q) do continue
		append(&out, l)
	}
	return out[:]
}

@(private = "file")
rt_host :: proc(c: Rt_Client) -> string { return c.host == "*" || c.host == "" ? "(no name)" : c.host }

// ---------- keys ----------

@(private = "file")
rt_go :: proc(a: ^App, page: int) {
	r := a.router
	r.page, r.sel, r.band, r.toast = page, 0, "", ""
	clear(&a.query); a.cursor = 0
	if page == 5 && !r.log_job.running do router_load_log(r)
}

@(private = "file")
rt_flip :: proc(a: ^App, i: int, confirmed: bool) {
	r := a.router
	if i < 0 || i >= len(r.radios) do return
	q := r.radios[i]
	if q.on && q.mine && !confirmed { r.band, r.sel = "radiooff", i; return }
	r.band = ""
	rt_run(a, "radio", q.id, q.on ? "off" : "on")
	r.radios[i].on = !q.on
	if strings.contains(r.toast, "next reboot") do r.radios[i].pending = true
}

router_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	r := a.router
	if ctrl && (ch == 'c' || ch == 'g') { a.exit = 1; a.done = true; return true }
	block := rt_block(r)
	if block != "" {
		switch {
		case block == "nopass" || block == "fail":
			switch {
			case k == .Tab: r.show_pw = !r.show_pw
			case k == .Enter && len(r.pw) > 0:
				rt_run(a, "password")
				clear(&r.pw)
				if !r.toast_hot { r.asking_pw = false; r.status = "ok"; r.load_at = {} } else do r.status = "fail"
			case k == .Escape:
				if r.asking_pw { r.asking_pw = false; clear(&r.pw) } else { r.toast = "The bar module stays dim until a password is saved"; a.exit = 1; a.done = true }
			case k == .Backspace: if len(r.pw) > 0 { _, n := utf8.decode_last_rune(r.pw[:]); resize(&r.pw, len(r.pw) - n) }
			case text != "" && !ctrl: append(&r.pw, ..transmute([]u8)text)
			}
		case block == "unreach":
			switch {
			case text == "r" || k == .Enter: rt_run(a, "retry")
			case text == "o": rt_run(a, "luci")
			case k == .Escape: a.exit = 1; a.done = true
			}
		case block == "rebooting": if k == .Escape { a.exit = 1; a.done = true }
		}
		return true
	}
	if r.band == "reboot" || r.band == "radiooff" {
		switch {
		case text == "y":
			if r.band == "reboot" { r.band = ""; rt_run(a, "reboot"); if !r.toast_hot { r.status = "rebooting"; r.reboot_at = time.to_unix_seconds(time.now()) } }
			else do rt_flip(a, r.sel, true)
		case text == "n" || k == .Escape: r.band = ""
		}
		return true
	}
	switch {
	case k == .Tab || k == .Back_Tab: rt_go(a, (r.page + (k == .Tab ? 1 : 5)) % 6); return true
	case alt && ch >= '1' && ch <= '6': rt_go(a, int(ch - '1')); return true
	case ctrl && ch == 'r': r.page, r.band, r.toast = 1, "reboot", ""; return true
	case ctrl && ch == 'k': r.asking_pw = true; clear(&r.pw); return true
	}
	switch r.page {
	case 3:
		n := len(r.radios)
		switch {
		case k == .Down: r.sel = min(r.sel + 1, max(n - 1, 0))
		case k == .Up: r.sel = max(r.sel - 1, 0)
		case k == .Enter || text == " ": rt_flip(a, r.sel, false)
		case ctrl && ch == 'r': r.band = "reboot"
		case text == "r": r.load_at = {}; r.toast = "Refreshing…"
		case k == .Escape:
			if radios_saved(r, a) { for &q in r.radios do q.pending = false } else { a.exit = 1; a.done = true }
		case: return false
		}
	case 4, 5:
		list_n := r.page == 4 ? len(rt_clients(a)) : len(rt_logs(a))
		switch {
		case k == .Down && r.page == 4: r.sel = min(r.sel + 1, max(list_n - 1, 0))
		case k == .Up && r.page == 4: r.sel = max(r.sel - 1, 0)
		case k == .Enter && r.page == 4:
			l := rt_clients(a)
			if r.sel < len(l) do rt_run(a, "copy", l[r.sel].ip, fmt.tprintf("%s · %s", l[r.sel].ip, rt_host(l[r.sel])))
		case ctrl && ch == 'm' && r.page == 4:
			l := rt_clients(a)
			if r.sel < len(l) do rt_run(a, "copy", l[r.sel].mac, l[r.sel].mac)
		case ctrl && ch == 's' && r.page == 5: r.sev = (r.sev + 1) % 4
		case k == .Escape:
			if len(a.query) > 0 { clear(&a.query); a.cursor = 0 } else { a.exit = 1; a.done = true }
		case:
			before := len(a.query)
			res := app_edit_key(a, k, ctrl, ch, text)
			if len(a.query) != before do r.sel = 0
			return res
		}
	case:
		switch {
		case text == "r": r.load_at = {}; r.toast = "Refreshing…"
		case k == .Escape: a.exit = 1; a.done = true
		case: return false
		}
	}
	return true
}

// The Wireless page's "saved, not applied" band shows while a radio change waits for a reboot.
@(private = "file")
radios_saved :: proc(r: ^Router, a: ^App) -> bool {
	for q in r.radios do if q.pending do return true
	return false
}

router_click :: proc(a: ^App, x, y, button: int) -> bool {
	r := a.router
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Tab: rt_go(a, h.a)
	case .Section: rt_go(a, h.a) // a tile or a radio chip opens its page
	case .Row:
		if r.sel == h.a do router_key(a, .Enter, false, false, 0, "")
		else do r.sel = h.a
	case .Chip:
		switch h.b {
		case 0: // the block card's buttons
			keys := [2]Key{.Enter, .Escape}
			if rt_block(r) == "unreach" && h.a == 1 do router_key(a, .None, false, false, 'o', "o")
			else do router_key(a, keys[min(h.a, 1)], false, false, 0, "")
		case 1: // the band's buttons: yes, no / reboot, later
			if r.band != "" do router_key(a, .None, false, false, h.a == 0 ? 'y' : 'n', h.a == 0 ? "y" : "n")
			else if h.a == 0 do router_key(a, .None, true, false, 'r', "")
			else do router_key(a, .Escape, false, false, 0, "")
		case 2: r.sev = h.a // the level chips
		case 3: r.asking_pw = true; clear(&r.pw) // the footer's password button
		}
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
rt_btn :: proc(a: ^App, cv: ^Canvas, S, x, y: int, label, key: string, kind: int, id, group: int, H: HUD, soft: u32, f, fk: ^Font, h := 26) -> int {
	// kind 0 plain, 1 accent, 2 alarm
	bw := tw(f, label) + 6 * S + tw(fk, key) + 20 * S
	bc := kind == 2 ? H.hot : H.acc
	if kind > 0 do fill_rect(cv, x, y, bw, h * S, argb(bc, 0xff))
	rounded_rect(cv, x, y, bw, h * S, 0, 0, f32(S), argb(kind > 0 ? bc : H.line, 0xff))
	text_in(cv, f, label, x + 10 * S, y, h * S, argb(kind > 0 ? H.bg : soft, 0xff))
	text_in(cv, fk, key, x + 10 * S + tw(f, label) + 6 * S, y, h * S, argb(kind > 0 ? H.bg : H.dim, 0xff))
	hit_add(a, x, y, bw, h * S, .Chip, id, group)
	return bw
}

@(private = "file")
rt_spark :: proc(cv: ^Canvas, x, y, w, h: int, vals: []f32, vmax: f32, c: u32, vals2: []f32 = nil, c2: u32 = 0) {
	if len(vals) == 0 || h <= 0 do return
	n := 40
	bw := f32(w - (n - 1)) / f32(n)
	off := n - len(vals)
	for i in 0 ..< len(vals) {
		v := clamp(vals[i] / max(vmax, 0.0001), 0, 1)
		bh := max(int(v * f32(h)), 1)
		bx := x + int(f32(i + off) * (bw + 1))
		fill_rect(cv, bx, y + h - bh, max(int(bw), 1), bh, argb(c, 0xff))
		if vals2 != nil && i < len(vals2) {
			v2 := clamp(vals2[i] / max(vmax, 0.0001), 0, v)
			b2 := int(v2 * f32(h))
			if b2 > 0 do fill_rect(cv, bx, y + h - b2, max(int(bw), 1), b2, argb(c2, 0xff))
		}
	}
}

router_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	r := a.router
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	pop := a.opts.popup.set
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	px := (pop ? 14 : 20) * S
	block := rt_block(r)
	now := time.to_unix_seconds(time.now())
	// the head: ROUTER / host · model · release · up, the pages, the WAN state
	hh := 56 * S
	ty := (hh - int(r.f13b.line_h) - 3 * S - int(r.f10.line_h)) / 2
	spaced(cv, r.f13b, "ROUTER", px, ty, int(r.f13b.line_h), H.acc, 2 * S, true)
	sub := r.have_sys ? (pop ? fmt.tprintf("%s · %s · up %s", r.hostname, r.model, rt_dur(r.uptime)) : fmt.tprintf("%s · %s · %s · up %s", r.hostname, r.model, r.release, rt_dur(r.uptime))) : r.host
	wan_l, wan_c := "WAN UP", t.green
	poll_l := "ubus · every 3 s"
	switch {
	case block == "unreach": wan_l, wan_c, poll_l = "UNREACHABLE", H.hot, "retrying every 30 s"
	case block == "rebooting": wan_l, wan_c, poll_l = "REBOOTING", t.yellow, "waiting for it"
	case block != "": wan_l, wan_c, poll_l = "NOT CONNECTED", H.dim, "not polling"
	case !r.loaded: wan_l, wan_c, poll_l = "CONNECTING…", H.dim, "first poll…"
	case !r.wan_up: wan_l, wan_c = "WAN DOWN", H.hot
	case: wan_l = fmt.tprintf("WAN UP · %s", r.wan_ip)
	}
	rw := max(tw(r.f10b, wan_l) + 12 * S, tw(r.f10, poll_l))
	// the sub line sits under the title; the tabs start after it
	tx := px + max(spaced_w(r.f13b, "ROUTER", 2 * S), min(tw(r.f10, sub), (pop ? 150 : 260) * S)) + 18 * S
	text_in(cv, r.f10, ellipsize(r.f10, sub, tx - px - 14 * S), px, ty + int(r.f13b.line_h) + 3 * S, int(r.f10.line_h), argb(H.dim, 0xff))
	names := [6]string{"OVERVIEW", "SYSTEM", "WAN", "WIRELESS", "CLIENTS", "LOG"}
	new_n, err_n := 0, 0
	for c in r.clients do if c.tag == "NEW" do new_n += 1
	for l in r.logs do if l.sev == "err" do err_n += 1
	tab_end := w - px - rw - 10 * S
	for l, i in names {
		lbl := pop ? l[:min(4, len(l))] : l
		on := i == r.page
		k := fmt.tprint(i + 1)
		badge := ""
		bc := H.acc
		switch i {
		case 2: if r.loaded && !r.wan_up && block == "" { badge, bc = "!", H.hot }
		case 4: if new_n > 0 do badge = fmt.tprint(new_n)
		case 5: if err_n > 0 { badge, bc = fmt.tprint(err_n), H.hot }
		}
		tp := (pop ? 7 : 11) * S
		bw := tw(r.f10b, lbl) + 5 * S + tw(r.f10, k) + (badge != "" ? tw(r.f9b, badge) + 11 * S : 0) + 2 * tp
		if tx + bw > tab_end do break
		text_in(cv, r.f10b, lbl, tx + tp, 0, hh, argb(on ? H.fg : H.dim, 0xff))
		kx := tx + tp + tw(r.f10b, lbl) + 5 * S
		text_in(cv, r.f10, k, kx, 0, hh, argb(H.faint, 0xff))
		if badge != "" {
			bx := kx + tw(r.f10, k) + 5 * S
			bwid := tw(r.f9b, badge) + 6 * S
			fill_rect(cv, bx, (hh - 12 * S) / 2, bwid, 12 * S, argb(bc, 0xff))
			text_in(cv, r.f9b, badge, bx + 3 * S, (hh - 12 * S) / 2, 12 * S, argb(H.bg, 0xff))
		}
		if on do fill_rect(cv, tx, hh - 2 * S, bw, 2 * S, argb(H.acc, 0xff))
		hit_add(a, tx, 0, bw, hh, .Tab, i, 0)
		tx += bw
	}
	ry := (hh - 2 * int(r.f10.line_h) - 3 * S) / 2
	wx := w - px - tw(r.f10b, wan_l)
	fill_rect(cv, wx - 12 * S, ry + (int(r.f10.line_h) - 6 * S) / 2, 6 * S, 6 * S, argb(wan_c, 0xff))
	text_in(cv, r.f10b, wan_l, wx, ry, int(r.f10.line_h), argb(wan_c, 0xff))
	text_in(cv, r.f10, poll_l, w - px - tw(r.f10, poll_l), ry + int(r.f10.line_h) + 3 * S, int(r.f10.line_h), argb(H.dim, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))

	fh := 30 * S
	fy := h - fh
	top := hh + S
	if block != "" do rt_draw_block(a, cv, S, top, fy, H, soft, block, now)
	else do rt_draw_page(a, cv, S, top, fy, H, soft, px, now)

	// the foot: key hints, the password button, the result
	for i in fy * w ..< h * w do cv.px[i] = 0
	fill_rect(cv, 0, fy, w, h - fy, argb(H.bg, a.bg_alpha))
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	HK: [][2]string
	switch {
	case block == "nopass" || block == "fail": HK = {{"↵", "Save"}, {"Tab", "Show"}, {"Esc", "Not now"}}
	case block == "unreach": HK = {{"r", "Retry"}, {"o", "LuCI"}, {"Esc", "Close"}}
	case block == "rebooting": HK = {{"Esc", "Hide"}}
	case r.band != "": HK = {{"y", "Yes"}, {"n Esc", "No"}}
	case r.page == 3: HK = {{"↑↓", "Radio"}, {"␣", "On / off"}, {"Tab", "Page"}, {"r", "Refresh"}}
	case r.page == 4: HK = {{"type", "Filter"}, {"↵", "Copy IP"}, {"^M", "MAC"}, {"Tab", "Page"}}
	case r.page == 5: HK = {{"type", "Filter"}, {"^S", "Level"}, {"Tab", "Page"}}
	case: HK = {{"Tab Alt 1–6", "Pages"}, {"r", "Refresh"}, {"^R", "Reboot"}, {"Esc", "Close"}}
	}
	kx := px
	for k in HK {
		kw := tw(r.f10, k[0]) + 8 * S
		rounded_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, r.f10, k[0], kx + 4 * S, fy, fh, argb(H.fg, 0xff))
		kx += kw + 5 * S
		text_in(cv, r.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(r.f10, k[1]) + 12 * S
	}
	pwl := r.status == "nopass" ? "⚿ no password" : "⚿ password in keyring"
	right := w - px
	if r.toast != "" {
		tt := ellipsize(r.f10, r.toast, max(right - kx - tw(r.f10, pwl) - 30 * S, 40 * S))
		text_in(cv, r.f10, tt, right - tw(r.f10, tt), fy, fh, argb(r.toast_hot ? H.hot : H.acc, 0xff))
		right -= tw(r.f10, tt) + 12 * S
	}
	if right - kx > tw(r.f10, pwl) + 12 * S {
		pw := tw(r.f10, pwl) + 12 * S
		rounded_rect(cv, right - pw, fy + (fh - 20 * S) / 2, pw, 20 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, r.f10, pwl, right - pw + 6 * S, fy, fh, argb(H.dim, 0xff))
		hit_add(a, right - pw, fy, pw, fh, .Chip, 0, 3)
	}
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 24)
}

// Unreachable, a password, rebooting: a card in the middle of the page.
@(private = "file")
rt_draw_block :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32, block: string, now: i64) {
	r := a.router
	t := a.theme
	w := cv.w
	title: string
	c := H.acc
	lines := make([dynamic][2]string, 0, 3, context.temp_allocator)
	field, count := false, false
	err := ""
	switch block {
	case "unreach":
		title, c = "Can’t reach the router", H.hot
		ago := r.last_seen > 0 ? fmt.tprintf("last seen %s (%s ago)", rt_clock(r.last_seen)[:5], rt_dur(now - r.last_seen)) : "not seen since k4 started"
		append(&lines, [2]string{fmt.tprintf("%s didn’t answer on %s · %s", r.host, r.scheme == "https" ? ":443" : ":80", ago), "fg"})
		append(&lines, [2]string{"Are you on the home network? Is the router rebooting? k4 keeps trying every 30 s.", "soft"})
	case "nopass", "fail":
		field = true
		if block == "fail" && !r.asking_pw {
			title, c = "Login failed", H.hot
			append(&lines, [2]string{fmt.tprintf("ubus login as %s was refused.", r.user), "soft"})
			err = "The router said no to that password. Type the right one to replace it."
		} else {
			title = fmt.tprintf("Connect to %s", r.host)
			append(&lines, [2]string{"k4 needs the router’s password to read it over ubus. Saved once, used every 3 s.", "soft"})
		}
	case "rebooting":
		el := now - r.reboot_at
		title, c, count = fmt.tprintf("Router rebooting · %d s", el), t.yellow, true
		append(&lines, [2]string{fmt.tprintf("Asked at %s. Usually back in about 90 s; this window comes back by itself when %s answers.", rt_clock(r.reboot_at), r.host), "soft"})
	}
	cw := 440 * S
	inner := cw - 40 * S
	wrapped := make([dynamic][2]string, 0, 6, context.temp_allocator)
	for l in lines do for wl in wrap_hard(r.f11, l[0], inner) do append(&wrapped, [2]string{wl, l[1]})
	ch := 18 * S + int(r.f14b.line_h) + 10 * S + len(wrapped) * 17 * S + (field ? 10 * S + int(r.f10.line_h) + 5 * S + 32 * S + (err != "" ? 5 * S + int(r.f10.line_h) : 0) + 5 * S + int(r.f10.line_h) : 0) + (count ? 10 * S + 4 * S : 0) + 12 * S + 26 * S + 18 * S
	cx := (w - cw) / 2
	cy := top + (fy - top - ch) / 2
	fill_rect(cv, cx, cy, cw, ch, c == H.acc ? argb(H.acc, 0x0d) : argb(c, 0x0d))
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, cx, cy, 3 * S, ch, argb(c, 0xff))
	y := cy + 18 * S
	text_in(cv, r.f14b, title, cx + 20 * S, y, int(r.f14b.line_h), argb(c, 0xff))
	y += int(r.f14b.line_h) + 10 * S
	for l in wrapped {
		text_in(cv, r.f11, l[0], cx + 20 * S, y, 17 * S, argb(l[1] == "fg" ? H.fg : soft, 0xff))
		y += 17 * S
	}
	if field {
		y += 10 * S
		text_in(cv, r.f10, fmt.tprintf("Password for %s@%s", r.user, r.host), cx + 20 * S, y, int(r.f10.line_h), argb(H.dim, 0xff))
		y += int(r.f10.line_h) + 5 * S
		fb := err != "" ? H.hot : H.acc
		fill_rect(cv, cx + 20 * S, y, inner, 32 * S, argb(H.bg, 0xff))
		rounded_rect(cv, cx + 20 * S, y, inner, 32 * S, 0, 0, f32(S), argb(fb, 0xff))
		shown := r.show_pw ? string(r.pw[:]) : strings.repeat("•", utf8.rune_count_in_string(string(r.pw[:])), context.temp_allocator)
		if shown == "" do text_in(cv, r.f12, "router password", cx + 30 * S, y, 32 * S, argb(H.hint, 0xff))
		else do text_in(cv, r.f12, shown, cx + 30 * S, y, 32 * S, argb(H.fg, 0xff))
		fill_rect(cv, cx + 30 * S + tw(r.f12, shown) + S, y + 9 * S, max(S, 2), 14 * S, argb(H.acc, 0xff))
		text_in(cv, r.f10, "Tab shows", cx + 20 * S + inner - 10 * S - tw(r.f10, "Tab shows"), y, 32 * S, argb(H.dim, 0xff))
		y += 32 * S
		if err != "" { y += 5 * S; text_in(cv, r.f10, ellipsize(r.f10, err, inner), cx + 20 * S, y, int(r.f10.line_h), argb(H.hot, 0xff)); y += int(r.f10.line_h) }
		y += 5 * S
		text_in(cv, r.f10, "Kept in the keyring, never in a file.", cx + 20 * S, y, int(r.f10.line_h), argb(H.dim, 0xff))
		y += int(r.f10.line_h)
	}
	if count {
		y += 10 * S
		p := clamp(f32(now - r.reboot_at) / 90, 0, 1)
		sw := (inner - 19 * 3 * S) / 20
		for i in 0 ..< 20 do fill_rect(cv, cx + 20 * S + i * (sw + 3 * S), y, sw, 4 * S, argb(i < int(p * 20 + 0.5) ? t.yellow : H.line, 0xff))
		y += 4 * S
	}
	y += 12 * S
	ax := cx + 20 * S
	switch block {
	case "unreach":
		ax += rt_btn(a, cv, S, ax, y, "Retry", "r", 0, 0, 0, H, soft, r.f11b, r.f11) + 6 * S
		rt_btn(a, cv, S, ax, y, "Open LuCI", "o", 0, 1, 0, H, soft, r.f11b, r.f11)
	case "nopass", "fail":
		ax += rt_btn(a, cv, S, ax, y, "Save and connect", "↵", 1, 0, 0, H, soft, r.f11b, r.f11) + 6 * S
		rt_btn(a, cv, S, ax, y, "Not now", "Esc", 0, 1, 0, H, soft, r.f11b, r.f11)
	case "rebooting": rt_btn(a, cv, S, ax, y, "Hide", "Esc", 0, 1, 0, H, soft, r.f11b, r.f11)
	}
}

@(private = "file")
rt_draw_page :: proc(a: ^App, cv: ^Canvas, S, top, fy: int, H: HUD, soft: u32, px: int, now: i64) {
	r := a.router
	t := a.theme
	w := cv.w
	pop := a.opts.popup.set
	y := top + 12 * S
	x0, x1 := px, w - px
	loading := !r.have_sys
	ph :: proc(s: string, loading: bool, n := 6) -> string { return loading ? strings.repeat("░", n, context.temp_allocator) : s }
	// the banner: WAN down, or busy
	if r.loaded && r.have_wan && !r.wan_up || rt_busy(r) {
		down := r.have_wan && !r.wan_up
		bc := down ? H.hot : t.yellow
		bt := down ? fmt.tprintf("WAN down for %s", rt_dur(now - (r.down_since > 0 ? r.down_since : now))) : "Router is busy"
		bs := down ? fmt.tprintf("since %s · LAN and Wi-Fi still work · last IP %s", rt_clock(r.down_since), r.wan_ip) : fmt.tprintf("memory %.0f%% · load %.2f", r.mem_used / max(r.mem_total, 1) * 100, r.load[0])
		bh := 32 * S
		fill_rect(cv, x0, y, x1 - x0, bh, argb(bc, 0x12))
		rounded_rect(cv, x0, y, x1 - x0, bh, 0, 0, f32(S), argb(bc, 0xff))
		fill_rect(cv, x0, y, 3 * S, bh, argb(bc, 0xff))
		text_in(cv, r.f11b, bt, x0 + 12 * S, y, bh, argb(bc, 0xff))
		bx := rt_btn(a, cv, S, 0, -1000, "Show log", "Alt 6", 0, 0, 9, H, soft, r.f10b, r.f10, 22)
		text_in(cv, r.f10, ellipsize(r.f10, bs, x1 - x0 - tw(r.f11b, bt) - bx - 40 * S), x0 + 22 * S + tw(r.f11b, bt), y, bh, argb(soft, 0xff))
		bxx := x1 - 8 * S - bx
		rt_btn(a, cv, S, bxx, y + 5 * S, "Show log", "Alt 6", 0, 5, 9, H, soft, r.f10b, r.f10, 22)
		hit_add(a, bxx, y + 5 * S, bx, 22 * S, .Section, 5, 0)
		y += bh + 10 * S
	}
	mem_pct := r.mem_total > 0 ? r.mem_used / r.mem_total * 100 : 0
	sev3 :: proc(v, warn, crit: f32, H: HUD, yellow: u32) -> u32 { return v >= crit ? H.hot : (v >= warn ? yellow : H.fg) }
	mem_c := sev3(mem_pct, 70, 90, H, t.yellow)
	load_c := sev3(r.load[0], 2, 3.5, H, t.yellow)
	out_c := t.magenta
	switch r.page {
	case 0: // tiles, radios, the newest clients
		th := (pop ? 118 : 132) * S
		tw3 := (x1 - x0 - 20 * S) / 3
		for i in 0 ..< 3 {
			tx := x0 + i * (tw3 + 10 * S)
			title, meta, big, unit: string
			big_c := loading ? H.faint : H.fg
			bd := H.line
			switch i {
			case 0:
				title, meta = "MEMORY", ph(fmt.tprintf("%.0f / %.0f MB", r.mem_used, r.mem_total), loading, 10)
				big, unit = ph(fmt.tprintf("%.0f%%", mem_pct), loading, 3), fmt.tprintf("of %.0f MB%s", r.mem_total, mem_pct >= 80 ? " · high" : "")
				if !loading do big_c = mem_c
			case 1:
				title, meta = "LOAD", ph("1 · 5 · 15 min", loading, 8)
				big, unit = ph(fmt.tprintf("%.2f", r.load[0]), loading, 4), ph(fmt.tprintf("%.2f  %.2f", r.load[1], r.load[2]), loading)
				if !loading do big_c = load_c
			case 2:
				down := r.have_wan && !r.wan_up
				title, meta = "WAN", ph(down ? fmt.tprintf("down · %s", rt_dur(now - r.down_since)) : fmt.tprintf("up %s", rt_dur(r.wan_uptime)), loading, 8)
				big, unit = down ? "DOWN" : ph(fmt.tprintf("↓ %s", rt_rate(r.rx_rate)), loading, 8), down ? "no traffic" : ph(fmt.tprintf("↑ %s", rt_rate(r.tx_rate)), loading)
				if down do big_c = H.hot
			}
			if big_c == H.hot do bd = H.hot
			else if big_c == t.yellow do bd = mix(H.bg, t.yellow, 0.55)
			fill_rect(cv, tx, y, tw3, th, argb(H.panel, 0xff))
			rounded_rect(cv, tx, y, tw3, th, 0, 0, f32(S), argb(bd, 0xff))
			yy := y + 9 * S
			spaced(cv, r.f10b, title, tx + 11 * S, yy, int(r.f10.line_h), H.dim, S)
			mw := tw3 - 30 * S - spaced_w(r.f10b, title, S)
			mt := ellipsize(r.f10, meta, mw)
			text_in(cv, r.f10, mt, tx + tw3 - 11 * S - tw(r.f10, mt), yy, int(r.f10.line_h), argb(H.dim, 0xff))
			yy += int(r.f10.line_h) + 6 * S
			text_in(cv, r.f20b, big, tx + 11 * S, yy, int(r.f20b.line_h), argb(big_c, 0xff))
			text_in(cv, r.f10, ellipsize(r.f10, unit, tw3 - 30 * S - tw(r.f20b, big)), tx + 17 * S + tw(r.f20b, big), yy + int(r.f20b.line_h) - int(r.f10.line_h) - 2 * S, int(r.f10.line_h), argb(soft, 0xff))
			yy += int(r.f20b.line_h) + 6 * S
			sh := y + th - 9 * S - yy
			fill_rect(cv, tx + 11 * S, y + th - 9 * S, tw3 - 22 * S, S, argb(H.line, 0xff))
			if !loading {
				switch i {
				case 0: rt_spark(cv, tx + 11 * S, yy, tw3 - 22 * S, sh, r.hist_mem[:], 100, mem_c == H.fg ? H.acc : mem_c)
				case 1: rt_spark(cv, tx + 11 * S, yy, tw3 - 22 * S, sh, r.hist_load[:], 4, load_c == H.fg ? H.acc : load_c)
				case 2:
					m: f32 = 1
					for v in r.hist_rx do m = max(m, v)
					rt_spark(cv, tx + 11 * S, yy, tw3 - 22 * S, sh, r.hist_rx[:], m, H.acc, r.hist_tx[:], out_c)
				}
			}
			hit_add(a, tx, y, tw3, th, .Section, i == 2 ? 2 : 1, 0)
		}
		y += th + 10 * S
		// the radios
		if len(r.radios) > 0 {
			rw := (x1 - x0 - (len(r.radios) - 1) * 8 * S) / len(r.radios)
			for q, i in r.radios {
				rx := x0 + i * (rw + 8 * S)
				fill_rect(cv, rx, y, rw, 30 * S, argb(H.panel, 0xff))
				rounded_rect(cv, rx, y, rw, 30 * S, 0, 0, f32(S), argb(H.line, 0xff))
				fill_rect(cv, rx + 10 * S, y + 12 * S, 6 * S, 6 * S, argb(q.on ? t.green : H.faint, 0xff))
				text_in(cv, r.f11b, q.band, rx + 24 * S, y, 30 * S, argb(q.on ? H.fg : H.dim, 0xff))
				n := q.on ? fmt.tprintf("%d client%s", q.clients, q.clients == 1 ? "" : "s") : "off"
				text_in(cv, r.f11, n, rx + rw - 10 * S - tw(r.f11, n), y, 30 * S, argb(q.on ? soft : H.dim, 0xff))
				sx := rx + 32 * S + tw(r.f11b, q.band)
				text_in(cv, r.f11, ellipsize(r.f11, fmt.tprintf("ch %s · %s", q.channel, strings.join(strings.split(q.ssids, ",", context.temp_allocator), ", ", context.temp_allocator)), rx + rw - 20 * S - tw(r.f11, n) - sx), sx, y, 30 * S, argb(H.dim, 0xff))
				hit_add(a, rx, y, rw, 30 * S, .Section, 3, 0)
			}
			y += 30 * S + 10 * S
		}
		spaced(cv, r.f10b, "NEWEST CLIENTS", x0 + 2 * S, y, int(r.f10.line_h), H.dim, S)
		text_in(cv, r.f10, fmt.tprintf("%d connected · Alt 5 for all", len(r.clients)), x0 + 12 * S + spaced_w(r.f10b, "NEWEST CLIENTS", S), y, int(r.f10.line_h), argb(H.faint, 0xff))
		y += int(r.f10.line_h) + 4 * S
		for c, i in r.clients {
			if i >= (pop ? 4 : 5) || y + 26 * S > fy - 4 * S do break
			fill_rect(cv, x0, y + 26 * S - S, x1 - x0, S, argb(H.line, 0xff))
			lw := pop ? 70 : 70
			right := x1 - 8 * S
			text_in(cv, r.f11, c.lease, right - tw(r.f11, c.lease), y, 26 * S, argb(H.dim, 0xff))
			right -= lw * S + 12 * S
			text_in(cv, r.f11, c.band, right, y, 26 * S, argb(H.dim, 0xff))
			right -= 120 * S + 12 * S
			text_in(cv, r.f11, c.ip, right, y, 26 * S, argb(soft, 0xff))
			nx := x0 + 8 * S
			nm := ellipsize(r.f11b, rt_host(c), right - nx - 50 * S)
			text_in(cv, r.f11b, nm, nx, y, 26 * S, argb(H.fg, 0xff))
			if c.tag == "NEW" do rt_tag(cv, r.f9b, nx + tw(r.f11b, nm) + 8 * S, y, 26 * S, "NEW", H.acc, S)
			y += 26 * S
		}
		if len(r.clients) == 0 && !loading do text_in(cv, r.f11, "No clients right now.", x0 + 8 * S, y, 26 * S, argb(H.dim, 0xff))
	case 1: // key/value, the Reboot band
		Kv :: struct { k, v: string, c: u32, bar: f32, bar_c: u32 }
		kv := [?]Kv{
			{"Model", r.model, H.fg, -1, 0}, {"Hostname", fmt.tprintf("%s (%s)", r.hostname, r.host), H.fg, -1, 0},
			{"Release", r.release, H.fg, -1, 0}, {"Kernel", r.kernel, H.fg, -1, 0},
			{"Memory", fmt.tprintf("%.0f / %.0f MB · %.0f%%", r.mem_used, r.mem_total, mem_pct), mem_c, mem_pct / 100, mem_c == H.fg ? H.acc : mem_c},
			{"Load", fmt.tprintf("%.2f  %.2f  %.2f", r.load[0], r.load[1], r.load[2]), load_c, min(r.load[0] / 4, 1), load_c == H.fg ? H.acc : load_c},
			{"Uptime", rt_dur(r.uptime), H.fg, -1, 0}, {"Router password", "in the keyring · Ctrl+K changes it", H.dim, -1, 0},
		}
		yy := y + 6 * S
		for e in kv {
			text_in(cv, r.f12, e.k, x0 + 4 * S, yy, 22 * S, argb(H.dim, 0xff))
			vx := x0 + 160 * S
			v := ph(e.v, loading, 12)
			text_in(cv, r.f12, ellipsize(r.f12, v, x1 - vx - 140 * S), vx, yy, 22 * S, argb(loading ? H.faint : e.c, 0xff))
			if e.bar >= 0 && !loading {
				bx := vx + tw(r.f12, v) + 12 * S
				fill_rect(cv, bx, yy + 9 * S, 120 * S, 4 * S, argb(H.line, 0xff))
				fill_rect(cv, bx, yy + 9 * S, int(120 * f32(S) * clamp(e.bar, 0, 1)), 4 * S, argb(e.bar_c, 0xff))
			}
			yy += 22 * S + 9 * S
		}
		rt_band(a, cv, S, x0, x1, fy, H, soft)
	case 2: // WAN: the numbers, in above the line and out below
		down := r.have_wan && !r.wan_up
		Wk :: struct { k, v: string, c: u32 }
		wk := [?]Wk{
			{"Status", down ? fmt.tprintf("DOWN · %s", rt_dur(now - r.down_since)) : "UP", down ? H.hot : t.green},
			{"IP", down ? fmt.tprintf("%s (last)", r.wan_ip) : r.wan_ip, H.fg},
			{"Interface up", down ? "—" : rt_dur(r.wan_uptime), H.fg},
			{"↓ now · peak", fmt.tprintf("%s · %s", rt_rate(r.rx_rate), rt_rate(r.peak)), H.acc},
			{"↑ now", rt_rate(r.tx_rate), out_c},
			{"Since boot", fmt.tprintf("↓ %s  ↑ %s", rt_bytes(r.rx_total), rt_bytes(r.tx_total)), soft},
		}
		xx := x0 + 4 * S
		for e, i in wk {
			if pop && i >= 4 do break
			vw := max(tw(r.f14b, e.v), tw(r.f10, e.k))
			if xx + vw > x1 do break
			text_in(cv, r.f10, e.k, xx, y, int(r.f10.line_h), argb(H.dim, 0xff))
			text_in(cv, r.f14b, e.v, xx, y + int(r.f10.line_h) + 3 * S, int(r.f14b.line_h), argb(e.c, 0xff))
			xx += vw + 24 * S
		}
		gy := y + int(r.f10.line_h) + 3 * S + int(r.f14b.line_h) + 12 * S
		gh := fy - 12 * S - gy
		fill_rect(cv, x0, gy, x1 - x0, gh, argb(H.panel, 0xff))
		rounded_rect(cv, x0, gy, x1 - x0, gh, 0, 0, f32(S), argb(H.line, 0xff))
		inner_h := gh - 16 * S
		in_h := inner_h * 66 / 100
		mid := gy + 8 * S + in_h
		fill_rect(cv, x0 + 10 * S, mid, x1 - x0 - 20 * S, S, argb(soft, 0xff))
		mi: f32 = 1
		mo: f32 = 1
		for v in r.hist_rx do mi = max(mi, v)
		for v in r.hist_tx do mo = max(mo, v)
		n := 40
		bw := f32(x1 - x0 - 20 * S - (n - 1) * 2 * S) / f32(n)
		off := n - len(r.hist_rx)
		for i in 0 ..< len(r.hist_rx) {
			bx := x0 + 10 * S + int(f32(i + off) * (bw + f32(2 * S)))
			hi := max(int(r.hist_rx[i] / mi * f32(in_h - 4 * S)), 2 * S)
			fill_rect(cv, bx, mid - 3 * S - hi, max(int(bw), 1), hi, argb(H.acc, 0xff))
			if i < len(r.hist_tx) {
				ho := max(int(r.hist_tx[i] / mo * f32(gh - 16 * S - in_h - 4 * S)), 2 * S)
				fill_rect(cv, bx, mid + 4 * S, max(int(bw), 1), ho, argb(out_c, 0xff))
			}
		}
		text_in(cv, r.f10, "↓ in", x0 + 12 * S, gy + 6 * S, int(r.f10.line_h), argb(H.acc, 0xff))
		text_in(cv, r.f10, "↑ out", x0 + 12 * S, gy + gh - 6 * S - int(r.f10.line_h), int(r.f10.line_h), argb(out_c, 0xff))
		lab := "last 2 min · 3 s steps"
		text_in(cv, r.f10, lab, x1 - 12 * S - tw(r.f10, lab), gy + 6 * S, int(r.f10.line_h), argb(H.dim, 0xff))
	case 3: // one row per radio, a switch
		text_in(cv, r.f9b, "RADIO", x0 + 10 * S, y, 18 * S, argb(H.dim, 0xff))
		text_in(cv, r.f9b, "CLIENTS", x1 - 50 * S - tw(r.f9b, "CLIENTS"), y, 18 * S, argb(H.dim, 0xff))
		y += 18 * S
		r.sel = clamp(r.sel, 0, max(len(r.radios) - 1, 0))
		for q, i in r.radios {
			rh := 46 * S
			on := i == r.sel
			fg := on ? H.bg : H.fg
			if on { fill_rect(cv, x0, y, x1 - x0, rh, argb(H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, rh) }
			else do rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(H.line, 0xff))
			// the switch
			sw, sh := 30 * S, 16 * S
			sx, sy := x1 - 10 * S - sw, y + (rh - sh) / 2
			track := q.on ? (on ? H.bg : H.acc) : 0
			if track != 0 do fill_rect(cv, sx, sy, sw, sh, argb(track, 0xff))
			rounded_rect(cv, sx, sy, sw, sh, 0, 0, f32(S), argb(on ? H.bg : (q.on ? H.acc : H.faint), 0xff))
			fill_rect(cv, q.on ? sx + sw - 14 * S : sx + 2 * S, sy + 2 * S, 12 * S, 12 * S, argb(q.on ? (on ? H.acc : H.bg) : (on ? H.bg : H.dim), 0xff))
			n := q.on ? fmt.tprint(q.clients) : "off"
			text_in(cv, r.f11, n, sx - 10 * S - tw(r.f11, n), y, rh, argb(fg, 0xff))
			l1 := fmt.tprintf("%s · %s%s", q.band, q.id, q.mine ? "  · this machine is on it" : "")
			l2 := fmt.tprintf("ch %s%s · SSIDs: %s%s", q.channel, q.width != "" ? fmt.tprintf(" · %s", q.width) : "", strings.join(strings.split(q.ssids, ",", context.temp_allocator), ", ", context.temp_allocator), q.pending ? " · applies at next reboot (saved, not applied)" : "")
			lw := sx - 90 * S - x0
			ly := y + (rh - int(r.f11b.line_h) - 3 * S - int(r.f10.line_h)) / 2
			text_in(cv, r.f11b, ellipsize(r.f11b, l1, lw), x0 + 10 * S, ly, int(r.f11b.line_h), argb(fg, 0xff))
			text_in(cv, r.f10, ellipsize(r.f10, l2, lw), x0 + 10 * S, ly + int(r.f11b.line_h) + 3 * S, int(r.f10.line_h), argb(on ? H.bg : (q.pending ? t.yellow : H.dim), 0xff))
			hit_add(a, x0, y, x1 - x0, rh, .Row, i, 0)
			y += rh + 3 * S
		}
		if len(r.radios) == 0 do text_in(cv, r.f11, loading ? "…" : "No radios in the router's wireless config.", x0 + 10 * S, y + 10 * S, 20 * S, argb(H.dim, 0xff))
		rt_band(a, cv, S, x0, x1, fy, H, soft)
	case 4, 5: // clients, the log
		is_log := r.page == 5
		fh2 := 34 * S
		fill_rect(cv, x0, y, x1 - x0, fh2, argb(H.panel, 0xff))
		rounded_rect(cv, x0, y, x1 - x0, fh2, 0, 0, f32(S), argb(H.line, 0xff))
		fill_rect(cv, x0, y, 3 * S, fh2, argb(H.acc, 0xff))
		text_in(cv, r.f13b, "›", x0 + 10 * S, y, fh2, argb(H.acc, 0xff))
		qx := x0 + 24 * S
		qt := string(a.query[:])
		right := x1 - 10 * S
		cnt: string
		clients := rt_clients(a)
		logs := rt_logs(a)
		if is_log do cnt = r.log_loaded ? fmt.tprintf("%d lines", len(r.logs)) : "loading…"
		else do cnt = len(a.query) > 0 ? fmt.tprintf("%d of %d", len(clients), len(r.clients)) : fmt.tprintf("%d clients", len(r.clients))
		text_in(cv, r.f10, cnt, right - tw(r.f10, cnt), y, fh2, argb(H.dim, 0xff))
		right -= tw(r.f10, cnt) + 10 * S
		if is_log {
			lv := [4]string{"ALL", "ERR", "WARN", "NOTICE"}
			for i := 3; i >= 0; i -= 1 {
				cw := tw(r.f9b, lv[i]) + 12 * S
				cx := right - cw
				on := i == r.sev
				if on do fill_rect(cv, cx, y + 7 * S, cw, 20 * S, argb(H.acc, 0x1f))
				rounded_rect(cv, cx, y + 7 * S, cw, 20 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
				text_in(cv, r.f9b, lv[i], cx + 6 * S, y + 7 * S, 20 * S, argb(on ? H.fg : H.dim, 0xff))
				hit_add(a, cx, y + 7 * S, cw, 20 * S, .Chip, i, 2)
				right = cx - 4 * S
			}
		}
		if qt == "" do text_in(cv, r.f12, is_log ? "Filter log lines…" : "Filter by name, IP or MAC…", qx, y, fh2, argb(H.hint, 0xff))
		else do text_in(cv, r.f12, ellipsize(r.f12, qt, right - qx), qx, y, fh2, argb(H.fg, 0xff))
		qs := shape(r.f12, qt)
		cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
		fill_rect(cv, qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)]), y + (fh2 - 14 * S) / 2, max(S, 2), 14 * S, argb(H.acc, 0xff))
		y += fh2 + 8 * S
		if !is_log {
			cols := pop ? [][2]string{{"HOST", "1"}, {"IP", "120"}, {"LEASE", "60"}} : [][2]string{{"HOST", "1"}, {"IP", "130"}, {"MAC", "150"}, {"BAND", "70"}, {"LEASE", "60"}}
			rt_head(cv, r, S, x0, x1, y, cols, H)
			y += 18 * S
			r.sel = clamp(r.sel, 0, max(len(clients) - 1, 0))
			// scroll so the picked one shows
			rh := 28 * S
			vis := max((fy - 8 * S - y) / (rh + 3 * S), 1)
			first := max(0, r.sel - vis + 1)
			for c, i in clients {
				if i < first do continue
				if y + rh > fy - 6 * S do break
				on := i == r.sel
				if on { fill_rect(cv, x0, y, x1 - x0, rh, argb(H.acc, 0xff)); mark_sel(a, x0, y, x1 - x0, rh) }
				else do rounded_rect(cv, x0, y, x1 - x0, rh, 0, 0, f32(S), argb(H.line, 0xff))
				fg := on ? H.bg : H.fg
				dim := on ? H.bg : H.dim
				xr := x1 - 10 * S
				vals := pop ? []string{c.lease, c.ip} : []string{c.lease, c.band, c.mac, c.ip}
				widths := pop ? []int{60, 120} : []int{60, 70, 150, 130}
				for v, k in vals {
					cwid := widths[k] * S
					if k == 0 do text_in(cv, r.f11, v, xr - tw(r.f11, v), y, rh, argb(dim, 0xff))
					else do text_in(cv, r.f11, ellipsize(r.f11, v, cwid), xr - cwid, y, rh, argb(k == len(vals) - 1 ? fg : dim, 0xff))
					xr -= cwid + 12 * S
				}
				nm := ellipsize(r.f11b, rt_host(c), xr - x0 - 70 * S)
				text_in(cv, r.f11b, nm, x0 + 10 * S, y, rh, argb(fg, 0xff))
				if c.tag != "" {
					tc := c.tag == "NEW" ? H.acc : (c.tag == "YOU" ? t.green : H.dim)
					rt_tag(cv, r.f9b, x0 + 18 * S + tw(r.f11b, nm), y, rh, c.tag, on ? H.bg : tc, S)
				}
				hit_add(a, x0, y, x1 - x0, rh, .Row, i, 0)
				y += rh + 3 * S
			}
			if len(clients) == 0 do text_in(cv, r.f11, len(r.clients) == 0 ? "No clients right now." : fmt.tprintf("No client matches “%s”.", strings.trim_space(qt)), x0 + 10 * S, y + 4 * S, 20 * S, argb(H.dim, 0xff))
		} else {
			rh := 22 * S
			for l in logs {
				if y + rh > fy - 6 * S do break
				sc := l.sev == "err" ? H.hot : (l.sev == "warn" ? t.yellow : (l.sev == "notice" ? H.acc : H.dim))
				tcol := l.sev == "err" ? H.hot : (l.sev == "warn" ? t.yellow : soft)
				text_in(cv, r.f11, l.time, x0 + 6 * S, y, rh, argb(H.dim, 0xff))
				text_in(cv, r.f11b, strings.to_upper(l.sev, context.temp_allocator), x0 + 76 * S, y, rh, argb(sc, 0xff))
				text_in(cv, r.f11, ellipsize(r.f11, l.text, x1 - x0 - 140 * S), x0 + 134 * S, y, rh, argb(tcol, 0xff))
				y += rh
			}
			if r.log_loaded && len(logs) == 0 do text_in(cv, r.f11, len(a.query) > 0 ? fmt.tprintf("No line matches “%s”.", strings.trim_space(qt)) : "No log lines at this level.", x0 + 10 * S, y + 4 * S, 20 * S, argb(H.dim, 0xff))
		}
	}
}

@(private = "file")
rt_tag :: proc(cv: ^Canvas, f: ^Font, x, y, h: int, l: string, c: u32, S: int) {
	tw_ := tw(f, l) + 8 * S
	ty := y + (h - 14 * S) / 2
	rounded_rect(cv, x, ty, tw_, 14 * S, 0, 0, f32(S), argb(c, 0xff))
	text_in(cv, f, l, x + 4 * S, ty, 14 * S, argb(c, 0xff))
}

@(private = "file")
rt_head :: proc(cv: ^Canvas, r: ^Router, S, x0, x1, y: int, cols: [][2]string, H: HUD) {
	xr := x1 - 10 * S
	for i := len(cols) - 1; i >= 1; i -= 1 {
		wd, _ := strconv.parse_int(cols[i][1])
		if i == len(cols) - 1 do text_in(cv, r.f9b, cols[i][0], xr - tw(r.f9b, cols[i][0]), y, 18 * S, argb(H.dim, 0xff))
		else do text_in(cv, r.f9b, cols[i][0], xr - wd * S, y, 18 * S, argb(H.dim, 0xff))
		xr -= wd * S + 12 * S
	}
	text_in(cv, r.f9b, cols[0][0], x0 + 10 * S, y, 18 * S, argb(H.dim, 0xff))
}

// The band at the foot of System (Reboot) and Wireless (turn off, saved not applied).
@(private = "file")
rt_band :: proc(a: ^App, cv: ^Canvas, S, x0, x1, fy: int, H: HUD, soft: u32) {
	r := a.router
	t := a.theme
	title, body: string
	c := H.dim
	bg := argb(H.panel, 0xff)
	acts := make([dynamic][3]string, 0, 2, context.temp_allocator) // label key kind
	switch {
	case r.band == "reboot":
		title, c = "Reboot the router?", H.hot
		body = fmt.tprintf("Everyone’s internet and Wi-Fi drop for about 90 s, including this machine’s. %d clients are connected. k4 counts until it answers again.", len(r.clients))
		append(&acts, [3]string{"Reboot", "y", "2"}, [3]string{"Cancel", "n", "0"})
	case r.band == "radiooff" && r.sel < len(r.radios):
		q := r.radios[r.sel]
		title, c = fmt.tprintf("Turn off %s? This machine is connected through it.", q.band), H.hot
		body = fmt.tprintf("This machine drops off Wi-Fi now and k4 loses the router until it reconnects on another band. %d clients are on this radio.", q.clients)
		append(&acts, [3]string{"Turn off", "y", "2"}, [3]string{"Keep on", "n", "0"})
	case r.page == 3 && radios_saved(r, a):
		title, c = "Saved, not applied yet", t.yellow
		body = "This router doesn’t allow wifi reload, so the change applies at the next reboot."
		append(&acts, [3]string{"Reboot router now", "^R", "1"}, [3]string{"Later", "Esc", "0"})
	case r.page == 1:
		title, body = "Reboot", "Restarts the router. Everyone on it is offline for about 90 s."
		append(&acts, [3]string{"Reboot router…", "^R", "0"})
	case: return
	}
	if c != H.dim do bg = argb(c, 0x12)
	inner := x1 - x0 - 24 * S
	lines := wrap_hard(r.f11, body, inner)
	bh := 10 * S + int(r.f12b.line_h) + 7 * S + len(lines) * 16 * S + 7 * S + 24 * S + 10 * S
	by := fy - 12 * S - bh
	fill_rect(cv, x0, by, x1 - x0, bh, bg)
	rounded_rect(cv, x0, by, x1 - x0, bh, 0, 0, f32(S), argb(c, 0xff))
	fill_rect(cv, x0, by, 3 * S, bh, argb(c, 0xff))
	y := by + 10 * S
	text_in(cv, r.f12b, title, x0 + 12 * S, y, int(r.f12b.line_h), argb(c == H.dim ? H.fg : c, 0xff))
	y += int(r.f12b.line_h) + 7 * S
	for l in lines { text_in(cv, r.f11, l, x0 + 12 * S, y, 16 * S, argb(soft, 0xff)); y += 16 * S }
	y += 7 * S
	ax := x0 + 12 * S
	for ac, i in acts {
		kind, _ := strconv.parse_int(ac[2])
		ax += rt_btn(a, cv, S, ax, y, ac[0], ac[1], kind, i, 1, H, soft, r.f10b, r.f10, 24) + 6 * S
	}
}

router_dump :: proc(a: ^App) -> string {
	r := a.router
	sb := strings.builder_make(context.temp_allocator)
	pages := [6]string{"overview", "system", "wan", "wireless", "clients", "log"}
	block := rt_block(r)
	fmt.sbprintfln(&sb, "router %s · %s%s", pages[r.page], r.status, block != "" ? fmt.tprintf(" · block %s", block) : "")
	switch {
	case block != "":
	case r.page == 3: for q, i in r.radios do fmt.sbprintfln(&sb, "%s %s %s%s", i == r.sel ? "*" : " ", q.band, q.on ? "on" : "off", q.pending ? " (pending)" : "")
	case r.page == 4: for c, i in rt_clients(a) do fmt.sbprintfln(&sb, "%s %s %s%s", i == r.sel ? "*" : " ", rt_host(c), c.ip, c.tag != "" ? fmt.tprintf(" %s", c.tag) : "")
	case r.page == 5: for l in rt_logs(a) do fmt.sbprintfln(&sb, "  %s %s", l.sev, l.text)
	}
	if r.band != "" do fmt.sbprintfln(&sb, "band %s", r.band)
	if r.toast != "" do fmt.sbprintfln(&sb, "toast %s", r.toast)
	return strings.to_string(sb)
}
