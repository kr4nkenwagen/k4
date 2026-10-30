package k4

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// --youtube: YouTube (k4-youtube, over yt-dlp and one mpv), the Kestrel design's KYouTube board,
// 900×600 (with --popup 760×520): a search field; three tabs — Results (a grid four across: the
// thumbnail with its length and a badge when playing or queued, the title, channel · views),
// Queue (now playing, then up next) and History (what was watched here, how far, ↵ resumes);
// and what plays, in a strip at the foot. Nothing searched yet: "continue watching" from the
// history (and before that, your YouTube home page). The player itself is mpv's window, small in the top-left corner of every workspace
// (the YouTubePip board): this window only finds and steers.
// Typing (anywhere) goes to the field, ↵ searches, ↓ the grid: arrows pick, ↵ plays (in History it
// resumes), a or ^↵ queues, Space pauses, n p next and back, d takes it out of the queue, o opens
// it on youtube.com, y hides or shows the player, ^⌫ clears the history, Tab or Alt+1–3 the tabs,
// Esc back to the field, then closes. Cards: nothing found, offline (^R again), yt-dlp or mpv
// missing (↵ installs them in a terminal), installing.
// The data comes from k4-youtube (panel lines R and L, panel.odin), again every 1.5 s while open:
//   S <ok|missing|installing|offline|error> <note> <yt-dlp version> <mpv version>
//   Q <query> <count> <seconds it took>    the last search
//   V <id> <title> <channel> <seconds> <views> [thumb]   its results (seconds 0: live)
//   N <id> <title> <channel> <play|pause> <position> <seconds> <shown|hidden> [thumb]   what plays
//   P <index> <id> <title> <channel> <seconds> <current 1|0> [thumb]   mpv's playlist
//   H <unix time> <id> <title> <channel> <seconds> [thumb] <position>   watched, newest first
//   F <ok|loading|signedout|error> <browser> <why>   nothing searched: your YouTube home page, then
//   W <id> <title> <channel> <seconds> <views> [thumb]   its videos (signed in with that browser)
// thumb: a picture file once fetched (until then a dashed outline). The home page scrolls without
// end: reaching its last row asks for more (home-more), grey tiles under it meanwhile. The runner's
// verbs: search QUERY, clear, home, home-more, play ID [resume], queue ID, jump INDEX, pause, next,
// prev, remove INDEX, browser ID, pip, forget, install.

YT_W, YT_H :: 900, 600
YT_PW, YT_PH :: 760, 520
YT_COLS :: 4

Yt_Video :: struct { id, title, channel, thumb: string, secs, views, pos, index: int, current, is_chan: bool, ts: i64 } // is_chan: a channel (id UC…, channel: its @handle, views: its subscribers)
Yt_Tab :: enum { Results, Queue, History }

YouTube :: struct {
	using pn: Panel,
	state, note, query, took, ytv, mpvv: string,
	searched: bool,      // a search was made (a Q line came)
	view, view_name: string, // what the results are: "search", or "channel" (that channel's videos, opened from the search)
	vids, queue, hist, feed: [dynamic]Yt_Video, // results, mpv's playlist, watched, the home page
	home, home_browser, home_why: string,        // the home page: ok, loading, signedout, error; whose session
	now: Yt_Video,       // what plays (id "": nothing)
	paused, hidden: bool,
	pos, dur: int,
	tab: Yt_Tab,
	cur: [Yt_Tab]int,    // the picked one in each tab
	top: int,            // the first row shown
	field: bool,         // the keys go to the search field
	more_at: int,        // the home page's length when more was last asked for (once a length)
}

youtube_setup :: proc(a: ^App, data: string) {
	y := new(YouTube)
	y.mode = {draw = yt_draw, key = yt_key, click = yt_click, scroll = yt_scroll, loaded = yt_loaded, dump = yt_dump}
	panel_init(a, &y.pn, "youtube", data)
	y.refresh_ms = 1500
	a.width, a.height = y.popup ? YT_PW : YT_W, y.popup ? YT_PH : YT_H
	y.field = !y.searched || len(y.vids) == 0
}

@(private = "file")
Y :: proc(a: ^App) -> ^YouTube { return (^YouTube)(a.pn) }

@(private = "file")
yt_free :: proc(list: ^[dynamic]Yt_Video) {
	for &v in list { delete(v.id); delete(v.title); delete(v.channel); delete(v.thumb) }
	clear(list)
}

@(private = "file")
yt_loaded :: proc(a: ^App, data: string) {
	y := Y(a)
	yt_free(&y.vids); yt_free(&y.queue); yt_free(&y.hist); yt_free(&y.feed)
	delete(y.home); y.home = ""
	delete(y.now.id); delete(y.now.title); delete(y.now.channel); delete(y.now.thumb)
	y.now = {}
	y.searched = false
	text := data
	num :: proc(s: string) -> int { n, _ := strconv.parse_int(s); return n }
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			delete(y.state); delete(y.note); delete(y.ytv); delete(y.mpvv)
			y.state, y.note, y.ytv, y.mpvv = strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3)), strings.clone(fget(f, 4))
		case "Q":
			delete(y.query); delete(y.took); delete(y.view); delete(y.view_name)
			y.query, y.took, y.searched = strings.clone(fget(f, 1)), strings.clone(fget(f, 3)), true
			y.view, y.view_name = strings.clone(fget(f, 4)), strings.clone(fget(f, 5))
		case "C": // the search named a channel: it, first among the results
			append(&y.vids, Yt_Video{id = strings.clone(fget(f, 1)), title = strings.clone(fget(f, 2)), channel = strings.clone(fget(f, 3)), views = num(fget(f, 4)), thumb = strings.clone(fget(f, 5)), is_chan = true})
		case "F":
			delete(y.home_browser); delete(y.home_why)
			y.home, y.home_browser, y.home_why = strings.clone(fget(f, 1)), strings.clone(fget(f, 2)), strings.clone(fget(f, 3))
		case "W":
			append(&y.feed, Yt_Video{id = strings.clone(fget(f, 1)), title = strings.clone(fget(f, 2)), channel = strings.clone(fget(f, 3)), secs = num(fget(f, 4)), views = num(fget(f, 5)), thumb = strings.clone(fget(f, 6))})
		case "V":
			append(&y.vids, Yt_Video{id = strings.clone(fget(f, 1)), title = strings.clone(fget(f, 2)), channel = strings.clone(fget(f, 3)), secs = num(fget(f, 4)), views = num(fget(f, 5)), thumb = strings.clone(fget(f, 6))})
		case "N":
			y.now = Yt_Video{id = strings.clone(fget(f, 1)), title = strings.clone(fget(f, 2)), channel = strings.clone(fget(f, 3)), thumb = strings.clone(fget(f, 8))}
			y.paused, y.pos, y.dur, y.hidden = fget(f, 4) == "pause", num(fget(f, 5)), num(fget(f, 6)), fget(f, 7) == "hidden"
		case "P":
			append(&y.queue, Yt_Video{index = num(fget(f, 1)), id = strings.clone(fget(f, 2)), title = strings.clone(fget(f, 3)), channel = strings.clone(fget(f, 4)), secs = num(fget(f, 5)), current = fget(f, 6) == "1", thumb = strings.clone(fget(f, 7))})
		case "H":
			v := Yt_Video{id = strings.clone(fget(f, 2)), title = strings.clone(fget(f, 3)), channel = strings.clone(fget(f, 4)), secs = num(fget(f, 5)), thumb = strings.clone(fget(f, 6)), pos = num(fget(f, 7))}
			v.ts, _ = strconv.parse_i64(fget(f, 1))
			append(&y.hist, v)
		}
	}
	for t in Yt_Tab do y.cur[t] = clamp(y.cur[t], 0, max(len(yt_items(y, t)) - 1, 0))
}

