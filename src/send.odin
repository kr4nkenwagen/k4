package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --send: Send to (the Kestrel design's Share › Send to, LocalSend): what is being sent, the
// devices nearby (found live by the k4-localsend service), and the transfer. 760×600 in the
// launcher's frame, or 420×560 under the bar's transfer module (--popup). ↑↓ pick a device, ↵
// sends, Space picks several (↵ sends to all), Tab switches what is sent (k4 closes and the
// script asks for files or a folder, then opens it again), v this machine visible or hidden, r
// scans again; while sending Esc cancels; after, r retries and ↵ clears. It talks to the service
// over $XDG_RUNTIME_DIR/k4-localsend.sock. What is sent comes on stdin:
//   S <kind: TEXT | IMAGE | N FILES | FOLDER | SCREENSHOT> <title> <sub> <mode: text|files>
//     <payload: the text, or paths joined by \x1f> <tab: clipboard|files|folder|screenshot> [thumb]
// When k4 closes on Tab it prints "pick<TAB>clipboard|files|folder".

SEND_W, SEND_H :: 760, 600
SEND_PW, SEND_PH :: 420, 560

Send_Dev :: struct {
	fp, alias, kind, model, ip: string,
	age: int,
	trusted: bool,
}

Send :: struct {
	kind, title, sub, mode, payload, tab, thumb: string,
	devs: [dynamic]Send_Dev,
	cur: int,
	sel_fp: string,
	picks: [dynamic]string,
	// the job, as the service reports it
	job_st: string, // none waiting sending sent declined failed cancelled
	job_p: f32,
	job_done, job_total, job_files_done, job_files, job_speed, job_left: int,
	job_to: string,
	job_secs: f32,
	targets: map[string][2]string, // fp -> status, progress
	last_targets: [dynamic]string, // for retry
	alias: string,
	visible: bool,
	scan_until: time.Tick,
	toast: string,
	offline: bool,
	popup: bool,
	f9, f9b, f10, f10b, f11, f11b, f12, f12b, f13, f13b, f15, icon: ^Font,
}

send_sock :: proc() -> string {
	if v := os.get_env("K4_LOCALSEND_SOCK", context.temp_allocator); v != "" do return v
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	return fmt.tprintf("%s/k4-localsend.sock", run != "" ? run : "/tmp")
}

@(private = "file")
send_ctl :: proc(cmd: string) -> (string, bool) {
	if os.get_env("K4_SEND_FIXTURE", context.temp_allocator) != "" do return "", false
	return unix_ctl(send_sock(), cmd)
}

send_setup :: proc(a: ^App, data: string) {
	s := new(Send)
	a.send = s
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	s.f10, s.f11, s.f12, s.f13, s.f15, s.icon = reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 13), reg(a, 15), reg(a, 16)
	s.f9b, s.f10b, s.f11b, s.f12b, s.f13b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13)
	s.f9 = reg(a, 9)
	s.popup = a.opts.popup.set
	s.job_st = "none"
	s.cur = 0
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
		switch f[0] {
		case "S":
			s.kind, s.title, s.sub, s.mode, s.payload, s.tab, s.thumb = get(f, 1), get(f, 2), get(f, 3), get(f, 4), get(f, 5), get(f, 6), get(f, 7)
			p, _ := strings.replace_all(s.payload, "\\n", "\n")
			s.payload = strings.clone(p)
		case "D": // tests: devices
			append(&s.devs, send_dev(f))
		}
	}
	if os.get_env("K4_SEND_FIXTURE", context.temp_allocator) != "" { s.alias, s.visible = "kestrel-x1", true; return }
	if _, ok := send_ctl("scan"); !ok do s.offline = true
	s.scan_until = time.tick_add(time.tick_now(), 5 * time.Second)
	send_refresh(a)
}

@(private = "file")
send_dev :: proc(f: []string) -> Send_Dev {
	get :: proc(f: []string, i: int) -> string { return i < len(f) ? strings.clone(f[i]) : "" }
	d := Send_Dev{fp = get(f, 1), alias = get(f, 2), kind = get(f, 3), model = get(f, 4), ip = get(f, 5), trusted = len(f) > 7 && f[7] == "1"}
	d.age, _ = strconv.parse_int(len(f) > 6 ? f[6] : "0")
	return d
}

