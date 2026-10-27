package k4

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// --media: Media (the Kestrel design's Media popup, under the bar's media module): any MPRIS
// player, 420×500. The cover (or the player's glyph), state, title, artist and album; the
// position (a live stream: a red dashed line, no seeking); shuffle, previous, play, next, repeat;
// the volume; the players (Tab switches which one the popup, the media keys and the bar module
// follow). ␣ plays or pauses, ← → seek 5 s, ⇧← → change track, ↑↓ volume, s shuffle, r repeat,
// ↵ raises the player. The data comes from media-menu (panel lines R and L, panel.odin), again
// every 2 s while open; the position moves on between loads:
//   P <bus name> <player> <mono> <Playing|Paused|Stopped> <title>
//   N <bus name> <status> <title> <artist> <album> <length µs: -1 live, 0 unknown> <position µs>
//     <volume 0–100, -1 none> <shuffle 1|0|-> <loop None|Playlist|Track|-> <cover file> <can seek 1|0>
//     <can go next/previous 1|0>
// The runner's verbs: toggle BUS, seek BUS ±S, setpos BUS S, next BUS, prev BUS, volume BUS N,
// shuffle BUS, loop BUS, pick BUS, raise BUS.

MEDIA_W, MEDIA_H :: 420, 500

Media_Player :: struct { bus, name, mono, status, title: string }

Media :: struct {
	using pn: Panel,
	players: [dynamic]Media_Player,
	bus, status, title, artist, album, art, shuffle, loop: string,
	length, pos: f64, // seconds; length < 0 live, 0 unknown
	pos_at: time.Tick,
	volume: int,
	can_seek, can_skip: bool,
}

media_setup :: proc(a: ^App, data: string) {
	m := new(Media)
	m.mode = {draw = media_draw, key = media_key, click = media_click, scroll = media_scroll, loaded = media_loaded, ran = media_ran, tick = media_tick, dump = media_dump}
	panel_init(a, &m.pn, "media", data)
	m.refresh_ms = 2000
	a.width, a.height = MEDIA_W, MEDIA_H
}

@(private = "file")
M :: proc(a: ^App) -> ^Media { return (^Media)(a.pn) }

@(private = "file")
media_loaded :: proc(a: ^App, data: string) {
	m := M(a)
	for &x in m.players { delete(x.bus); delete(x.name); delete(x.mono); delete(x.status); delete(x.title) }
	clear(&m.players)
	have_now := false
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "P": append(&m.players, Media_Player{strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5))})
		case "N":
			have_now = true
			for s in ([]^string{&m.bus, &m.status, &m.title, &m.artist, &m.album, &m.art, &m.shuffle, &m.loop}) do delete(s^)
			m.bus, m.status, m.title, m.artist, m.album = strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4)), strings.clone(fget(f, 5))
			l, _ := strconv.parse_f64(fget(f, 6))
			ps, _ := strconv.parse_f64(fget(f, 7))
			m.length = l < 0 ? -1 : l / 1e6
			m.pos = ps / 1e6
			m.pos_at = time.tick_now()
			v, ok := strconv.parse_int(fget(f, 8))
			m.volume = ok ? v : -1
			m.shuffle, m.loop, m.art = strings.clone(fget(f, 9)), strings.clone(fget(f, 10)), strings.clone(fget(f, 11))
			m.can_seek, m.can_skip = fget(f, 12) == "1", fget(f, 13) != "0"
		}
	}
	if !have_now { delete(m.bus); m.bus = "" }
}

@(private = "file")
media_ran :: proc(a: ^App, verb, line: string) -> bool { return false }

@(private = "file")
media_tick :: proc(a: ^App) -> int {
	m := M(a)
	return m.bus != "" && m.status == "Playing" && m.length > 0 ? 1000 : -1 // the position moves
}

@(private = "file")
media_now :: proc(m: ^Media) -> f64 {
	p := m.pos
	if m.status == "Playing" do p += time.duration_seconds(time.tick_since(m.pos_at))
	return m.length > 0 ? clamp(p, 0, m.length) : max(p, 0)
}