// What a tab lists to pick from: the results (nothing searched: the first 4 watched, to go on
// with), what comes after the playing one, or the history.
@(private = "file")
yt_items :: proc(y: ^YouTube, t: Yt_Tab) -> []Yt_Video {
	switch t {
	case .Results:
		if !y.searched do return len(y.feed) > 0 ? y.feed[:] : y.hist[:min(len(y.hist), YT_COLS)] // the home page, else continue watching
		if y.state == "offline" || y.state == "error" do return nil
		return y.vids[:]
	case .Queue:
		for v, i in y.queue do if v.current do return y.queue[i + 1:]
		return y.queue[:]
	case .History: return y.hist[:]
	}
	return nil
}

@(private = "file")
yt_picked :: proc(y: ^YouTube) -> (Yt_Video, bool) {
	l := yt_items(y, y.tab)
	if len(l) == 0 do return {}, false
	return l[clamp(y.cur[y.tab], 0, len(l) - 1)], true
}

// The home page shown and its last row reached: ask for more (once for this length).
@(private = "file")
yt_more :: proc(a: ^App) {
	y := Y(a)
	n := len(y.feed)
	if y.tab != .Results || y.searched || n == 0 || y.field || panel_busy(&y.pn) || y.more_at == n do return
	if y.cur[.Results] < (n - 1) / YT_COLS * YT_COLS do return // (not on the last row)
	y.more_at = n
	panel_run(a, "home-more")
}

@(private = "file")
yt_more_loading :: proc(y: ^YouTube) -> bool { return panel_busy(&y.pn) && y.run.verb == "home-more" }

@(private = "file")
yt_searching :: proc(y: ^YouTube) -> bool { return panel_busy(&y.pn) && y.run.verb == "search" }
@(private = "file")
yt_setup :: proc(y: ^YouTube) -> bool { return y.state == "missing" || y.state == "installing" }

// How far into a video the history says it got (0–100; 100 watched, 0 none).
@(private = "file")
yt_watched :: proc(y: ^YouTube, id: string) -> int {
	for h in y.hist do if h.id == id {
		if h.secs <= 0 || h.pos <= 10 do return 0
		return h.pos * 100 >= h.secs * 95 ? 100 : clamp(h.pos * 100 / h.secs, 1, 99)
	}
	return 0
}

@(private = "file")
yt_search :: proc(a: ^App) {
	y := Y(a)
	q := strings.trim_space(panel_text(&y.pn))
	if q == "" { panel_say(&y.pn, "Type something first"); return }
	y.tab, y.cur[.Results], y.top, y.field = .Results, 0, 0, false
	panel_run(a, "search", q)
}

// ↵ on the picked one: results play, the queue jumps to it, the history resumes.
@(private = "file")
yt_play :: proc(a: ^App) {
	y := Y(a)
	v, ok := yt_picked(y)
	if !ok do return
	switch {
	case v.is_chan: panel_run(a, "channel", v.id) // its videos, in place of the search
	case y.tab == .Queue: panel_run(a, "jump", fmt.tprint(v.index))
	case y.tab == .History || (!y.searched && len(y.feed) == 0): panel_run(a, "play", v.id, "resume")
	case: panel_run(a, "play", v.id)
	}
}

// ---------- keys ----------

@(private = "file")
yt_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	y := Y(a)
	if ctrl && (ch == 'c' || ch == 'g') { panel_close(a); return true }
	if yt_setup(y) {
		switch {
		case k == .Enter && y.state == "missing": panel_run(a, "install")
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	// everywhere
	switch {
	case alt && ch >= '1' && ch <= '3': yt_tab(y, Yt_Tab(ch - '1')); return true
	case k == .Tab: yt_tab(y, Yt_Tab((int(y.tab) + 1) % 3)); return true
	case k == .Back_Tab: yt_tab(y, Yt_Tab((int(y.tab) + 2) % 3)); return true
	case ctrl && ch == 'r':
		if y.searched do panel_run(a, "search", y.query)
		else do panel_run(a, "home")
		return true
	case ctrl && k == .Enter: if v, ok := yt_picked(y); ok && !y.field do panel_run(a, "queue", v.id); return true
	}
	if y.field {
		switch {
		case k == .Enter: yt_search(a)
		case k == .Down: if len(yt_items(y, y.tab)) > 0 do y.field = false
		case k == .Backspace: panel_bs(&y.pn)
		case k == .Escape:
			switch {
			case len(y.input) > 0: panel_clear(&y.pn)
			case y.view == "channel": panel_run(a, "back") // back to the search
			case y.searched: panel_run(a, "clear") // back to the home page
			case: panel_close(a)
			}
		case ctrl && ch == 'v': panel_type(&y.pn, strings.trim_space(yt_clipboard()))
		case text != "" && k == .None && !ctrl && !alt: panel_type(&y.pn, text)
		case: return false
		}
		return true
	}
	defer yt_more(a)
	n := len(yt_items(y, y.tab))
	grid := y.tab == .Results
	step := grid ? YT_COLS : 1
	c := &y.cur[y.tab]
	switch {
	case k == .Right && grid: c^ = min(c^ + 1, max(n - 1, 0))
	case k == .Left && grid: c^ = max(c^ - 1, 0)
	case k == .Down: c^ = min(c^ + step, max(n - 1, 0))
	case k == .Up: if c^ < step do y.field = true; else do c^ -= step
	case k == .Home: c^ = 0
	case k == .End: c^ = max(n - 1, 0)
	case k == .Enter: yt_play(a)
	case ctrl && k == .Backspace: if y.tab == .History do panel_run(a, "forget")
	case text == "a":
		if v, ok := yt_picked(y); ok && v.is_chan do panel_say(&y.pn, "A channel: ↵ opens its videos, a queues one of them")
		else if ok do panel_run(a, "queue", v.id)
	case text == " ": panel_run(a, "pause")
	case text == "n": panel_run(a, "next")
	case text == "p": panel_run(a, "prev")
	case text == "d":
		if v, ok := yt_picked(y); ok && y.tab == .Queue do panel_run(a, "remove", fmt.tprint(v.index))
		else do panel_say(&y.pn, "d removes from the Queue tab")
	case text == "o": if v, ok := yt_picked(y); ok do panel_run(a, "browser", v.id)
	case text == "y": panel_run(a, "pip")
	case k == .Escape: y.field = true
	case text != "" && k == .None && !ctrl && !alt && text != " ": y.field = true; panel_type(&y.pn, text) // (typing anywhere searches)
	case: return false
	}
	return true
}

@(private = "file")
yt_tab :: proc(y: ^YouTube, t: Yt_Tab) {
	y.tab, y.top = t, 0
	if len(yt_items(y, t)) > 0 do y.field = false
}

// The clipboard (a pasted link searches as well: yt-dlp takes it). K4_YOUTUBE_CLIPBOARD in tests.
@(private = "file")
yt_clipboard :: proc() -> string {
	if t := os.get_env("K4_YOUTUBE_CLIPBOARD", context.temp_allocator); t != "" do return t
	_, out, _, err := os.process_exec({command = {"wl-paste", "--no-newline", "--type", "text/plain"}}, context.temp_allocator)
	return err == nil ? string(out) : ""
}

@(private = "file")
yt_scroll :: proc(a: ^App, n: int) -> bool { // the wheel moves the pick a row (the grid follows it)
	y := Y(a)
	l := len(yt_items(y, y.tab))
	if l == 0 do return true
	step := y.tab == .Results ? YT_COLS : 1
	y.field = false
	y.cur[y.tab] = clamp(y.cur[y.tab] + n * step, 0, l - 1) // (n > 0: down)
	yt_more(a)
	return true
}

// Hits: .Item a video (a: its index in the tab), .Chip a tab (10 + it) or a button (1 play/pause,
// 2 the player shown/hidden, 20 and 21 a card's first and second).
@(private = "file")
yt_click :: proc(a: ^App, x, yy, button: int) -> bool {
	y := Y(a)
	h, ok := hit_at(a, x, yy)
	if !ok do return false
	#partial switch h.kind {
	case .Item:
		l := yt_items(y, y.tab)
		if h.a >= len(l) do return false
		was := y.cur[y.tab] == h.a && !y.field
		y.cur[y.tab], y.field = h.a, false
		if button == 3 do panel_run(a, "queue", l[h.a].id) // right click queues
		else if was do yt_play(a)                          // a second click plays
	case .Chip:
		switch h.a {
		case 1: panel_run(a, "pause")
		case 2: panel_run(a, "pip")
		case 20: yt_card_act(a, 0)
		case 21: yt_card_act(a, 1)
		case 10, 11, 12: yt_tab(y, Yt_Tab(h.a - 10))
		}
	case: return false
	}
	return true
}