// The devices, the job and this machine's state from the service (every half second while open).
send_refresh :: proc(a: ^App) {
	s := a.send
	if os.get_env("K4_SEND_FIXTURE", context.temp_allocator) != "" do return
	if out, ok := send_ctl("devices"); ok {
		s.offline = false
		keep := s.sel_fp
		clear(&s.devs)
		text := out
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t", context.temp_allocator)
			if f[0] == "D" do append(&s.devs, send_dev(f))
		}
		s.cur = 0
		for d, i in s.devs do if d.fp == keep { s.cur = i; break }
	} else do s.offline = true
	if out, ok := send_ctl("job"); ok {
		clear(&s.targets)
		text := out
		for line in strings.split_lines_iterator(&text) {
			f := strings.split(line, "\t", context.temp_allocator)
			get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
			switch f[0] {
			case "J":
				s.job_st = strings.clone(get(f, 1))
				p, _ := strconv.parse_f32(get(f, 2)); s.job_p = p
				s.job_done, _ = strconv.parse_int(get(f, 3)); s.job_total, _ = strconv.parse_int(get(f, 4))
				s.job_files_done, _ = strconv.parse_int(get(f, 5)); s.job_files, _ = strconv.parse_int(get(f, 6))
				s.job_speed, _ = strconv.parse_int(get(f, 7)); s.job_left, _ = strconv.parse_int(get(f, 8))
				s.job_to = strings.clone(get(f, 9))
				s.job_secs, _ = strconv.parse_f32(get(f, 10))
			case "T": s.targets[strings.clone(get(f, 1))] = {strings.clone(get(f, 2)), strings.clone(get(f, 3))}
			}
		}
	}
	if out, ok := send_ctl("status"); ok {
		f := strings.split(strings.trim_space(out), "\t", context.temp_allocator)
		if len(f) > 1 { s.alias = strings.clone(f[0]); s.visible = f[1] == "1" }
	}
}

@(private = "file")
send_busy :: proc(s: ^Send) -> bool { return s.job_st == "waiting" || s.job_st == "sending" }

@(private = "file")
send_over :: proc(s: ^Send) -> bool { return s.job_st == "sent" || s.job_st == "declined" || s.job_st == "failed" }

@(private = "file")
send_go :: proc(a: ^App, retry := false) {
	s := a.send
	targets := make([dynamic]string, 0, 4, context.temp_allocator)
	if retry do for t in s.last_targets do append(&targets, t)
	else if len(s.picks) > 0 do for p in s.picks do append(&targets, p)
	else if s.cur < len(s.devs) do append(&targets, s.devs[s.cur].fp)
	if len(targets) == 0 { s.toast = "Pick a device first"; return }
	for t in targets do for d in s.devs do if d.fp == t && d.age > 60 { s.toast = fmt.aprintf("%s is not answering · pick another or scan again (r)", d.alias); return }
	if s.payload == "" { s.toast = "Nothing to send · Tab picks what"; return }
	clear(&s.last_targets)
	for t in targets do append(&s.last_targets, strings.clone(t))
	if os.get_env("K4_SEND_FIXTURE", context.temp_allocator) != "" { s.job_st = "waiting"; s.toast = fmt.aprintf("(send %s to %d)", s.mode, len(targets)); return }
	send_ctl("clear")
	out, _ := send_ctl(fmt.tprintf("send\t%s\t%s\t%s", s.mode, strings.join(targets[:], ",", context.temp_allocator), s.payload))
	r := strings.trim_space(out)
	if r != "ok" { s.toast = fmt.aprintf("Could not send · %s", r); return }
	s.toast = ""
	send_refresh(a)
}

@(private = "file")
send_close :: proc(a: ^App, result: string = "") {
	s := a.send
	if send_busy(s) do send_ctl("detach") // the transfer goes on; its card shows it
	a.result = result
	a.exit = 0
	a.done = true
}

