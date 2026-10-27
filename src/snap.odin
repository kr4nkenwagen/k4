package k4

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// --snap: Snapshots (the Kestrel design's System › Snapshots, from Perf › Utilities): 680×560.
// How much of / the system and the snapshots take, then the snapshots newest first under the
// running system: number, when, what (PRE and POST of a package change joined by a bracket, AUTO
// for timeline ones, ◆ kept for ones the cleanup leaves alone) and size. ↵ or c compares the
// picked one with the system (or a pre with its post), n takes one, r restores one (asks; it
// takes effect at the next boot), k keeps or releases one, Del deletes it with its pair (asks).
// Running from a snapshot shows what to do about it. Without permission or without btrfs a
// notice says what would fix it. The data comes from k4-snap (panel lines R and L, panel.odin):
//   S <ok|noperm|unsupported> <tool, e.g. "snapper · root · number 5"> <system size> <snapshots
//     size> <free> <system 0–1> <snapshots 0–1> <booted snapshot or 0> <a note for noperm/unsupported>
//   N <number> <when> <what> <single|pre|post> <pair> <size> <auto 1|0> <keep 1|0>
// The runner's verbs: compare N (prints k4:diff TITLE and k4:dl SIGN TEXT lines; ↵ in its panel:
// diff N), create, restore N, keep N, release N, delete N [PAIR], keepboot, reboot, allow,
// list, install, learn.

SNAP_W, SNAP_H :: 680, 560

Snapshot :: struct { n, pair: int, at, what, kind, size: string, auto, keep: bool }

Snap_Panel :: enum { None, Diff, Restore, Delete, Taking }

Snap :: struct {
	using pn: Panel,
	state, tool, sys, snaps, free, note: string,
	sys_f, snap_f: f32,
	booted: int,
	list: [dynamic]Snapshot,
	cur: int, // 0 the running system, then list[cur-1]
	sel: int, // the picked snapshot's number (0: the system)
	scroll: int,
	panel: Snap_Panel,
	diff_title: string,
	diff: [dynamic][2]string,
	taking_at: time.Tick,
	fix: int, // the picked row of the noperm / unsupported page
}

snap_setup :: proc(a: ^App, data: string) {
	s := new(Snap)
	s.mode = {draw = snap_draw, key = snap_key, click = snap_click, scroll = snap_scroll, loaded = snap_loaded, ran = snap_ran, tick = snap_tick, dump = snap_dump}
	panel_init(a, &s.pn, "snap", data)
	a.width, a.height = SNAP_W, SNAP_H
}

@(private = "file")
Sn :: proc(a: ^App) -> ^Snap { return (^Snap)(a.pn) }

@(private = "file")
snap_loaded :: proc(a: ^App, data: string) {
	s := Sn(a)
	for &x in s.list { delete(x.at); delete(x.what); delete(x.kind); delete(x.size) }
	clear(&s.list)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			for p in ([]^string{&s.state, &s.tool, &s.sys, &s.snaps, &s.free, &s.note}) do delete(p^)
			s.state, s.tool, s.sys, s.snaps, s.free = strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5))
			s.sys_f, _ = strconv.parse_f32(fget(f, 6))
			s.snap_f, _ = strconv.parse_f32(fget(f, 7))
			s.booted, _ = strconv.parse_int(fget(f, 8))
			s.note = strings.clone(fget(f, 9))
		case "N":
			x: Snapshot
			x.n, _ = strconv.parse_int(fget(f, 1))
			x.at, x.what, x.kind = strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4))
			x.pair, _ = strconv.parse_int(fget(f, 5))
			x.size = strings.clone(fget(f, 6))
			x.auto, x.keep = fget(f, 7) == "1", fget(f, 8) == "1"
			append(&s.list, x)
		}
	}
	if s.state == "" do s.state = "ok"
	s.cur = 0
	for x, i in s.list do if x.n == s.sel do s.cur = i + 1
}