// A card's buttons: nothing found (Edit the search, History), offline (Retry, Queue), missing
// (Install, Not now).
@(private = "file")
yt_card_act :: proc(a: ^App, i: int) {
	y := Y(a)
	switch y.state {
	case "missing": if i == 0 do panel_run(a, "install"); else do panel_close(a)
	case "offline", "error": if i == 0 do panel_run(a, "search", y.query); else do yt_tab(y, .Queue)
	case: if i == 0 do y.field = true; else do yt_tab(y, .History)
	}
}

// ---------- drawing ----------

@(private = "file")
yt_secs :: proc(s: int) -> string {
	if s <= 0 do return "LIVE"
	if s >= 3600 do return fmt.tprintf("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
	return fmt.tprintf("%d:%02d", s / 60, s % 60)
}

// A position: 0:00, 1:23, 1:02:03.
@(private = "file")
yt_clock :: proc(s: int) -> string { return s > 0 ? yt_secs(s) : "0:00" }

@(private = "file")
yt_views :: proc(n: int) -> string {
	switch {
	case n <= 0: return ""
	case n >= 1_000_000_000: return fmt.tprintf("%.1fB views", f64(n) / 1e9)
	case n >= 1_000_000: return fmt.tprintf("%.1fM views", f64(n) / 1e6)
	case n >= 1_000: return fmt.tprintf("%dK views", n / 1000)
	}
	return fmt.tprintf("%d views", n)
}

// When it was watched: today 08:10, yesterday, Mon, 12 Oct.
@(private = "file")
yt_when :: proc(ts: i64) -> string {
	now := time.to_unix_seconds(time.now())
	if v, ok := strconv.parse_i64(os.get_env("K4_YOUTUBE_NOW", context.temp_allocator)); ok do now = v
	t := time.unix(ts, 0)
	h, mi, _ := time.clock(t)
	days := now / 86400 - ts / 86400
	switch {
	case days == 0: return fmt.tprintf("today %02d:%02d", h, mi)
	case days == 1: return "yesterday"
	}
	wd := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	if days < 7 do return wd[int(time.weekday(t))]
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	_, mo, dd := time.date(t)
	return fmt.tprintf("%d %s", dd, months[int(mo) - 1])
}

@(private = "file")
yt_nth :: proc(n: int) -> string {
	switch n {
	case 1: return "1st"
	case 2: return "2nd"
	case 3: return "3rd"
	}
	return fmt.tprintf("%dth", n)
}

@(private = "file")
yt_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	y := Y(a)
	H := panel_ground(a, cv)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	w, h := cv.w, cv.h
	px := (y.popup ? 12 : 14) * S

	// the head: the crumb, the title, the state at the right
	hh := (y.popup ? 40 : 48) * S
	cf := y.popup ? y.f11b : y.f12b
	crumb := y.tab == .Results ? (y.view == "channel" ? "YOUTUBE › CHANNEL" : "YOUTUBE") : fmt.tprintf("YOUTUBE › %s", y.tab == .Queue ? "QUEUE" : "HISTORY")
	cw, ch := tw(cf, crumb) + (y.popup ? 12 : 16) * S, (y.popup ? 20 : 24) * S
	fill_rect(cv, px, (hh - ch) / 2, cw, ch, argb(H.acc, 0xff))
	text_in(cv, cf, crumb, px + (cw - tw(cf, crumb)) / 2, (hh - ch) / 2, ch, argb(H.bg, 0xff))
	searching := yt_searching(y) && y.tab == .Results
	st, stc := "yt-dlp · mpv", H.dim
	switch {
	case y.state == "missing": st, stc = "not installed", th.red
	case y.state == "installing": st, stc = "installing", H.acc
	case y.state == "offline": st, stc = "offline", th.yellow
	case searching: st, stc = "searching", H.acc
	case y.now.id != "": st, stc = y.paused ? "paused" : "playing", y.paused ? H.dim : th.green
	}
	sw := tw(y.f10, st)
	text_in(cv, y.f10, st, w - px - sw, 0, hh, argb(stc, 0xff))
	fill_rect(cv, w - px - sw - 12 * S, (hh - 6 * S) / 2, 6 * S, 6 * S, argb(stc, 0xff))
	title := "Search"
	switch {
	case yt_setup(y): title = "Set up"
	case y.tab == .Queue: n := len(yt_items(y, .Queue)); title = n > 0 ? fmt.tprintf("%d up next", n) : "Queue empty"
	case y.tab == .History: title = fmt.tprintf("%d watched", len(y.hist))
	case searching: title = fmt.tprintf("“%s”", panel_text(&y.pn) != "" ? strings.trim_space(panel_text(&y.pn)) : y.query)
	case y.state == "offline" || y.state == "error": title = fmt.tprintf("“%s” · not sent", y.query)
	case y.view == "channel": title = fmt.tprintf("%s · %d newest videos", y.view_name, len(y.vids))
	case y.searched:
		n := 0
		for v in y.vids do if !v.is_chan do n += 1
		title = len(y.vids) > 0 ? fmt.tprintf("%d results · “%s”", n, y.query) : "0 results"
	}
	tx := px + cw + 10 * S
	text_in(cv, y.f13b, ellipsize(y.f13b, title, w - px - sw - 30 * S - tx), tx, 0, hh, argb(H.fg, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))

	// the foot: keys at the left, the last message at the right
	fh := 30 * S
	fy := h - fh
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	hints := yt_hints(y)
	toast_w := y.toast != "" ? min(tw(y.f10, y.toast), w / 2) : 0
	kx := px
	for k in hints {
		kw := tw(y.f10, k[0]) + 8 * S
		if kx + kw + 5 * S + tw(y.f10, k[1]) > w - px - toast_w - 12 * S do break
		fill_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, argb(H.panel, 0xff))
		rounded_rect(cv, kx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, y.f10, k[0], kx + 4 * S, fy, fh, argb(soft, 0xff))
		kx += kw + 5 * S
		text_in(cv, y.f10, k[1], kx, fy, fh, argb(H.dim, 0xff))
		kx += tw(y.f10, k[1]) + 12 * S
	}
	if y.toast != "" {
		t := ellipsize(y.f10, y.toast, toast_w)
		warn := strings.contains(y.toast, "hidden") || strings.contains(y.toast, "failed") || strings.contains(y.toast, "empty")
		text_in(cv, y.f10, t, w - px - tw(y.f10, t), fy, fh, argb(y.tone != 0 ? y.tone : (warn ? th.yellow : H.acc), 0xff))
	}

	// what plays: the strip over the foot
	sh := 56 * S
	sy := fy - sh
	yt_strip(a, cv, S, H, px, sy, w - 2 * px, sh)

	// the search field
	yy := hh + S + (y.popup ? 8 : 10) * S
	fw, fhh := w - 2 * px, (y.popup ? 36 : 40) * S
	setup := yt_setup(y)
	bd := searching ? argb(H.acc, 0x99) : (y.field ? argb(H.acc, 0x80) : argb(H.line, 0xff))
	bar := setup ? H.faint : H.acc
	fill_rect(cv, px, yy, fw, fhh, argb(H.panel, 0xff))
	rounded_rect(cv, px, yy, fw, fhh, 0, 0, f32(S), bd)
	fill_rect(cv, px, yy, 3 * S, fhh, argb(bar, 0xff))
	text_in(cv, y.f13b, "›", px + 12 * S, yy, fhh, argb(bar, setup ? 0x80 : 0xff))
	q := panel_text(&y.pn)
	qx := px + 12 * S + tw(y.f13b, "›") + 10 * S
	hint := searching ? "searching · 2–5 s" : (setup ? "needs yt-dlp" : (y.field && q != "" ? "↵ search" : (q == "" ? "type anywhere" : "")))
	hw := tw(y.f10, hint)
	text_in(cv, y.f10, hint, px + fw - 12 * S - hw, yy, fhh, argb(searching ? H.acc : H.dim, 0xff))
	if q == "" do text_in(cv, y.f12, "Search YouTube…", qx, yy, fhh, argb(H.faint, setup ? 0x80 : 0xff))
	shown := q
	for tw(y.f12, shown) > fw - (qx - px) - hw - 24 * S && len(shown) > 0 do shown = shown[1:]
	text_in(cv, y.f12, shown, qx, yy, fhh, argb(H.fg, 0xff))
	if y.field && !setup do fill_rect(cv, qx + (q != "" ? tw(y.f12, shown) + S : 0), yy + (fhh - 16 * S) / 2, 2 * S, 16 * S, argb(H.acc, 0xff))
	if searching do fill_rect(cv, px, yy + fhh - 2 * S, fw / 4, 2 * S, argb(H.acc, 0xff)) // (the board's sweep, still)
	yy += fhh + (y.popup ? 8 : 10) * S

	// the tabs
	tabh := 30 * S
	tabs := [3]string{"Results", "Queue", "History"}
	counts := [3]string{y.searched && len(y.vids) > 0 ? fmt.tprint(len(y.vids)) : "", len(yt_items(y, .Queue)) > 0 ? fmt.tprint(len(yt_items(y, .Queue))) : "", ""}
	tx = px
	for t, i in tabs {
		on := int(y.tab) == i
		lw := tw(y.f11b, t) + 24 * S
		cw2 := counts[i] != "" ? tw(y.f10, counts[i]) + 8 * S + 6 * S : 0
		bw := lw + cw2
		if on {
			fill_rect(cv, tx, yy, bw, tabh, argb(H.acc, 0x0f))
			fill_rect(cv, tx, yy + tabh - 2 * S, bw, 2 * S, argb(H.acc, 0xff))
		}
		text_in(cv, y.f11b, t, tx + 12 * S, yy, tabh, argb(on ? H.fg : H.dim, 0xff))
		if counts[i] != "" {
			cx := tx + 12 * S + tw(y.f11b, t) + 6 * S
			cww := tw(y.f10, counts[i]) + 8 * S
			rounded_rect(cv, cx, yy + (tabh - 15 * S) / 2, cww, 15 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, on ? 0x99 : 0xff))
			text_in(cv, y.f10, counts[i], cx + 4 * S, yy + (tabh - 15 * S) / 2, 15 * S, argb(on ? H.acc : H.dim, 0xff))
		}
		hit_add(a, tx, yy, bw, tabh, .Chip, 10 + i, 0)
		tx += bw + 2 * S
	}
	home_feed := y.tab == .Results && !y.searched && len(y.feed) > 0 && !yt_setup(y)
	if !y.popup || home_feed { // (the home page says whose it is here, where the grid does not lose a row to it)
		note := home_feed ? fmt.tprintf("YOUR YOUTUBE HOME · %s", yt_browser(y)) : "Tab · Alt+1–3"
		text_in(cv, y.f10, note, w - px - tw(y.f10, note), yy, tabh, argb(H.dim, 0xff))
	}
	yy += tabh
	fill_rect(cv, 0, yy, w, S, argb(H.line, 0xff))
	yy += S

	// the body
	body_top, body_bot := yy, sy
	switch {
	case setup: yt_setup_card(a, cv, S, H, px, body_top, w - 2 * px, body_bot - body_top)
	case y.tab == .Results && searching: yt_grid(a, cv, S, H, nil, px, body_top + 12 * S, w - 2 * px, body_bot - body_top - 12 * S, true)
	case y.tab == .Results && (y.state == "offline" || y.state == "error"):
		offline := y.state == "offline"
		yt_card(a, cv, S, H, px, body_top, w - 2 * px, body_bot - body_top, 560, th.yellow, true, offline ? "Can’t reach YouTube" : "The search failed",
			{y.note != "" ? fmt.tprintf("yt-dlp: %s", y.note) : "yt-dlp could not reach YouTube", "Queue and History still work, and the video that is loaded keeps playing."},
			{{"Retry", "^R"}, {"Queue", "Alt+2"}}, true)
	case y.tab == .Results && y.searched && len(y.vids) == 0:
		yt_card(a, cv, S, H, px, body_top, w - 2 * px, body_bot - body_top, 520, H.fg, false, fmt.tprintf("Nothing for “%s”", y.query),
			{"yt-dlp searched and found no videos. Try fewer or different words."}, {{"Edit the search", "Esc"}, {"History", "Alt+3"}}, false)
	case home_feed: yt_grid(a, cv, S, H, y.feed[:], px, body_top + 12 * S, w - 2 * px, body_bot - body_top - 12 * S, false, yt_more_loading(y)) // your home page: as much room as results
	case y.tab == .Results && !y.searched: // nothing searched: a hint, then continue watching
		hy := body_top + 12 * S
		hb := 34 * S
		panel_dashed(cv, px, hy, w - 2 * px, hb, S, argb(H.faint, 0xff))
		text_in(cv, y.f11, "Type, then ↵ to search.", px + 12 * S, hy, hb, argb(soft, 0xff))
		text_in(cv, y.f11, "yt-dlp, no account · a search takes 2–5 s", px + 12 * S + tw(y.f11, "Type, then ↵ to search.") + 10 * S, hy, hb, argb(H.dim, 0xff))
		hy += hb + 12 * S
		bname := yt_browser(y)
		switch {
		case y.home == "loading" || y.home == "":
			spaced(cv, y.f10b, fmt.tprintf("YOUR YOUTUBE HOME · %s · loading", bname), px, hy, 14 * S, H.dim, S)
			hy += 14 * S + 8 * S
			yt_grid(a, cv, S, H, nil, px, hy, w - 2 * px, body_bot - hy, true)
		case:
			why := y.home == "signedout" ? fmt.tprintf("Sign in to YouTube in %s to see your home page here · ^R tries again", bname) : fmt.tprintf("Your home page did not load%s · ^R tries again", y.home_why != "" ? fmt.tprintf(": %s", y.home_why) : "")
			text_in(cv, y.f11, ellipsize(y.f11, why, w - 2 * px), px, hy, 16 * S, argb(th.yellow, 0xff))
			hy += 16 * S + 12 * S
			if len(y.hist) > 0 {
				spaced(cv, y.f10b, "CONTINUE WATCHING · from History", px, hy, 14 * S, H.dim, S)
				hy += 14 * S + 8 * S
				yt_grid(a, cv, S, H, yt_items(y, .Results), px, hy, w - 2 * px, body_bot - hy, false)
			}
		}
	case y.tab == .Results: yt_grid(a, cv, S, H, y.vids[:], px, body_top + 12 * S, w - 2 * px, body_bot - body_top - 12 * S, false)
	case: yt_rows(a, cv, S, H, (y.popup ? 8 : 10) * S, body_top + 4 * S, w - 2 * (y.popup ? 8 : 10) * S, body_bot - body_top - 4 * S)
	}
}