@(private = "file")
mmss :: proc(s: f64) -> string {
	n := int(max(s, 0) + 0.5)
	if n >= 3600 do return fmt.tprintf("%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
	return fmt.tprintf("%d:%02d", n / 60, n % 60)
}

@(private = "file")
media_live :: proc(m: ^Media) -> bool { return m.length < 0 }

@(private = "file")
media_cur :: proc(m: ^Media) -> int {
	for p, i in m.players do if p.bus == m.bus do return i
	return 0
}

@(private = "file")
media_do :: proc(a: ^App, what: string) {
	m := M(a)
	if m.bus == "" do return
	switch what {
	case "toggle":
		m.pos = media_now(m); m.pos_at = time.tick_now()
		new_st := m.status == "Playing" ? "Paused" : "Playing"
		delete(m.status); m.status = strings.clone(new_st)
		panel_run(a, "toggle", m.bus)
	case "next", "prev":
		if !m.can_skip || media_live(m) { panel_say(&m.pn, "This player can’t change track", a.theme.yellow); return }
		panel_run(a, what, m.bus)
	case "shuffle", "loop", "raise": panel_run(a, what, m.bus)
	}
}

@(private = "file")
media_seek :: proc(a: ^App, d: f64) {
	m := M(a)
	if m.bus == "" do return
	if media_live(m) || !m.can_seek { panel_say(&m.pn, "A live stream can’t seek", a.theme.yellow); return }
	m.pos = media_now(m) + d
	m.pos_at = time.tick_now()
	panel_run(a, "seek", m.bus, fmt.tprintf("%+.0f", d))
}

@(private = "file")
media_vol :: proc(a: ^App, d: int) {
	m := M(a)
	if m.bus == "" || m.volume < 0 do return
	m.volume = clamp(m.volume + d, 0, 100)
	panel_run(a, "volume", m.bus, fmt.tprint(m.volume))
}

@(private = "file")
media_switch :: proc(a: ^App, d: int) {
	m := M(a)
	if len(m.players) < 2 do return
	i := (media_cur(m) + d + len(m.players)) % len(m.players)
	nb := m.players[i].bus
	delete(m.bus)
	m.bus = strings.clone(nb)
	panel_run(a, "pick", nb)
}

media_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := M(a)
	if ctrl && ch == 'c' { panel_close(a); return true }
	switch {
	case k == .Escape: panel_close(a)
	case m.bus == "": return false
	case text == " ": media_do(a, "toggle")
	case k == .Right: if a.shift do media_do(a, "next"); else do media_seek(a, 5)
	case k == .Left: if a.shift do media_do(a, "prev"); else do media_seek(a, -5)
	case k == .Up: media_vol(a, 5)
	case k == .Down: media_vol(a, -5)
	case k == .Tab: media_switch(a, 1)
	case k == .Back_Tab: media_switch(a, -1)
	case text == "s": media_do(a, "shuffle")
	case text == "r": media_do(a, "loop")
	case k == .Enter: media_do(a, "raise")
	case: return false
	}
	return true
}

media_scroll :: proc(a: ^App, n: int) -> bool { media_vol(a, n < 0 ? 5 : -5); return true }

media_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := M(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Chip:
		acts := [5]string{"shuffle", "prev", "toggle", "next", "loop"}
		if h.a < 5 do media_do(a, acts[h.a])
	case .Row:
		if h.a < len(m.players) && m.players[h.a].bus != m.bus {
			nb := m.players[h.a].bus
			delete(m.bus); m.bus = strings.clone(nb)
			panel_run(a, "pick", nb)
		}
	case .Slider: // the position bar: go there
		if media_live(m) || !m.can_seek || m.length <= 0 || h.w <= 0 do return true
		frac := f64(x - h.x) / f64(h.w)
		m.pos, m.pos_at = frac * m.length, time.tick_now()
		panel_run(a, "setpos", m.bus, fmt.tprintf("%.0f", frac * m.length))
	}
	return true
}

@(private = "file")
media_color :: proc(a: ^App, name: string) -> u32 {
	n := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.contains(n, "spotify"): return a.theme.green
	case strings.contains(n, "firefox"), strings.contains(n, "zen"): return a.theme.orange
	case strings.contains(n, "chrom"), strings.contains(n, "brave"): return a.theme.yellow
	case strings.contains(n, "mpv"), strings.contains(n, "vlc"): return a.theme.blue
	}
	return note_app_color(a.theme, name)
}