send_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	s := a.send
	if ctrl && (ch == 'c' || ch == 'g') { send_close(a); return true }
	if send_busy(s) {
		if k == .Escape { send_ctl("cancel"); s.toast = fmt.aprintf("Cancelled · nothing left behind on %s", s.job_to); send_refresh(a) }
		return true
	}
	if send_over(s) {
		switch {
		case text == "r" && s.job_st != "sent": send_go(a, true); return true
		case k == .Enter || k == .Escape: send_ctl("clear"); s.job_st = "none"; clear(&s.picks); s.toast = ""; return true
		case k == .Tab: send_ctl("clear"); s.job_st = "none"
		}
	}
	n := len(s.devs)
	switch {
	case k == .Down: if n > 0 { s.cur = min(s.cur + 1, n - 1); s.sel_fp = s.devs[s.cur].fp; s.toast = "" }
	case k == .Up: if n > 0 { s.cur = max(s.cur - 1, 0); s.sel_fp = s.devs[s.cur].fp; s.toast = "" }
	case k == .Enter: send_go(a)
	case text == " ":
		if s.cur < n {
			fp := s.devs[s.cur].fp
			for p, i in s.picks do if p == fp { ordered_remove(&s.picks, i); return true }
			append(&s.picks, strings.clone(fp))
		}
	case k == .Tab || k == .Back_Tab:
		order := [3]string{"clipboard", "files", "folder"}
		i := 0
		for o, j in order do if o == s.tab do i = j
		if s.tab == "screenshot" || s.tab == "" do i = -1
		next := order[((i + (k == .Tab ? 1 : 2)) % 3 + 3) % 3]
		if i < 0 do next = k == .Tab ? "clipboard" : "folder"
		send_close(a, fmt.aprintf("pick\t%s", next))
	case text == "v":
		out, _ := send_ctl("vis toggle")
		send_refresh(a)
		s.toast = strings.trim_space(out) == "off" ? fmt.aprintf("Hidden · other devices can’t see %s (you can still send)", s.alias) : fmt.aprintf("Visible as %s on port 53317", s.alias)
	case text == "r":
		send_ctl("scan")
		s.scan_until = time.tick_add(time.tick_now(), 5 * time.Second)
		s.toast = ""
	case k == .Escape:
		if len(s.picks) > 0 do clear(&s.picks)
		else do send_close(a)
	case: return false
	}
	return true
}