// The browser whose YouTube sign-in the home page comes with: Chromium.
@(private = "file")
yt_browser :: proc(y: ^YouTube) -> string {
	b := y.home_browser
	if b == "" do return "the browser"
	return strings.concatenate({strings.to_upper(b[:1], context.temp_allocator), b[1:]}, context.temp_allocator)
}

@(private = "file")
yt_hints :: proc(y: ^YouTube) -> [][2]string {
	keys :: proc(k: ..[2]string) -> [][2]string { return slice.clone(k, context.temp_allocator) }
	h: [][2]string
	switch {
	case y.state == "missing": h = keys({"↵", "Install"}, {"Esc", "Not now"})
	case y.state == "installing": h = keys({"…", "Installing"})
	case y.field: h = keys({"↵", "Search"}, {"↓", "Results"}, {"Tab", "Queue / History"}, {"Esc", len(y.input) > 0 ? "Clear" : "Close"})
	case y.tab == .History: h = keys({"↑↓", "Move"}, {"↵", "Resume"}, {"a", "Queue"}, {"Space", "Pause"}, {"y", "Player"}, {"o", "Browser"})
	case y.tab == .Queue: h = keys({"↑↓", "Move"}, {"↵", "Play now"}, {"d", "Remove"}, {"Space", "Pause"}, {"n", "Next"}, {"y", "Player"})
	case: h = keys({"←→↑↓", "Move"}, {"↵", "Play"}, {"a", "Queue"}, {"Space", "Pause"}, {"n p", "Next/prev"}, {"y", "Player"}, {"o", "Browser"})
	}
	if y.popup && len(h) > 5 do h = h[:5]
	return h
}