media_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := M(a)
	th := a.theme
	H := panel_ground(a, cv)
	w, h := cv.w, cv.h
	soft := mix(H.fg, H.bg, 0.2)
	playing := m.status == "Playing"
	np := fmt.tprintf("MPRIS · %d player%s", len(m.players), len(m.players) == 1 ? "" : "s")
	title := m.bus == "" ? "Media" : (playing ? "Now playing" : "Paused")
	hh, px, _ := panel_head(a, cv, S, H, "MEDIA", title, false, tw(m.f10, np))
	text_in(cv, m.f10, np, w - px - tw(m.f10, np), 0, hh, argb(H.dim, 0xff))
	fy := h - 30 * S
	if m.bus == "" {
		cy := hh + (fy - hh) / 2 - 80 * S
		bx := (w - 72 * S) / 2
		for i := 0; i < 72 * S; i += 6 * S { // a dashed square
			fill_rect(cv, bx + i, cy, 3 * S, S, argb(H.faint, 0xff)); fill_rect(cv, bx + i, cy + 72 * S - S, 3 * S, S, argb(H.faint, 0xff))
			fill_rect(cv, bx, cy + i, S, 3 * S, argb(H.faint, 0xff)); fill_rect(cv, bx + 72 * S - S, cy + i, S, 3 * S, argb(H.faint, 0xff))
		}
		text_in(cv, m.f24, "♪", bx + (72 * S - tw(m.f24, "♪")) / 2, cy, 72 * S, argb(H.faint, 0xff))
		cy += 72 * S + 12 * S
		l1 := "Nothing playing"
		text_in(cv, m.f13b, l1, (w - tw(m.f13b, l1)) / 2, cy, 20 * S, argb(H.fg, 0xff))
		cy += 26 * S
		for l in wrap_text(m.f11, "Any player that speaks MPRIS shows up here: Spotify, Firefox and Chrome tabs, mpv, VLC. The bar module hides until one starts.", w - 80 * S) {
			text_in(cv, m.f11, l, (w - tw(m.f11, l)) / 2, cy, 16 * S, argb(H.dim, 0xff))
			cy += 16 * S
		}
		panel_foot(a, cv, S, H, {{"Esc", "Close"}}, false)
		frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
		return
	}
	cp := media_cur(m)
	pname := cp < len(m.players) ? m.players[cp].name : ""
	pmono := cp < len(m.players) ? m.players[cp].mono : "♪"
	// the cover, and what plays
	y := hh + S + 16 * S
	ax := 16 * S
	as := 112 * S
	fill_rect(cv, ax, y, as, as, argb(a.theme.fg, 0x0d))
	art_ok := false
	if m.art != "" {
		img := image_cover(a, m.art, as, as)
		if img.ok { blit_image(cv, img.px, img.w, img.h, ax, y); art_ok = true }
	}
	if !art_ok {
		g := media_live(m) ? "◉" : "♪"
		text_in(cv, m.f34, g, ax + (as - tw(m.f34, g)) / 2, y, as, argb(H.faint, 0xff))
	}
	if playing do rounded_rect(cv, ax - S, y - S, as + 2 * S, as + 2 * S, 0, 0, f32(S), argb(H.acc, 0x40))
	rounded_rect(cv, ax, y, as, as, 0, 0, f32(S), argb(playing ? H.acc : H.line, 0xff))
	cx := ax + as + 14 * S
	cw := w - 16 * S - cx
	st, stc := playing ? "PLAYING" : (m.status == "Stopped" ? "STOPPED" : "PAUSED"), playing ? H.acc : H.dim
	if media_live(m) && playing do st, stc = "● LIVE", H.hot
	tg := panel_tag(cv, m.f9b, cx, y, 0, 14 * S, S, st, stc)
	_ = tg
	ty := y + 14 * S + 5 * S
	tl := wrap_text(m.f15b, m.title != "" ? m.title : "Untitled", cw)
	for l, i in tl {
		if i >= 2 do break
		s := l
		if i == 1 && len(tl) > 2 do s = ellipsize(m.f15b, strings.concatenate({l, " …"}, context.temp_allocator), cw)
		text_in(cv, m.f15b, ellipsize(m.f15b, s, cw), cx, ty, 20 * S, argb(playing ? H.fg : soft, 0xff))
		ty += 20 * S
	}
	ty += 3 * S
	text_in(cv, m.f12, ellipsize(m.f12, m.artist, cw), cx, ty, int(m.f12.line_h), argb(soft, 0xff))
	ty += int(m.f12.line_h) + 3 * S
	text_in(cv, m.f10, ellipsize(m.f10, m.album, cw), cx, ty, int(m.f10.line_h), argb(H.dim, 0xff))
	from := fmt.tprintf("from %s%s", pname, len(m.players) > 1 ? fmt.tprintf(" · %d of %d", cp + 1, len(m.players)) : "")
	text_in(cv, m.f10, ellipsize(m.f10, from, cw), cx, y + as - int(m.f10.line_h), int(m.f10.line_h), argb(H.dim, 0xff))
	// the position
	y += as + 12 * S
	bw := w - 32 * S
	fill_rect(cv, 16 * S, y + 3 * S, bw, 3 * S, argb(H.line, 0xff))
	now := media_now(m)
	if media_live(m) {
		for i := 0; i < bw; i += 10 * S do fill_rect(cv, 16 * S + i, y + 3 * S, min(6 * S, bw - i), 3 * S, argb(H.hot, 0xff))
	} else if m.length > 0 {
		pw := int(f64(bw) * clamp(now / m.length, 0, 1))
		bc := playing ? H.acc : H.dim
		fill_rect(cv, 16 * S, y + 3 * S, pw, 3 * S, argb(bc, 0xff))
		fill_rect(cv, 16 * S + pw - S, y - 0 * S, 3 * S, 10 * S, argb(bc, 0xff))
	}
	hit_add(a, 16 * S, y - 4 * S, bw, 18 * S, .Slider, 0, 0)
	y += 10 * S + 5 * S
	pos_l := media_live(m) ? "live" : mmss(now)
	len_l := media_live(m) ? "no length · can’t seek" : (m.length > 0 ? fmt.tprintf("-%s · %s", mmss(m.length - now), mmss(m.length)) : "")
	text_in(cv, m.f10, pos_l, 16 * S, y, int(m.f10.line_h), argb(soft, 0xff))
	text_in(cv, m.f10, len_l, w - 16 * S - tw(m.f10, len_l), y, int(m.f10.line_h), argb(media_live(m) ? H.hot : H.dim, 0xff))
	y += int(m.f10.line_h) + 12 * S
	// the controls
	Ctl :: struct { g, k: string, w: int, on, off, prime: bool }
	ctl := [5]Ctl{
		{"󰒝", "s", 52, m.shuffle == "1", media_live(m) || m.shuffle == "-", false},
		{"󰒮", "⇧←", 52, false, media_live(m) || !m.can_skip, false},
		{playing ? "󰏤" : "󰐊", "␣", 72, false, false, true},
		{"󰒭", "⇧→", 52, false, media_live(m) || !m.can_skip, false},
		{m.loop == "Track" ? "󰑘" : "󰑖", "r", 52, m.loop == "Playlist" || m.loop == "Track", media_live(m) || m.loop == "-", false},
	}
	total := -8 * S
	for c in ctl do total += c.w * S + 8 * S
	bx := (w - total) / 2
	for c, i in ctl {
		cw2 := c.w * S
		bh := 34 * S
		fg, bd, kc := soft, H.line, H.faint
		if c.prime { fill_rect(cv, bx, y, cw2, bh, argb(H.acc, 0xff)); fg, bd, kc = H.bg, H.acc, H.bg }
		else if c.on do fg, bd = H.acc, H.acc
		if c.off && !c.on do fg, bd, kc = mix(fg, H.bg, 0.65), mix(bd, H.bg, 0.65), mix(kc, H.bg, 0.65)
		rounded_rect(cv, bx, y, cw2, bh, 0, 0, f32(S), argb(bd, 0xff))
		gy := y + 3 * S
		text_in(cv, m.icon, c.g, bx + (cw2 - tw(m.icon, c.g)) / 2, gy, 18 * S, argb(fg, 0xff))
		text_in(cv, m.f8, c.k, bx + (cw2 - tw(m.f8, c.k)) / 2, gy + 18 * S, 11 * S, argb(kc, 0xff))
		hit_add(a, bx, y, cw2, bh, .Chip, i, 0)
		bx += cw2 + 8 * S
	}
	y += 34 * S + 14 * S
	// the volume
	if m.volume >= 0 {
		text_in(cv, m.f11, "Volume", 16 * S, y, 14 * S, argb(H.dim, 0xff))
		vx := 16 * S + 60 * S + 10 * S
		vr := w - 16 * S - tw(m.f9, "↑↓") - 10 * S - 36 * S - 10 * S
		panel_meter(cv, vx, y + 6 * S, vr - vx, 3 * S, f32(m.volume) / 100, H.acc, H.line)
		vl := fmt.tprintf("%d%%", m.volume)
		text_in(cv, m.f11b, vl, vr + 10 * S + 36 * S - tw(m.f11b, vl), y, 14 * S, argb(H.fg, 0xff))
		text_in(cv, m.f9, "↑↓", w - 16 * S - tw(m.f9, "↑↓"), y, 14 * S, argb(H.faint, 0xff))
		y += 14 * S + 10 * S
	}
	// the players
	fill_rect(cv, 0, y, w, S, argb(H.line, 0xff))
	y += S + 6 * S
	panel_group(a, cv, S, 16 * S, y, 20 * S, H, "PLAYERS", len(m.players) > 1 ? "Tab switches" : "")
	y += 20 * S
	for pl, i in m.players {
		if y + 30 * S > fy - 4 * S do break
		on := pl.bus == m.bus
		x0, x1 := 8 * S, w - 8 * S
		if on {
			fill_rect(cv, x0, y, x1 - x0, 30 * S, argb(H.acc, 0x14))
			rounded_rect(cv, x0, y, x1 - x0, 30 * S, 0, 0, f32(S), argb(H.acc, 0xff))
		}
		pc := media_color(a, pl.name)
		fill_rect(cv, x0 + 10 * S, y + 6 * S, 18 * S, 18 * S, argb(pc, 0x1a))
		rounded_rect(cv, x0 + 10 * S, y + 6 * S, 18 * S, 18 * S, 0, 0, f32(S), argb(pc, 0x55))
		text_in(cv, m.f9b, pl.mono, x0 + 10 * S + (18 * S - tw(m.f9b, pl.mono)) / 2, y + 6 * S, 18 * S, argb(pc, 0xff))
		pst := strings.to_lower(pl.status, context.temp_allocator)
		if on && pl.status == "Playing" do pst = "● playing"
		sw := tw(m.f10, pst)
		text_in(cv, m.f10, pst, x1 - 10 * S - sw, y, 30 * S, argb(on && pl.status == "Playing" ? H.acc : H.dim, 0xff))
		lx := x0 + 10 * S + 18 * S + 9 * S
		lab := pl.title != "" ? fmt.tprintf("%s · %s", pl.name, pl.title) : pl.name
		text_in(cv, m.f11, ellipsize(m.f11, lab, x1 - 20 * S - sw - lx), lx, y, 30 * S, argb(H.fg, 0xff))
		hit_add(a, x0, y, x1 - x0, 30 * S, .Row, i, 0)
		y += 30 * S + 2 * S
	}
	_ = pmono
	panel_foot(a, cv, S, H, {{"␣", "Play"}, {"← →", "Seek"}, {"⇧← →", "Track"}, {"↑↓", "Volume"}, {"↵", "Raise"}}, false)
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 22)
	_ = th
}

media_dump :: proc(a: ^App) -> string {
	m := M(a)
	sb := strings.builder_make(context.temp_allocator)
	if m.bus == "" do fmt.sbprintfln(&sb, "media nothing playing · %d players", len(m.players))
	else {
		fmt.sbprintfln(&sb, "media %s · %s — %s · %s", m.status, m.title, m.artist, m.album)
		fmt.sbprintfln(&sb, "position %s / %s · volume %d · shuffle %s · loop %s", media_live(m) ? "live" : mmss(m.pos), media_live(m) ? "live" : mmss(m.length), m.volume, m.shuffle, m.loop)
	}
	for p in m.players do fmt.sbprintfln(&sb, "%s %s · %s · %s", p.bus == m.bus ? "*" : " ", p.name, p.status, p.title)
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