@(private = "file")
snap_ran :: proc(a: ^App, verb, line: string) -> bool {
	s := Sn(a)
	switch {
	case strings.has_prefix(line, "k4:diff "):
		delete(s.diff_title)
		s.diff_title = strings.clone(line[8:])
		for &d in s.diff { delete(d[0]); delete(d[1]) }
		clear(&s.diff)
		s.panel = .Diff
	case strings.has_prefix(line, "k4:dl "):
		rest := line[6:]
		sp := strings.index_byte(rest, '\t')
		if sp < 0 do sp = strings.index_byte(rest, ' ')
		if sp < 0 do return true
		append(&s.diff, [2]string{strings.clone(rest[:sp]), strings.clone(rest[sp + 1:])})
	case: return false
	}
	return true
}

@(private = "file")
snap_tick :: proc(a: ^App) -> int {
	s := Sn(a)
	if s.panel == .Taking {
		if !s.pn.run.running && !(a.opts.dump || a.opts.dry_run != "") do s.panel = .None
		return 80
	}
	return -1
}

@(private = "file")
snap_sel :: proc(s: ^Snap) -> ^Snapshot { return s.cur > 0 && s.cur <= len(s.list) ? &s.list[s.cur - 1] : nil }

@(private = "file")
snap_pick :: proc(s: ^Snap, i: int) {
	s.cur = clamp(i, 0, len(s.list))
	x := snap_sel(s)
	s.sel = x != nil ? x.n : 0
	if s.panel != .Taking do s.panel = .None
	panel_say(&s.pn, "")
}

@(private = "file")
snap_take :: proc(a: ^App) {
	s := Sn(a)
	s.panel = .Taking
	s.taking_at = time.tick_now()
	panel_run(a, "create")
}

@(private = "file")
SNAP_FIX_PERM := [][3]string{{"Allow my user to use snapper", "asks for your password once, in a terminal", "allow"}, {"List them in a terminal", "sudo snapper list", "list"}, {"What snapper needs", "wiki ↗", "learn"}}
@(private = "file")
SNAP_FIX_FS := [][3]string{{"Install Timeshift (rsync to another disk)", "a terminal", "install"}, {"What btrfs snapshots need", "wiki ↗", "learn"}}

@(private = "file")
snap_fixes :: proc(s: ^Snap) -> [][3]string { return s.state == "noperm" ? SNAP_FIX_PERM : SNAP_FIX_FS } // label, meta, verb