// A thumbnail, or a dashed outline until it is fetched; how far it was watched in red along its foot.
@(private = "file")
yt_thumb :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, path: string, x, y, w, h: int, watched := 0) {
	drawn := false
	if path != "" {
		if img := image_cover(a, path, w, h); img.ok { blit_image(cv, img.px, img.w, img.h, x, y); drawn = true }
	}
	if !drawn {
		fill_rect(cv, x, y, w, h, argb(H.panel, 0xff))
		panel_dashed(cv, x, y, w, h, S, argb(H.faint, 0xff))
	}
	if watched > 0 {
		fill_rect(cv, x, y + h - 3 * S, w, 3 * S, argb(0x000000, 0x99))
		fill_rect(cv, x, y + h - 3 * S, w * watched / 100, 3 * S, argb(a.theme.red, 0xff))
	}
}

// The results (or what to continue), four across: the thumbnail with its length and a badge
// (playing, paused, its place in the queue), two lines of title, channel · views. skeleton:
// grey tiles while a search runs.
@(private = "file")
yt_grid :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, l: []Yt_Video, x, y, w, h: int, skeleton: bool, more := false) {
	yt := Y(a)
	gx, gy := (yt.popup ? 16 : 20) * S, (yt.popup ? 14 : 16) * S
	tw_ := min((yt.popup ? 172 : 204) * S, (w - (YT_COLS - 1) * gx) / YT_COLS)
	th_ := tw_ * 9 / 16
	tf := yt.popup ? yt.f11b : yt.f12b
	tlh := (yt.popup ? 15 : 16) * S
	rh := th_ + 6 * S + 2 * tlh + 6 * S + 13 * S + gy
	rows := max((h + gy) / rh, 1)
	if skeleton {
		for i in 0 ..< min(rows, 2) * YT_COLS {
			tx, ty := x + (i % YT_COLS) * (tw_ + gx), y + (i / YT_COLS) * rh
			fill_rect(cv, tx, ty, tw_, th_, argb(H.line, 0xff))
			fill_rect(cv, tx, ty + th_ + 6 * S, tw_ * 92 / 100, 11 * S, argb(H.line, 0xff))
			fill_rect(cv, tx, ty + th_ + 6 * S + 15 * S, tw_ * 60 / 100, 11 * S, argb(H.line, 0xff))
			fill_rect(cv, tx, ty + th_ + 6 * S + 2 * tlh + 6 * S, tw_ * 45 / 100, 9 * S, argb(H.panel, 0xff))
		}
		return
	}
	cur := yt.cur[.Results]
	crow := cur / YT_COLS
	if crow < yt.top do yt.top = crow
	if crow >= yt.top + rows do yt.top = crow - rows + 1
	total := (len(l) + YT_COLS - 1) / YT_COLS + (more ? 1 : 0) // (more: a row of grey tiles under the last, loading)
	if more && crow == (len(l) - 1) / YT_COLS do yt.top = max(yt.top, total - rows)
	yt.top = clamp(yt.top, 0, max(total - rows, 0))
	if more && len(l) % YT_COLS == 0 && (len(l) / YT_COLS) - yt.top < rows {
		for i in 0 ..< YT_COLS {
			tx, ty := x + i * (tw_ + gx), y + (len(l) / YT_COLS - yt.top) * rh
			fill_rect(cv, tx, ty, tw_, th_, argb(H.line, 0xff))
			fill_rect(cv, tx, ty + th_ + 6 * S, tw_ * 92 / 100, 11 * S, argb(H.line, 0xff))
			fill_rect(cv, tx, ty + th_ + 6 * S + 15 * S, tw_ * 60 / 100, 11 * S, argb(H.line, 0xff))
		}
	}
	for i in yt.top * YT_COLS ..< min((yt.top + rows) * YT_COLS, len(l)) {
		v := l[i]
		tx, ty := x + (i % YT_COLS) * (tw_ + gx), y + (i / YT_COLS - yt.top) * rh
		on := i == cur && !yt.field
		is_now := v.id == yt.now.id
		hit_add(a, tx, ty, tw_, rh - gy, .Item, i, 0)
		yt_thumb(a, cv, S, H, v.thumb, tx, ty, tw_, th_, yt_watched(yt, v.id) if v.ts > 0 else 0)
		// the outline: picked (2 px, the accent, a glow), playing (the accent, faint), else the line
		if on {
			rounded_rect(cv, tx - 3 * S, ty - 3 * S, tw_ + 6 * S, th_ + 6 * S, 0, 0, f32(S), argb(H.acc, 0x30))
			rounded_rect(cv, tx, ty, tw_, th_, 0, 0, 2 * f32(S), argb(H.acc, 0xff))
			mark_sel(a, tx, ty, tw_, th_)
		} else do rounded_rect(cv, tx, ty, tw_, th_, 0, 0, f32(S), is_now ? argb(H.acc, 0x99) : argb(H.line, 0xff))
		if v.is_chan { // a channel: its picture round in the middle, CHANNEL, @handle · subscribers
			fill_rect(cv, tx, ty, tw_, th_, argb(H.panel, 0xff))
			as := th_ - 18 * S
			ax, ay := tx + (tw_ - as) / 2, ty + 9 * S
			if v.thumb != "" {
				if img := image_cover(a, v.thumb, as, as); img.ok {
					blit_image(cv, img.px, img.w, img.h, ax, ay)
					// round: the corners in the tile's colour
					r := f32(as) / 2
					for yy in 0 ..< as do for xx in 0 ..< as {
						dx, dy := f32(xx) - r + 0.5, f32(yy) - r + 0.5
						if dx * dx + dy * dy > r * r do fill_rect(cv, ax + xx, ay + yy, 1, 1, argb(H.panel, 0xff))
					}
				}
			}
			rounded_rect(cv, tx, ty, tw_, th_, 0, 0, on ? 2 * f32(S) : f32(S), on ? argb(H.acc, 0xff) : argb(H.acc, 0x66))
			bw := tw(yt.f10b, "CHANNEL") + 10 * S
			fill_rect(cv, tx + 5 * S, ty + 5 * S, bw, 15 * S, argb(H.acc, 0xff))
			text_in(cv, yt.f10b, "CHANNEL", tx + 10 * S, ty + 5 * S, 15 * S, argb(H.bg, 0xff))
			if on {
				fill_rect(cv, tx, ty + th_ - 22 * S, tw_, 22 * S, argb(0x04070c, 0xcc))
				text_in(cv, yt.f9, "↵ its videos  o browser", tx + 6 * S, ty + th_ - 22 * S, 22 * S, argb(H.fg, 0xff))
			}
			text_in(cv, tf, ellipsize(tf, v.title, tw_), tx, ty + th_ + 6 * S, tlh, argb(on ? H.acc : H.fg, 0xff))
			subs := v.views >= 1_000_000 ? fmt.tprintf("%.1fM subscribers", f64(v.views) / 1e6) : (v.views >= 1000 ? fmt.tprintf("%dK subscribers", v.views / 1000) : "")
			sub := v.channel
			if subs != "" do sub = sub != "" ? fmt.tprintf("%s · %s", sub, subs) : subs
			text_in(cv, yt.f10, ellipsize(yt.f10, sub, tw_), tx, ty + th_ + 6 * S + 2 * tlh + 6 * S, 13 * S, argb(H.dim, 0xff))
			continue
		}
		d := yt_secs(v.secs)
		dw := tw(yt.f10b, d) + 10 * S
		fill_rect(cv, tx + tw_ - 5 * S - dw, ty + th_ - 5 * S - 15 * S, dw, 15 * S, argb(v.secs <= 0 ? a.theme.red : 0x04070c, 0xdd))
		text_in(cv, yt.f10b, d, tx + tw_ - 5 * S - dw + 5 * S, ty + th_ - 20 * S, 15 * S, argb(H.fg, 0xff))
		badge := ""
		if is_now do badge = yt.paused ? "‖ PAUSED" : "▶ PLAYING"
		else do for q, qi in yt_items(yt, .Queue) do if q.id == v.id { badge = fmt.tprintf("QUEUE %d", qi + 1); break }
		if badge != "" {
			bw := tw(yt.f10b, badge) + 10 * S
			fill_rect(cv, tx + 5 * S, ty + 5 * S, bw, 15 * S, is_now ? argb(H.acc, 0xff) : argb(0x04070c, 0xdd))
			rounded_rect(cv, tx + 5 * S, ty + 5 * S, bw, 15 * S, 0, 0, f32(S), is_now ? argb(H.acc, 0xff) : argb(H.acc, 0x99))
			text_in(cv, yt.f10b, badge, tx + 10 * S, ty + 5 * S, 15 * S, argb(is_now ? H.bg : H.acc, 0xff))
		}
		if on { // what the keys do, over the foot of the picked one
			fill_rect(cv, tx, ty + th_ - 22 * S, tw_, 22 * S, argb(0x04070c, 0xcc))
			text_in(cv, yt.f9, "↵ play  a queue  o browser", tx + 6 * S, ty + th_ - 22 * S, 22 * S, argb(H.fg, 0xff))
		}
		ly := ty + th_ + 6 * S
		lines := wrap_text(tf, v.title, tw_)
		for k in 0 ..< min(len(lines), 2) {
			s := lines[k]
			if k == 1 && len(lines) > 2 do s = ellipsize(tf, strings.concatenate({s, " …"}, context.temp_allocator), tw_)
			text_in(cv, tf, s, tx, ly + k * tlh, tlh, argb(on ? H.acc : H.fg, 0xff))
		}
		ly += 2 * tlh + 6 * S
		sub := v.channel
		if v.ts > 0 do sub = fmt.tprintf("%s · %s", sub, yt_when(v.ts))
		else if vs := yt_views(v.views); vs != "" do sub = fmt.tprintf("%s · %s", sub, vs)
		text_in(cv, yt.f10, ellipsize(yt.f10, sub, tw_), tx, ly, 13 * S, argb(H.dim, 0xff))
	}
}