send_click :: proc(a: ^App, x, y, button: int) -> bool {
	s := a.send
	h, ok := hit_at(a, x, y)
	if !ok { send_close(a); return true }
	#partial switch h.kind {
	case .Row:
		if s.cur == h.a && !send_busy(s) do send_go(a)
		else if h.a < len(s.devs) do s.cur, s.sel_fp, s.toast = h.a, s.devs[h.a].fp, ""
	case .Tab:
		order := [3]string{"clipboard", "files", "folder"}
		if h.a < 3 && order[h.a] != s.tab do send_close(a, fmt.aprintf("pick\t%s", order[h.a]))
	case .Confirm: send_key(a, .None, false, 'v', "v")
	case .Chip:
		switch h.a {
		case 0: send_key(a, .Escape, false, 0, "") // cancel / OK / done
		case 1: send_key(a, .None, false, 'r', "r") // retry
		case 2: send_key(a, .Tab, false, 0, "") // send more
		case 3: send_key(a, .None, false, 'r', "r") // scan again
		}
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
send_icon :: proc(kind: string) -> string {
	switch kind {
	case "mobile": return "󰄜"
	case "tablet": return "󰓶"
	case "laptop": return "󰌢"
	case "server", "headless": return "󰒋"
	case "web": return "󰖟"
	}
	return "󰍹"
}

@(private = "file")
send_size :: proc(b: int) -> string {
	f := f64(b)
	switch {
	case f >= 1e9: return fmt.tprintf("%.2f GB", f / 1e9)
	case f >= 1e6: return fmt.tprintf("%.1f MB", f / 1e6)
	}
	return fmt.tprintf("%d KB", max(1, int(f / 1e3 + 0.5)))
}

send_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	s := a.send
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	pop := s.popup
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	px := (pop ? 12 : 16) * S
	// the head: SHARE › SEND TO · what this is · visible / hidden
	hh := (pop ? 40 : 56) * S
	crumb := pop ? "SHARE" : "SHARE › SEND TO"
	cf := pop ? s.f11b : s.f12b
	cw := tw(cf, crumb) + (pop ? 12 : 16) * S
	ch := (pop ? 20 : 24) * S
	fill_rect(cv, px, (hh - ch) / 2, cw, ch, argb(H.acc, 0xff))
	text_in(cv, cf, crumb, px + (cw - tw(cf, crumb)) / 2, (hh - ch) / 2, ch, argb(H.bg, 0xff))
	vis_l := s.visible ? (pop ? "Visible" : fmt.tprintf("Visible as %s", s.alias)) : "Hidden"
	if s.offline do vis_l = "Not running"
	vc := s.visible && !s.offline ? t.green : H.dim
	vw := tw(s.f10b, vis_l) + 6 * S + 6 * S + 16 * S
	vx := w - px - vw
	rounded_rect(cv, vx, (hh - 24 * S) / 2, vw, 24 * S, 0, 0, f32(S), argb(s.visible && !s.offline ? mix(H.bg, t.green, 0.4) : H.line, 0xff))
	fill_rect(cv, vx + 8 * S, (hh - 6 * S) / 2, 6 * S, 6 * S, argb(vc, 0xff))
	text_in(cv, s.f10b, vis_l, vx + 8 * S + 6 * S + 6 * S, (hh - 24 * S) / 2, 24 * S, argb(vc, 0xff))
	hit_add(a, vx, (hh - 24 * S) / 2, vw, 24 * S, .Confirm, 0, 0)
	head_t := pop ? "Send to a nearby device" : "Send to a nearby device · LocalSend"
	hf := pop ? s.f13 : s.f15
	text_in(cv, hf, ellipsize(hf, head_t, vx - 12 * S - (px + cw + 12 * S)), px + cw + 12 * S, 0, hh, argb(H.fg, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// what is being sent
	y := hh + S + 12 * S
	spaced(cv, s.f10b, "SENDING", px, y, 22 * S, H.dim, S)
	tx := px + spaced_w(s.f10b, "SENDING", S) + 12 * S
	tabs := make([dynamic][2]string, 0, 4, context.temp_allocator)
	if s.tab == "screenshot" do append(&tabs, [2]string{"screenshot", "Screenshot"})
	append(&tabs, [2]string{"clipboard", "Clipboard"}, [2]string{"files", "Files"}, [2]string{"folder", "Folder"})
	for tb, i in tabs {
		on := tb[0] == s.tab
		bw := tw(s.f10b, tb[1]) + 16 * S
		if on do fill_rect(cv, tx, y, bw, 22 * S, argb(H.acc, 0x1a))
		rounded_rect(cv, tx, y, bw, 22 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
		text_in(cv, s.f10b, tb[1], tx + 8 * S, y, 22 * S, argb(on ? H.fg : H.dim, 0xff))
		idx := s.tab == "screenshot" ? i - 1 : i
		if idx >= 0 do hit_add(a, tx, y, bw, 22 * S, .Tab, idx, 0)
		tx += bw + 6 * S
	}
	text_in(cv, s.f10, "Tab", w - px - tw(s.f10, "Tab"), y, 22 * S, argb(H.faint, 0xff))
	y += 22 * S + 8 * S
	bh := 56 * S
	fill_rect(cv, px, y, w - 2 * px, bh, argb(t.fg, 0x0a))
	rounded_rect(cv, px, y, w - 2 * px, bh, 0, 0, f32(S), argb(H.line, 0xff))
	ix, iy := px + 10 * S, y + 8 * S
	fill_rect(cv, ix, iy, 40 * S, 40 * S, argb(H.bg, 0xff))
	img_ok := false
	if s.thumb != "" {
		img := image_cover(a, s.thumb, 40 * S, 40 * S)
		if img.ok { blit_image(cv, img.px, img.w, img.h, ix, iy); img_ok = true }
	}
	if !img_ok {
		g := s.mode == "text" ? "T" : (s.tab == "folder" ? "/" : fmt.tprint(max(1, strings.count(s.payload, "\x1f") + 1)))
		text_in(cv, s.f13b, g, ix + (40 * S - tw(s.f13b, g)) / 2, iy, 40 * S, argb(H.acc, 0xff))
	}
	rounded_rect(cv, ix, iy, 40 * S, 40 * S, 0, 0, f32(S), argb(H.line, 0xff))
	kc := s.mode == "text" ? H.acc : (s.kind == "IMAGE" || s.kind == "SCREENSHOT" ? t.magenta : soft)
	kw := spaced_w(s.f9b, s.kind, S) + 12 * S
	kx := w - px - 10 * S - kw
	rounded_rect(cv, kx, y + (bh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(kc, 0xff))
	spaced(cv, s.f9b, s.kind, kx + 6 * S, y + (bh - 16 * S) / 2, 16 * S, kc, S)
	lx := ix + 40 * S + 12 * S
	ly := y + (bh - int(s.f13b.line_h) - 3 * S - int(s.f10.line_h)) / 2
	title := s.title != "" ? s.title : "Nothing yet · Tab picks what to send"
	text_in(cv, s.f13b, ellipsize(s.f13b, title, kx - 12 * S - lx), lx, ly, int(s.f13b.line_h), argb(H.fg, 0xff))
	text_in(cv, s.f10, ellipsize(s.f10, s.sub, kx - 12 * S - lx), lx, ly + int(s.f13b.line_h) + 3 * S, int(s.f10.line_h), argb(H.dim, 0xff))
	y += bh + 10 * S
	fill_rect(cv, 0, y, w, S, argb(H.line, 0xff))
	// NEARBY · scanning
	scanning := time.tick_diff(time.tick_now(), s.scan_until) > 0 && os.get_env("K4_SEND_FIXTURE", context.temp_allocator) == ""
	ny := y + S
	spaced(cv, s.f10b, "NEARBY", px, ny, 30 * S, H.dim, S)
	sl, sc := "", H.dim
	switch {
	case s.offline: sl, sc = "the k4-localsend service is not running", H.hot
	case scanning: sl, sc = len(s.devs) > 0 ? fmt.tprintf("scanning… %d found", len(s.devs)) : "scanning…", H.acc
	case len(s.devs) == 0: sl, sc = "nothing found", H.hot
	case: sl = fmt.tprintf("%d found · port 53317", len(s.devs))
	}
	text_in(cv, s.f10, sl, px + spaced_w(s.f10b, "NEARBY", S) + 8 * S, ny, 30 * S, argb(sc, 0xff))
	note := len(s.picks) > 0 ? fmt.tprintf("%d picked · ↵ sends to all", len(s.picks)) : (pop ? "" : "Space picks several")
	text_in(cv, s.f10, note, w - px - tw(s.f10, note), ny, 30 * S, argb(H.faint, 0xff))
	if scanning { // a moving line under it
		fill_rect(cv, 0, ny + 30 * S - S, w, S, argb(H.line, 0xff))
		ph := f32(time.duration_milliseconds(time.tick_diff(s.scan_until, time.tick_now())) + 5000) / 1600
		seg := w / 4
		sx := int((ph - f32(int(ph))) * f32(w + seg)) - seg
		fill_rect(cv, max(sx, 0), ny + 30 * S - S, min(seg, w - max(sx, 0)), S, argb(H.acc, 0xff))
	}
	y = ny + 30 * S + 2 * S
	// the footer and the job panel first: the list fills what is left
	fh := (pop ? 30 : 40) * S
	fy := h - fh
	job_h := 0
	if s.job_st != "none" && s.job_st != "" && s.job_st != "cancelled" do job_h = 10 * S + int(s.f12b.line_h) + 8 * S + (s.job_st == "sending" || s.job_st == "failed" ? 4 * S + 8 * S : 0) + 24 * S + 10 * S + 10 * S
	list_b := fy - job_h - 8 * S
	if len(s.devs) == 0 {
		cy := y + (list_b - y) / 2 - 50 * S
		l1 := scanning ? "Looking for devices…" : "No devices found"
		if s.offline do l1 = "LocalSend is off"
		text_in(cv, s.f13b, l1, (w - tw(s.f13b, l1)) / 2, cy, 20 * S, argb(H.fg, 0xff))
		cy += 28 * S
		tips: []string
		if s.offline do tips = {"Start it with k4-share daemon (it starts at login)."}
		else if scanning do tips = {"Phones and computers with LocalSend open show up here within a few seconds."}
		else do tips = {"1 · Is the other device on the same network?", "2 · Is LocalSend open on it? Phones stop listening in the background.", "3 · Is port 53317 open? sudo ufw allow 53317"}
		for tip in tips {
			for l in wrap_text(s.f11, tip, w - 80 * S) { text_in(cv, s.f11, l, (w - tw(s.f11, l)) / 2, cy, 16 * S, argb(H.dim, 0xff)); cy += 16 * S }
			cy += 4 * S
		}
		if !scanning && !s.offline {
			b := "Scan again"
			bw := tw(s.f11b, b) + 6 * S + tw(s.f11, "r") + 20 * S
			bx := (w - bw) / 2
			rounded_rect(cv, bx, cy + 6 * S, bw, 26 * S, 0, 0, f32(S), argb(H.acc, 0xff))
			text_in(cv, s.f11b, b, bx + 10 * S, cy + 6 * S, 26 * S, argb(H.acc, 0xff))
			text_in(cv, s.f11, "r", bx + 10 * S + tw(s.f11b, b) + 6 * S, cy + 6 * S, 26 * S, argb(H.dim, 0xff))
			hit_add(a, bx, cy + 6 * S, bw, 26 * S, .Chip, 3, 0)
		}
	}
	rh := 46 * S
	for d, i in s.devs {
		ry := y + 2 * S + i * (rh + 3 * S)
		if ry + rh > list_b do break
		on := i == s.cur
		picked := false
		for p in s.picks do if p == d.fp do picked = true
		gone := d.age > 60
		x0, x1 := px, w - px
		if on {
			fill_rect(cv, x0, ry, x1 - x0, rh, argb(H.acc, 0x12))
			rounded_rect(cv, x0, ry, x1 - x0, rh, 0, 0, f32(S), argb(H.acc, 0xff))
			fill_rect(cv, x0, ry, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, x0, ry, x1 - x0, rh)
		} else if picked do rounded_rect(cv, x0, ry, x1 - x0, rh, 0, 0, f32(S), argb(H.acc, 0x66))
		// the pick box, the device, its name and what it is
		bx := x0 + 10 * S
		if picked do fill_rect(cv, bx, ry + (rh - 14 * S) / 2, 14 * S, 14 * S, argb(H.acc, 0xff))
		rounded_rect(cv, bx, ry + (rh - 14 * S) / 2, 14 * S, 14 * S, 0, 0, f32(S), argb(picked ? H.acc : (on ? H.dim : H.faint), 0xff))
		if picked do text_in(cv, s.f10b, "✓", bx + (14 * S - tw(s.f10b, "✓")) / 2, ry + (rh - 14 * S) / 2, 14 * S, argb(H.bg, 0xff))
		gx := bx + 14 * S + 12 * S
		ic := on ? H.acc : (gone ? H.faint : soft)
		fill_rect(cv, gx, ry + (rh - 28 * S) / 2, 28 * S, 28 * S, on ? argb(H.acc, 0x14) : argb(t.fg, 0x0a))
		rounded_rect(cv, gx, ry + (rh - 28 * S) / 2, 28 * S, 28 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
		g := send_icon(d.kind)
		text_in(cv, s.icon, g, gx + (28 * S - tw(s.icon, g)) / 2, ry + (rh - 28 * S) / 2, 28 * S, argb(ic, 0xff))
		// the status on the right
		status, stc, dot := d.age < 15 ? "just seen" : (gone ? "not answering" : fmt.tprintf("%d s ago", d.age)), gone ? H.dim : soft, gone ? H.faint : t.green
		prog: f32 = -1
		pc := H.acc
		if st, ok := s.targets[d.fp]; ok {
			p, _ := strconv.parse_f32(st[1])
			switch st[0] {
			case "waiting": status, stc, dot = "waiting for accept", t.yellow, t.yellow
			case "sending": status, stc, dot, prog = fmt.tprintf("sending %.0f%%", p * 100), H.acc, H.acc, p
			case "sent": status, stc, dot = "sent ✓", t.green, t.green
			case "declined": status, stc, dot = "declined", H.hot, H.hot
			case "failed": status, stc, dot, prog, pc = fmt.tprintf("lost at %.0f%%", p * 100), H.hot, H.hot, p, H.hot
			}
		}
		stw := tw(s.f10, status)
		text_in(cv, s.f10, status, x1 - 12 * S - stw, ry, rh, argb(stc, 0xff))
		fill_rect(cv, x1 - 12 * S - stw - 12 * S, ry + (rh - 6 * S) / 2, 6 * S, 6 * S, argb(dot, 0xff))
		nx := gx + 28 * S + 12 * S
		right := x1 - 12 * S - stw - 20 * S
		ny2 := ry + (rh - int(s.f12b.line_h) - 3 * S - int(s.f10.line_h)) / 2
		name := ellipsize(s.f12b, d.alias, right - nx - (d.trusted ? 70 * S : 0))
		text_in(cv, s.f12b, name, nx, ny2, int(s.f12b.line_h), argb(gone ? H.dim : H.fg, 0xff))
		if d.trusted {
			tgx := nx + tw(s.f12b, name) + 7 * S
			tgw := spaced_w(s.f9b, "TRUSTED", S) + 8 * S
			rounded_rect(cv, tgx, ny2 + (int(s.f12b.line_h) - 13 * S) / 2, tgw, 13 * S, 0, 0, f32(S), argb(H.dim, 0xff))
			spaced(cv, s.f9b, "TRUSTED", tgx + 4 * S, ny2 + (int(s.f12b.line_h) - 13 * S) / 2, 13 * S, H.dim, S)
		}
		sub := strings.join([]string{d.model != "" ? d.model : d.kind, d.ip}, " · ", context.temp_allocator)
		text_in(cv, s.f10, ellipsize(s.f10, sub, right - nx), nx, ny2 + int(s.f12b.line_h) + 3 * S, int(s.f10.line_h), argb(H.dim, 0xff))
		if prog >= 0 do fill_rect(cv, x0, ry + rh - 2 * S, int(f32(x1 - x0) * clamp(prog, 0, 1)), 2 * S, argb(pc, 0xff))
		hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
	}
	// the job panel
	if job_h > 0 {
		jy := fy - 10 * S - (job_h - 10 * S)
		jw := w - 2 * px
		title, sub, pct, meta: string
		c := H.acc
		acts := make([dynamic][3]string, 0, 2, context.temp_allocator) // label, key, chip id
		what := s.mode == "text" ? "the text" : (s.job_files == 1 ? "1 file" : fmt.tprintf("%d files", s.job_files))
		switch s.job_st {
		case "waiting":
			title, sub, c = fmt.tprintf("Waiting for %s", s.job_to), "They may be asked to accept · gives up after 2 min", t.yellow
			meta = fmt.tprintf("%s · %s", what, send_size(s.job_total))
			append(&acts, [3]string{"Cancel", "Esc", "0"})
		case "sending":
			title = fmt.tprintf("Sending to %s", s.job_to)
			sub = fmt.tprintf("%d of %d files · %s of %s", s.job_files_done, s.job_files, send_size(s.job_done), send_size(s.job_total))
			pct = fmt.tprintf("%.0f%%", s.job_p * 100)
			meta = fmt.tprintf("%s/s · %d s left", send_size(s.job_speed), max(s.job_left, 1))
			append(&acts, [3]string{"Cancel", "Esc", "0"})
		case "sent":
			c, pct = t.green, "✓"
			if s.mode == "text" { title, sub, meta = fmt.tprintf("Text sent to %s", s.job_to), "Shows up there as a message they can copy", fmt.tprintf("“%s”", s.title) }
			else { title, sub, meta = fmt.tprintf("Sent to %s", s.job_to), fmt.tprintf("%s · %s · in %.1f s", what, send_size(s.job_total), s.job_secs), s.title }
			if s.mode != "text" do append(&acts, [3]string{"Send more", "Tab", "2"})
			append(&acts, [3]string{"Done", "↵", "0"})
		case "declined":
			title, sub, c = fmt.tprintf("%s said no", s.job_to), "Nothing was sent", H.hot
			meta = "They can mark this machine as trusted to skip the question"
			append(&acts, [3]string{"Try again", "r", "1"}, [3]string{"OK", "↵", "0"})
		case "failed":
			title, c = fmt.tprintf("Lost connection to %s", s.job_to), H.hot
			sub = fmt.tprintf("Stopped at %.0f%% · %s of %s", s.job_p * 100, send_size(s.job_done), send_size(s.job_total))
			meta = "Timed out · same network?"
			append(&acts, [3]string{"Retry", "r", "1"}, [3]string{"OK", "↵", "0"})
		}
		jh := job_h - 10 * S
		fill_rect(cv, px, jy, jw, jh, argb(t.fg, 0x0a))
		rounded_rect(cv, px, jy, jw, jh, 0, 0, f32(S), argb(mix(H.bg, c, 0.4), 0xff))
		fill_rect(cv, px, jy, 3 * S, jh, argb(c, 0xff))
		yy := jy + 10 * S
		text_in(cv, s.f12b, title, px + 12 * S, yy, int(s.f12b.line_h), argb(c, 0xff))
		if pct != "" do text_in(cv, s.f12b, pct, px + jw - 12 * S - tw(s.f12b, pct), yy, int(s.f12b.line_h), argb(c, 0xff))
		sx := px + 12 * S + tw(s.f12b, title) + 10 * S
		text_in(cv, s.f10, ellipsize(s.f10, sub, px + jw - 24 * S - tw(s.f12b, pct) - sx), sx, yy, int(s.f12b.line_h), argb(soft, 0xff))
		yy += int(s.f12b.line_h) + 8 * S
		if s.job_st == "sending" || s.job_st == "failed" {
			segs := 24
			sw := (jw - 24 * S - (segs - 1) * 2 * S) / segs
			on := int(s.job_p * f32(segs) + 0.5)
			for i in 0 ..< segs do fill_rect(cv, px + 12 * S + i * (sw + 2 * S), yy, sw, 4 * S, argb(i < on ? (s.job_st == "failed" ? H.hot : H.acc) : H.line, 0xff))
			yy += 4 * S + 8 * S
		}
		ax := px + jw - 12 * S
		for i := len(acts) - 1; i >= 0; i -= 1 {
			ac := acts[i]
			bw := tw(s.f10b, ac[0]) + 6 * S + tw(s.f10, ac[1]) + 18 * S
			ax -= bw
			prim := ac[0] == "Done" || (ac[0] == "Retry")
			bc := ac[0] == "Retry" ? H.hot : H.acc
			if prim do fill_rect(cv, ax, yy, bw, 24 * S, argb(bc, 0xff))
			rounded_rect(cv, ax, yy, bw, 24 * S, 0, 0, f32(S), argb(prim ? bc : H.line, 0xff))
			text_in(cv, s.f10b, ac[0], ax + 9 * S, yy, 24 * S, argb(prim ? H.bg : soft, 0xff))
			text_in(cv, s.f10, ac[1], ax + 9 * S + tw(s.f10b, ac[0]) + 6 * S, yy, 24 * S, argb(prim ? H.bg : H.dim, 0xff))
			id, _ := strconv.parse_int(ac[2])
			hit_add(a, ax, yy, bw, 24 * S, .Chip, id, 0)
			ax -= 6 * S
		}
		text_in(cv, s.f10, ellipsize(s.f10, meta, ax - 10 * S - (px + 12 * S)), px + 12 * S, yy, 24 * S, argb(H.dim, 0xff))
	}
	// the footer
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	ff := pop ? s.f10 : s.f11
	if s.toast != "" do text_in(cv, ff, ellipsize(ff, s.toast, w - 2 * px - 40 * S), px, fy, fh, argb(H.acc, 0xff))
	else {
		HK: [][2]string
		switch {
		case send_busy(s): HK = {{"Esc", "Cancel"}}
		case pop: HK = {{"↑↓", "Pick"}, {"↵", "Send"}, {"Tab", "What"}, {"Esc", "Close"}}
		case: HK = {{"↑↓", "Pick"}, {"↵", "Send"}, {"␣", "Pick several"}, {"Tab", "What to send"}, {"v", "Visible"}, {"r", "Rescan"}, {"Esc", "Close"}}
		}
		kx := px
		for k in HK {
			kw := tw(ff, k[0]) + 10 * S
			fill_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, argb(t.fg, 0x0a))
			rounded_rect(cv, kx, fy + (fh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(H.line, 0xff))
			text_in(cv, ff, k[0], kx + 5 * S, fy, fh, argb(soft, 0xff))
			kx += kw + 6 * S
			text_in(cv, ff, k[1], kx, fy, fh, argb(H.dim, 0xff))
			kx += tw(ff, k[1]) + 14 * S
		}
	}
	if !pop do text_in(cv, ff, "k4", w - px - tw(ff, "k4"), fy, fh, argb(H.acc, 0xff))
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 24)
}

send_dump :: proc(a: ^App) -> string {
	s := a.send
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "send %s · %s · %d devices%s", s.kind, s.tab, len(s.devs), len(s.picks) > 0 ? fmt.tprintf(" · %d picked", len(s.picks)) : "")
	for d, i in s.devs {
		picked := false
		for p in s.picks do if p == d.fp do picked = true
		fmt.sbprintfln(&sb, "%s %s%s", i == s.cur ? "*" : " ", picked ? "[x] " : "", d.alias)
	}
	if s.job_st != "none" do fmt.sbprintfln(&sb, "job %s", s.job_st)
	if s.toast != "" do fmt.sbprintfln(&sb, "toast %s", s.toast)
	return strings.to_string(sb)
}