snap_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	s := Sn(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	if s.state != "ok" {
		fx := snap_fixes(s)
		switch {
		case k == .Down: s.fix = min(s.fix + 1, len(fx) - 1)
		case k == .Up: s.fix = max(s.fix - 1, 0)
		case k == .Enter: panel_run(a, fx[s.fix][2])
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	x := snap_sel(s)
	if s.panel == .Restore || s.panel == .Delete {
		switch {
		case text == "y":
			if x != nil {
				if s.panel == .Restore do panel_run(a, "restore", fmt.tprint(x.n))
				else if x.pair > 0 do panel_run(a, "delete", fmt.tprint(x.n), fmt.tprint(x.pair))
				else do panel_run(a, "delete", fmt.tprint(x.n))
			}
			s.panel = .None
		case text == "n" || k == .Escape: s.panel = .None
		case: return false
		}
		return true
	}
	switch {
	case k == .Down: snap_pick(s, s.cur + 1)
	case k == .Up: snap_pick(s, s.cur - 1)
	case k == .Page_Down: snap_pick(s, s.cur + 10)
	case k == .Page_Up: snap_pick(s, s.cur - 10)
	case text == "n": snap_take(a)
	case k == .Escape: if s.panel != .None && s.panel != .Taking do s.panel = .None; else do panel_close(a)
	case s.booted > 0 && x == nil && k == .Enter: panel_run(a, "keepboot")
	case s.booted > 0 && text == "b": panel_run(a, "reboot")
	case x == nil && k == .Enter: snap_take(a)
	case x == nil: return false
	case k == .Enter || text == "c":
		if s.panel == .Diff && k == .Enter do panel_run(a, "diff", fmt.tprint(x.n))
		else if s.panel == .Diff do s.panel = .None
		else do panel_run(a, "compare", fmt.tprint(x.n))
	case text == "r": s.panel = .Restore; panel_say(&s.pn, "")
	case text == "k":
		x.keep = !x.keep
		panel_run(a, x.keep ? "keep" : "release", fmt.tprint(x.n))
	case k == .Delete: s.panel = .Delete; panel_say(&s.pn, "")
	case: return false
	}
	return true
}

snap_scroll :: proc(a: ^App, n: int) -> bool { s := Sn(a); snap_pick(s, s.cur + n); return true }

snap_click :: proc(a: ^App, x, y, button: int) -> bool {
	s := Sn(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row:
		if s.state != "ok" { s.fix = h.a; panel_run(a, snap_fixes(s)[h.a][2]); return true }
		if h.a == s.cur do snap_key(a, .Enter, false, false, 0, "")
		else do snap_pick(s, h.a)
	case .Chip:
		sx := snap_sel(s)
		switch s.panel {
		case .Diff: if h.a == 0 && sx != nil do panel_run(a, "diff", fmt.tprint(sx.n)); else do s.panel = .None
		case .Restore, .Delete: snap_key(a, .None, false, false, h.a == 0 ? 'y' : 'n', h.a == 0 ? "y" : "n")
		case .None: if s.booted > 0 { if h.a == 0 do panel_run(a, "keepboot"); else do panel_run(a, "reboot") }
		case .Taking:
		}
	}
	return true
}

snap_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	s := Sn(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	title := s.state == "unsupported" ? "Not available on this disk" : (s.state == "noperm" ? "Needs permission" : fmt.tprintf("%d snapshots", len(s.list)))
	hh, px, _ := panel_head(a, cv, S, H, "SYSTEM › SNAPSHOTS", title, false, tw(s.f10, s.tool))
	text_in(cv, s.f10, s.tool, w - px - tw(s.f10, s.tool), 0, hh, argb(H.dim, 0xff))
	fy := h - 30 * S
	if s.state != "ok" {
		y := hh + S + 16 * S
		nt := s.state == "noperm" ? "Snapper needs permission once" : "Snapshots need btrfs, or Timeshift in rsync mode"
		y += panel_notice(a, cv, S, 16 * S, y, w - 32 * S, H, nt, s.note, th.yellow) + 10 * S
		for f, i in snap_fixes(s) {
			on := i == s.fix
			if on do fill_rect(cv, 16 * S, y, w - 32 * S, 40 * S, argb(H.acc, 0xff))
			rounded_rect(cv, 16 * S, y, w - 32 * S, 40 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
			text_in(cv, s.f12b, f[0], 28 * S, y, 40 * S, argb(on ? H.bg : H.fg, 0xff))
			text_in(cv, s.f10, f[1], w - 28 * S - tw(s.f10, f[1]), y, 40 * S, argb(on ? H.bg : H.dim, 0xff))
			if on do mark_sel(a, 16 * S, y, w - 32 * S, 40 * S)
			hit_add(a, 16 * S, y, w - 32 * S, 40 * S, .Row, i, 0)
			y += 40 * S + 10 * S
		}
		panel_foot(a, cv, S, H, {{"↑↓", "Move"}, {"↵", "Do it"}, {"Esc", "Close"}}, false)
		frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
		return
	}
	// how / is used
	y := hh + S
	bh := 10 * S + int(s.f10.line_h) + 10 * S
	text_in(cv, s.f10, "/ btrfs", 16 * S, y, bh, argb(H.dim, 0xff))
	r1 := fmt.tprintf("%s system · ", s.sys)
	r2 := strings.has_suffix(s.snaps, "snapshots") ? s.snaps : fmt.tprintf("%s in snapshots", s.snaps)
	r3 := fmt.tprintf(" · %s free", s.free)
	rw := tw(s.f10, r1) + tw(s.f10, r2) + tw(s.f10, r3)
	rx := w - 16 * S - rw
	text_in(cv, s.f10, r1, rx, y, bh, argb(soft, 0xff))
	text_in(cv, s.f10, r2, rx + tw(s.f10, r1), y, bh, argb(H.acc, 0xff))
	text_in(cv, s.f10, r3, rx + tw(s.f10, r1) + tw(s.f10, r2), y, bh, argb(soft, 0xff))
	mx := 16 * S + tw(s.f10, "/ btrfs") + 10 * S
	mw := rx - 10 * S - mx
	fill_rect(cv, mx, y + (bh - 5 * S) / 2, mw, 5 * S, argb(H.line, 0xff))
	sw1 := int(f32(mw) * clamp(s.sys_f, 0, 1))
	fill_rect(cv, mx, y + (bh - 5 * S) / 2, sw1, 5 * S, argb(soft, 0xff))
	fill_rect(cv, mx + sw1, y + (bh - 5 * S) / 2, min(int(f32(mw) * clamp(s.snap_f, 0, 1)), mw - sw1), 5 * S, argb(H.acc, 0xff))
	y += bh
	fill_rect(cv, 0, y, w, S, argb(H.line, 0xff))
	y += S
	// the columns
	cx_n, cx_w := 44 * S, 44 * S + 34 * S + 10 * S
	cx_what := cx_w + 120 * S + 10 * S
	cx_size := w - 16 * S
	spaced(cv, s.f10b, "#", cx_n, y, 24 * S, H.dim, S)
	spaced(cv, s.f10b, "WHEN", cx_w, y, 24 * S, H.dim, S)
	spaced(cv, s.f10b, "WHAT", cx_what, y, 24 * S, H.dim, S)
	spaced(cv, s.f10b, "SIZE", cx_size - spaced_w(s.f10b, "SIZE", S), y, 24 * S, H.dim, S)
	y += 24 * S
	// the panel at the bottom
	x := snap_sel(s)
	pt, pc := "", H.acc
	plines := make([dynamic][3]string, 0, 4, context.temp_allocator) // sign, text, tone
	pacts := make([dynamic][3]string, 0, 2, context.temp_allocator)
	pbar := false
	switch {
	case s.panel == .Diff && x != nil:
		pt = s.diff_title != "" ? s.diff_title : fmt.tprintf("What changed since #%d", x.n)
		for d in s.diff do append(&plines, [3]string{d[0], d[1], d[0]})
		if len(s.diff) == 0 do append(&plines, [3]string{"", "Nothing changed.", ""})
		append(&pacts, [3]string{"Full diff in a terminal", "↵", "prime"}, [3]string{"Close", "Esc", ""})
	case s.panel == .Restore && x != nil:
		pt, pc = fmt.tprintf("Go back to #%d?", x.n), H.hot
		append(&plines, [3]string{"1", fmt.tprintf("Boots into #%d (%s) next time; what came after it is set aside, not deleted.", x.n, x.at), "red"})
		append(&plines, [3]string{"2", "Your home folder is not touched: /home is its own subvolume.", "red"})
		append(&plines, [3]string{"3", "Changed your mind? The current system is kept as a snapshot too.", "red"})
		append(&pacts, [3]string{"Restore", "y", "hot"}, [3]string{"Cancel", "n", ""})
	case s.panel == .Delete && x != nil:
		pt, pc = x.pair > 0 ? fmt.tprintf("Delete #%d and #%d?", x.n, x.pair) : fmt.tprintf("Delete #%d?", x.n), H.hot
		append(&plines, [3]string{"", x.pair > 0 ? "A pre and post snapshot go together. This can’t be undone." : "This can’t be undone.", "red"})
		append(&pacts, [3]string{"Delete", "y", "hot"}, [3]string{"Cancel", "n", ""})
	case s.panel == .Taking:
		pt = "Taking a snapshot of /"
		append(&plines, [3]string{"", "btrfs subvolume snapshot · usually a few seconds; you can keep working", ""})
		pbar = true
	case s.booted > 0:
		pt, pc = fmt.tprintf("You are running snapshot #%d (read-only)", s.booted), th.yellow
		append(&plines, [3]string{"", "Make it the system to keep it after the next reboot, or reboot to go back to how things were.", ""})
		append(&pacts, [3]string{"Keep this one", "↵", "prime"}, [3]string{"Reboot back", "b", ""})
	}
	ph := 0
	if pt != "" do ph = 10 * S + int(s.f12b.line_h) + 7 * S + len(plines) * 15 * S + (pbar ? 3 * S + 7 * S : 0) + (len(pacts) > 0 ? 7 * S + 24 * S : 0) + 10 * S
	list_b := fy - 6 * S - (ph > 0 ? ph + 10 * S : 0)
	// the rows, the system first, scrolled to keep the picked one in view
	lh := list_b - y
	rh := 30 * S
	n := len(s.list) + 1
	if s.cur * rh < s.scroll do s.scroll = s.cur * rh
	if (s.cur + 1) * rh > s.scroll + lh do s.scroll = (s.cur + 1) * rh - lh
	s.scroll = clamp(s.scroll, 0, max(n * rh - lh, 0))
	list := Canvas{cv.px[y * w:], w, max(lh, 0)}
	nh := len(a.hits)
	for i in 0 ..< n {
		ry := i * rh - s.scroll
		if ry + rh < 0 do continue
		if ry > lh do break
		on := i == s.cur
		sn := i > 0 ? &s.list[i - 1] : nil
		pair_on := x != nil && x.pair > 0 && sn != nil && (sn.n == x.pair)
		x0, x1 := 10 * S, w - 10 * S
		sel_c := s.panel == .Restore || s.panel == .Delete ? H.hot : H.acc
		if on { fill_rect(&list, x0, ry, x1 - x0, rh, argb(sel_c, 0xff)); mark_sel(a, x0, ry + y, x1 - x0, rh) }
		else if pair_on do fill_rect(&list, x0, ry, x1 - x0, rh, argb(H.acc, 0x10))
		fg := on ? H.bg : H.fg
		dc := on ? H.bg : H.dim
		lx := x0 + 12 * S
		if sn == nil { // the running system: a square
			nc := on ? H.bg : (s.booted > 0 ? th.yellow : th.green)
			fill_rect(&list, lx, ry + (rh - 8 * S) / 2, 8 * S, 8 * S, argb(nc, 0xff))
		} else if sn.kind == "pre" || sn.kind == "post" { // the bracket joining a pre and its post
			lc := on ? H.bg : (pair_on || (x != nil && x.n == sn.n) ? H.acc : H.dim)
			if sn.kind == "post" { fill_rect(&list, lx, ry + rh / 2, S, rh - rh / 2, argb(lc, 0xff)); fill_rect(&list, lx, ry + rh / 2, 8 * S, S, argb(lc, 0xff)) }
			else { fill_rect(&list, lx, ry, S, rh / 2 + S, argb(lc, 0xff)); fill_rect(&list, lx, ry + rh / 2, 8 * S, S, argb(lc, 0xff)) }
		}
		num := sn != nil ? fmt.tprintf("#%d", sn.n) : ""
		at := sn != nil ? sn.at : (s.booted > 0 ? fmt.tprintf("booted from #%d", s.booted) : "running")
		what := sn != nil ? sn.what : (s.booted > 0 ? fmt.tprintf("Running snapshot #%d read-only · make it permanent or go back", s.booted) : "Current system")
		text_in(&list, s.f11, num, cx_n, ry, rh, argb(dc, 0xff))
		text_in(&list, s.f11, ellipsize(s.f11, at, 120 * S), cx_w, ry, rh, argb(dc, 0xff))
		size := sn != nil ? sn.size : ""
		szw := tw(s.f11, size)
		text_in(&list, s.f11, size, cx_size - szw, ry, rh, argb(dc, 0xff))
		tx := cx_what
		tag, tagc := "", H.dim
		switch {
		case sn == nil: tag, tagc = s.booted > 0 ? "SNAPSHOT" : "NOW", s.booted > 0 ? th.yellow : th.green
		case sn.kind == "pre": tag, tagc = "PRE", H.acc
		case sn.kind == "post": tag, tagc = "POST", H.acc
		case sn.auto: tag = "AUTO"
		}
		if tag != "" do tx += panel_tag(&list, s.f9b, tx, ry + (rh - 13 * S) / 2, 0, 13 * S, S, tag, on ? H.bg : tagc) + 7 * S
		kept := sn != nil && sn.keep
		kw := kept ? tw(s.f9, "◆ kept") + 7 * S : 0
		wf := on || sn == nil ? s.f11b : s.f11
		ws := ellipsize(wf, what, cx_size - szw - 12 * S - kw - tx)
		text_in(&list, wf, ws, tx, ry, rh, argb(fg, 0xff))
		if kept do text_in(&list, s.f9, "◆ kept", tx + tw(wf, ws) + 7 * S, ry, rh, argb(on ? H.bg : H.acc, 0xff))
		hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
	}
	for &hh2 in a.hits[nh:] {
		hh2.y += y
		y0, y1 := max(hh2.y, y), min(hh2.y + hh2.h, y + lh)
		hh2.y, hh2.h = y0, max(y1 - y0, 0)
	}
	if ph > 0 {
		py := fy - 10 * S - ph
		pw := w - 20 * S
		bgc := pc == H.acc ? argb(a.theme.fg, 0x0d) : argb(pc, 0x12)
		fill_rect(cv, 10 * S, py, pw, ph, bgc)
		rounded_rect(cv, 10 * S, py, pw, ph, 0, 0, f32(S), argb(pc, 0xff))
		fill_rect(cv, 10 * S, py, 3 * S, ph, argb(pc, 0xff))
		yy := py + 10 * S
		text_in(cv, s.f12b, ellipsize(s.f12b, pt, pw - 24 * S), 22 * S, yy, int(s.f12b.line_h), argb(pc, 0xff))
		yy += int(s.f12b.line_h) + 7 * S
		for l in plines {
			sc := H.dim
			switch {
			case l[2] == "red": sc = H.hot
			case strings.has_prefix(l[2], "+"): sc = th.green
			case strings.has_prefix(l[2], "~"): sc = th.yellow
			case strings.has_prefix(l[2], "-"), strings.has_prefix(l[2], "−"): sc = H.hot
			}
			tx := 22 * S
			if l[0] != "" { text_in(cv, s.f10b, l[0], tx, yy, 15 * S, argb(sc, 0xff)); tx += 36 * S }
			text_in(cv, s.f10, ellipsize(s.f10, l[1], pw - (tx - 10 * S) - 12 * S), tx, yy, 15 * S, argb(soft, 0xff))
			yy += 15 * S
		}
		if pbar { // nothing measures a snapshot's progress: a segment that runs along
			yy += 3 * S
			bw := pw - 24 * S
			fill_rect(cv, 22 * S, yy, bw, 3 * S, argb(H.line, 0xff))
			ph2 := f32(time.duration_milliseconds(time.tick_since(s.taking_at))) / 1400
			seg := bw / 4
			sx := int((ph2 - f32(int(ph2))) * f32(bw + seg)) - seg
			fill_rect(cv, 22 * S + max(sx, 0), yy, min(seg, bw - max(sx, 0)), 3 * S, argb(H.acc, 0xff))
			yy += 3 * S + 7 * S
		}
		if len(pacts) > 0 {
			yy += 7 * S
			bx := 22 * S
			for ac, j in pacts {
				kind := Btn_Kind.Plain
				if ac[2] == "prime" do kind = .Prime
				if ac[2] == "hot" do kind = .Hot
				bx += panel_btn(a, cv, S, bx, yy, 24 * S, H, ac[0], ac[1], kind, j) + 6 * S
			}
		}
	}
	hints: [][2]string = s.panel == .Restore || s.panel == .Delete ? {{"y", s.panel == .Restore ? "Restore" : "Delete"}, {"n", "Cancel"}} : {{"↑↓", "Move"}, {"↵ c", "Compare"}, {"n", "New"}, {"r", "Restore"}, {"k", "Keep"}, {"Del", "Delete"}}
	keep, tone := s.pn.toast, s.pn.tone
	if strings.has_prefix(keep, "Deleted") || strings.has_prefix(keep, "Rebooting") do s.pn.tone = H.hot
	panel_foot(a, cv, S, H, hints, false)
	s.pn.tone = tone
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
}

snap_dump :: proc(a: ^App) -> string {
	s := Sn(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "snap %s · %d snapshots%s · panel %v", s.state, len(s.list), s.booted > 0 ? fmt.tprintf(" · booted #%d", s.booted) : "", s.panel)
	if s.state != "ok" {
		for f, i in snap_fixes(s) do fmt.sbprintfln(&sb, "%s %s", i == s.fix ? "*" : " ", f[0])
	} else {
		fmt.sbprintfln(&sb, "%s now", s.cur == 0 ? "*" : " ")
		for x, i in s.list do fmt.sbprintfln(&sb, "%s #%d %s · %s · %s%s%s", i + 1 == s.cur ? "*" : " ", x.n, x.at, x.kind, x.what, x.auto ? " · auto" : "", x.keep ? " · kept" : "")
	}
	if s.panel == .Diff do for d in s.diff do fmt.sbprintfln(&sb, "diff %s %s", d[0], d[1])
	panel_dump_toast(&s.pn, &sb)
	return strings.to_string(sb)
}