// The queue (now playing, up next) or the history: rows of 66 px under small headings.
@(private = "file")
yt_rows :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	yt := Y(a)
	soft := mix(H.fg, H.bg, 0.2)
	Line :: struct { head: string, v: Yt_Video, i: int, now: bool } // i: its index among the picks (-1 none)
	lines := make([dynamic]Line, 0, 32, context.temp_allocator)
	items := yt_items(yt, yt.tab)
	if yt.tab == .Queue {
		if yt.now.id != "" {
			append(&lines, Line{head = "NOW PLAYING", i = -1})
			append(&lines, Line{v = yt.now, i = -1, now = true})
		}
		total := 0
		for v in items do total += v.secs
		append(&lines, Line{head = len(items) > 0 ? fmt.tprintf("UP NEXT · %d · %d min", len(items), total / 60) : "UP NEXT · empty, a on a result adds one", i = -1})
		for v, i in items do append(&lines, Line{v = v, i = i})
		append(&lines, Line{head = "When the queue ends, the corner player closes.", i = -1})
	} else {
		append(&lines, Line{head = "WATCHED ON THIS MACHINE · kept 90 days · ^⌫ clears", i = -1})
		for v, i in items do append(&lines, Line{v = v, i = i})
	}
	lh :: proc(l: Line, S: int) -> int { return l.head != "" ? 26 * S : 68 * S }
	// keep the picked one in view
	cur := yt.cur[yt.tab]
	sel_line := 0
	for l, k in lines do if l.head == "" && l.i == cur do sel_line = k
	first := 0
	for {
		used := 0
		for k in first ..= sel_line do used += lh(lines[k], S)
		if used <= h || first >= sel_line do break
		first += 1
	}
	yy := y
	for k in first ..< len(lines) {
		l := lines[k]
		hgt := lh(l, S)
		if yy + hgt > y + h do break
		if l.head != "" {
			spaced(cv, yt.f10b, l.head, x + 4 * S, yy + 8 * S, 14 * S, H.dim, S)
			yy += hgt
			continue
		}
		v := l.v
		on := l.i >= 0 && l.i == cur && !yt.field
		rh := 66 * S
		switch {
		case on:
			fill_rect(cv, x, yy, w, rh, argb(H.acc, 0x14))
			rounded_rect(cv, x, yy, w, rh, 0, 0, f32(S), argb(H.acc, 0x59))
			fill_rect(cv, x, yy, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, x, yy, w, rh)
		case l.now:
			fill_rect(cv, x, yy, w, rh, argb(H.acc, 0x0d))
			fill_rect(cv, x, yy, 3 * S, rh, argb(H.acc, 0x80))
		}
		if l.i >= 0 do hit_add(a, x, yy, w, rh, .Item, l.i, 0)
		n := l.now ? (yt.paused ? "‖" : "▶") : (yt.tab == .Queue ? fmt.tprint(l.i + 1) : "")
		text_in(cv, yt.f11b, n, x + 6 * S + 22 * S - tw(yt.f11b, n), yy, rh, argb(l.now ? H.acc : H.dim, 0xff))
		ix, iy := x + 6 * S + 22 * S + 12 * S, yy + (rh - 54 * S) / 2
		watched := yt.tab == .History ? yt_watched(yt, v.id) : 0
		if yt.tab == .History && watched == 0 && v.pos > 0 do watched = 100
		yt_thumb(a, cv, S, H, v.thumb, ix, iy, 96 * S, 54 * S, watched)
		rounded_rect(cv, ix, iy, 96 * S, 54 * S, 0, 0, f32(S), argb(l.now ? H.acc : H.line, 0xff))
		if l.now {
			fill_rect(cv, ix, iy, 96 * S, 54 * S, argb(0x04070c, 0x88))
			g := yt.paused ? "‖" : "▶"
			text_in(cv, yt.f13b, g, ix + (96 * S - tw(yt.f13b, g)) / 2, iy, 54 * S, argb(H.acc, 0xff))
		}
		right, rc := "", H.dim
		switch {
		case l.now: right, rc = yt.hidden ? "player hidden" : "in the corner", yt.hidden ? a.theme.yellow : H.dim
		case yt.tab == .Queue && l.i == 0: right = "next · n"
		case yt.tab == .History:
			pc := yt_watched(yt, v.id)
			if pc > 0 && pc < 100 do right, rc = fmt.tprintf("%s · %d%% · ↵ resumes", yt_when(v.ts), pc), soft
			else do right = fmt.tprintf("%s · watched", yt_when(v.ts))
		}
		rw := tw(yt.f10, right)
		text_in(cv, yt.f10, right, x + w - 10 * S - rw, yy, rh, argb(rc, 0xff))
		tx := ix + 96 * S + 12 * S
		tmax := x + w - 10 * S - rw - 12 * S - tx
		meta := fmt.tprintf("%s · %s", v.channel, yt_secs(v.secs))
		if l.now do meta = fmt.tprintf("%s · %s of %s", v.channel, yt_clock(yt.pos), yt_secs(yt.dur))
		text_in(cv, yt.f12b, ellipsize(yt.f12b, v.title, tmax), tx, yy + rh / 2 - 19 * S, 18 * S, argb(on ? H.acc : H.fg, 0xff))
		text_in(cv, yt.f10, ellipsize(yt.f10, meta, tmax), tx, yy + rh / 2 + 3 * S, 14 * S, argb(H.dim, 0xff))
		yy += hgt
	}
}

// What plays, at the foot: its thumbnail, title and channel, how far (a bar and the time), where
// the player is, and play/pause. Nothing: a dashed outline and a line.
@(private = "file")
yt_strip :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	yt := Y(a)
	cv_w := cv.w
	fill_rect(cv, 0, y, cv_w, h, argb(H.panel, 0xff))
	fill_rect(cv, 0, y, cv_w, S, argb(H.line, 0xff))
	ty := y + (h - 36 * S) / 2
	if yt.now.id == "" {
		panel_dashed(cv, x, ty, 64 * S, 36 * S, S, argb(H.faint, 0xff))
		text_in(cv, yt.f11, "Nothing playing · ↵ on a video plays it in the corner player", x + 64 * S + 12 * S, y, h, argb(H.dim, 0xff))
		return
	}
	playing := !yt.paused
	yt_thumb(a, cv, S, H, yt.now.thumb, x, ty, 64 * S, 36 * S)
	rounded_rect(cv, x, ty, 64 * S, 36 * S, 0, 0, f32(S), playing ? argb(H.acc, 0x99) : argb(H.line, 0xff))
	// the button and the chip, from the right
	bs := 34 * S
	bx := x + w - bs
	by := y + (h - bs) / 2
	if playing do fill_rect(cv, bx, by, bs, bs, argb(H.acc, 0xff))
	rounded_rect(cv, bx, by, bs, bs, 0, 0, f32(S), argb(H.acc, 0xff))
	g := playing ? "‖" : "▶"
	text_in(cv, yt.f13b, g, bx + (bs - tw(yt.f13b, g)) / 2, by, bs, argb(playing ? H.bg : H.acc, 0xff))
	hit_add(a, bx, by, bs, bs, .Chip, 1, 0)
	chip := yt.hidden ? "PiP HIDDEN" : "PiP · TOP LEFT"
	cc := yt.hidden ? a.theme.yellow : H.dim
	cw := tw(yt.f10b, chip) + 5 * S + tw(yt.f10, "y") + 14 * S
	cx := bx - 12 * S - cw
	cy := y + (h - 20 * S) / 2
	if yt.hidden do fill_rect(cv, cx, cy, cw, 20 * S, argb(cc, 0x12))
	rounded_rect(cv, cx, cy, cw, 20 * S, 0, 0, f32(S), argb(yt.hidden ? cc : H.line, 0xff))
	text_in(cv, yt.f10b, chip, cx + 7 * S, cy, 20 * S, argb(cc, 0xff))
	text_in(cv, yt.f10, "y", cx + 7 * S + tw(yt.f10b, chip) + 5 * S, cy, 20 * S, argb(H.dim, 0xff))
	hit_add(a, cx, cy, cw, 20 * S, .Chip, 2, 0)
	// the title, the channel, how far
	tx := x + 64 * S + 12 * S
	tend := cx - 12 * S
	time_ := fmt.tprintf("%s / %s", yt_clock(yt.pos), yt_secs(yt.dur))
	chw := tw(yt.f10, yt.now.channel)
	tt := ellipsize(yt.f12b, yt.now.title, tend - tx - chw - 8 * S)
	text_in(cv, yt.f12b, tt, tx, y + 10 * S, 17 * S, argb(playing ? H.fg : mix(H.fg, H.bg, 0.2), 0xff))
	text_in(cv, yt.f10, yt.now.channel, tx + tw(yt.f12b, tt) + 8 * S, y + 11 * S, 17 * S, argb(H.dim, 0xff))
	tmw := tw(yt.f10, time_)
	text_in(cv, yt.f10, time_, tend - tmw, y + 30 * S, 14 * S, argb(H.dim, 0xff))
	pw := tend - tmw - 8 * S - tx
	fill_rect(cv, tx, y + 36 * S, pw, 3 * S, argb(H.line, 0xff))
	if yt.dur > 0 do fill_rect(cv, tx, y + 36 * S, pw * clamp(yt.pos, 0, yt.dur) / yt.dur, 3 * S, argb(playing ? H.acc : H.dim, 0xff))
}

// A card in the body: a title, lines, buttons (the first filled when hot). dashed: no fill, a
// dashed outline (nothing found).
@(private = "file")
yt_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h, cw_: int, c: u32, filled: bool, title: string, lines: []string, btns: [][2]string, hot: bool) {
	yt := Y(a)
	soft := mix(H.fg, H.bg, 0.2)
	cw := min(cw_ * S, w)
	wrapped := make([dynamic][]string, 0, len(lines), context.temp_allocator)
	ch := 16 * S + 19 * S
	for l in lines { ws := wrap_text(yt.f11, l, cw - 36 * S); append(&wrapped, ws); ch += 10 * S + len(ws) * 17 * S }
	ch += 10 * S + 28 * S + 16 * S
	cx, cy := x + (w - cw) / 2, y + max((h - ch) / 2, 8 * S)
	if filled {
		fill_rect(cv, cx, cy, cw, ch, argb(c, 0x0d))
		rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(c, 0xff))
		fill_rect(cv, cx, cy, 3 * S, ch, argb(c, 0xff))
	} else do panel_dashed(cv, cx, cy, cw, ch, S, argb(H.faint, 0xff))
	yy := cy + 16 * S
	text_in(cv, yt.f13b, ellipsize(yt.f13b, title, cw - 36 * S), cx + 18 * S, yy, 19 * S, argb(c, 0xff))
	yy += 19 * S
	for ws, i in wrapped {
		yy += 10 * S
		for l in ws { text_in(cv, yt.f11, l, cx + 18 * S, yy, 17 * S, argb(i == 0 && len(wrapped) > 1 ? H.dim : soft, 0xff)); yy += 17 * S }
	}
	yy += 10 * S
	bx := cx + 18 * S
	for b, i in btns {
		prime := i == 0 && hot
		bw := tw(yt.f11b, b[0]) + 7 * S + tw(yt.f11, b[1]) + 24 * S
		if prime do fill_rect(cv, bx, yy, bw, 28 * S, argb(c, 0xff))
		rounded_rect(cv, bx, yy, bw, 28 * S, 0, 0, f32(S), argb(prime ? c : H.line, 0xff))
		text_in(cv, yt.f11b, b[0], bx + 12 * S, yy, 28 * S, argb(prime ? H.bg : soft, 0xff))
		text_in(cv, yt.f11, b[1], bx + 12 * S + tw(yt.f11b, b[0]) + 7 * S, yy, 28 * S, argb(prime ? H.bg : H.dim, 0xff))
		hit_add(a, bx, yy, bw, 28 * S, .Chip, 20 + i, 0)
		bx += bw + 6 * S
	}
}

// yt-dlp or mpv missing, or being installed: what each is for, where it stands.
@(private = "file")
yt_setup_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int) {
	yt := Y(a)
	th := a.theme
	soft := mix(H.fg, H.bg, 0.2)
	ins := yt.state == "installing"
	cw := min(560 * S, w)
	line := ins ? "From your distribution’s packages, in a terminal. This window carries on when it is done." : "yt-dlp searches and fetches videos. mpv plays them in the corner player. No account, nothing to sign in to."
	ws := wrap_text(yt.f11, line, cw - 36 * S)
	ch := 16 * S + 19 * S + 10 * S + len(ws) * 17 * S + 10 * S + 2 * 28 * S + 4 * S + (ins ? 14 * S : 10 * S + 28 * S) + 16 * S
	cx, cy := x + (w - cw) / 2, y + max((h - ch) / 2, 8 * S)
	fill_rect(cv, cx, cy, cw, ch, argb(H.acc, 0x0d))
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(H.acc, 0xff))
	fill_rect(cv, cx, cy, 3 * S, ch, argb(H.acc, 0xff))
	yy := cy + 16 * S
	text_in(cv, yt.f13b, ins ? "Installing yt-dlp…" : "YouTube needs two programs", cx + 18 * S, yy, 19 * S, argb(H.acc, 0xff))
	yy += 19 * S + 10 * S
	for l in ws { text_in(cv, yt.f11, l, cx + 18 * S, yy, 17 * S, argb(soft, 0xff)); yy += 17 * S }
	yy += 10 * S
	pk := [2][3]string{{"yt-dlp", "search and streams · 3 MB", yt.ytv}, {"mpv", "the player", yt.mpvv}}
	for p, i in pk {
		ry := yy + i * (28 * S + 4 * S)
		rw := cw - 36 * S
		fill_rect(cv, cx + 18 * S, ry, rw, 28 * S, argb(H.bg, 0xff))
		rounded_rect(cv, cx + 18 * S, ry, rw, 28 * S, 0, 0, f32(S), argb(H.line, 0xff))
		have := p[2] != ""
		ic, icc := have ? "✓" : (ins ? "…" : "✕"), have ? th.green : (ins ? H.acc : th.red)
		st, stc := have ? p[2] : (ins ? "installing" : "missing"), have ? H.dim : (ins ? H.acc : th.red)
		text_in(cv, yt.f11b, ic, cx + 28 * S, ry, 28 * S, argb(icc, 0xff))
		text_in(cv, yt.f11b, p[0], cx + 46 * S, ry, 28 * S, argb(H.fg, 0xff))
		d := have && i == 1 ? "the player · already installed" : p[1]
		text_in(cv, yt.f11, d, cx + 46 * S + tw(yt.f11b, p[0]) + 10 * S, ry, 28 * S, argb(H.dim, 0xff))
		text_in(cv, yt.f10, st, cx + 18 * S + rw - 10 * S - tw(yt.f10, st), ry, 28 * S, argb(stc, 0xff))
	}
	yy += 2 * 28 * S + 4 * S
	if ins { // no progress to read from a terminal: a still bar
		yy += 10 * S
		fill_rect(cv, cx + 18 * S, yy, cw - 36 * S, 4 * S, argb(H.line, 0xff))
		fill_rect(cv, cx + 18 * S, yy, (cw - 36 * S) * 2 / 5, 4 * S, argb(H.acc, 0xff))
		return
	}
	yy += 10 * S
	bx := cx + 18 * S
	for b, i in ([2][2]string{{"Install yt-dlp", "↵"}, {"Not now", "Esc"}}) {
		bw := tw(yt.f11b, b[0]) + 7 * S + tw(yt.f11, b[1]) + 24 * S
		if i == 0 do fill_rect(cv, bx, yy, bw, 28 * S, argb(H.acc, 0xff))
		rounded_rect(cv, bx, yy, bw, 28 * S, 0, 0, f32(S), argb(i == 0 ? H.acc : H.line, 0xff))
		text_in(cv, yt.f11b, b[0], bx + 12 * S, yy, 28 * S, argb(i == 0 ? H.bg : soft, 0xff))
		text_in(cv, yt.f11, b[1], bx + 12 * S + tw(yt.f11b, b[0]) + 7 * S, yy, 28 * S, argb(i == 0 ? H.bg : H.dim, 0xff))
		hit_add(a, bx, yy, bw, 28 * S, .Chip, 20 + i, 0)
		bx += bw + 6 * S
	}
}

yt_dump :: proc(a: ^App) -> string {
	y := Y(a)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&sb, "youtube %s%s", y.state, y.note != "" ? fmt.tprintf(" · %s", y.note) : "")
	if yt_setup(y) {
		fmt.sbprintfln(&sb, "card %s · yt-dlp %s · mpv %s", y.state == "installing" ? "Installing" : "Missing", y.ytv != "" ? y.ytv : "missing", y.mpvv != "" ? y.mpvv : "missing")
		panel_dump_toast(&y.pn, &sb)
		return strings.to_string(sb)
	}
	fmt.sbprintfln(&sb, "find %s%s", panel_text(&y.pn), y.field ? "|" : "")
	l := yt_items(y, y.tab)
	if y.view == "channel" do fmt.sbprintfln(&sb, "channel %s", y.view_name)
	fmt.sbprintfln(&sb, "tab %v %d%s", y.tab, len(l), y.tab == .Results && !y.searched ? (len(y.feed) > 0 ? " · home" : fmt.tprintf(" · continue watching · home %s", y.home)) : "")
	switch {
	case y.tab == .Results && (y.state == "offline" || y.state == "error"): fmt.sbprintfln(&sb, "card Offline")
	case y.tab == .Results && y.searched && len(y.vids) == 0: fmt.sbprintfln(&sb, "card NoResults")
	}
	for v, i in l {
		mark := i == y.cur[y.tab] && !y.field ? "*" : " "
		if v.is_chan { fmt.sbprintfln(&sb, "%s [channel] %s · %s · %d subscribers", mark, v.title, v.channel, v.views); continue }
		extra := y.tab == .History ? "" : fmt.tprintf(" · %s", yt_secs(v.secs))
		if v.id == y.now.id do extra = strings.concatenate({extra, " · playing"}, context.temp_allocator)
		if pc := yt_watched(y, v.id); pc > 0 && v.ts > 0 do extra = strings.concatenate({extra, pc < 100 ? fmt.tprintf(" · %d%%", pc) : " · watched"}, context.temp_allocator)
		fmt.sbprintfln(&sb, "%s %s · %s%s%s", mark, v.title, v.channel, extra, v.thumb != "" ? "" : " · nothumb")
	}
	if y.now.id != "" do fmt.sbprintfln(&sb, "now %s %s · %s / %s · %s", y.paused ? "‖" : "▶", y.now.title, yt_clock(y.pos), yt_secs(y.dur), y.hidden ? "PiP HIDDEN" : "PiP · TOP LEFT")
	panel_dump_toast(&y.pn, &sb)
	return strings.to_string(sb)
}
