package k4

import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --releases: what is coming (k4-releases, releases.py): movies and TV (TMDB, Swedish dates), games
// (Steam), books (Hardcover), and what you follow. 1100×680 (--popup 420×560): the head (RELEASES ›
// TAB, the search, the count), five tabs (Alt+1–5, Tab), the list grouped by week (poster, title,
// date and "in 12 d", genres / platforms / author, ★ followed, a trailer, in the calendar) and the
// selected title's detail (poster, facts, every date, the overview, people, rating, trailers).
// ↵ plays the trailer (k4's YouTube player), t the next one; c puts the date in the calendar, f
// follows, o opens its page; typing searches the tab's source (↵), Esc clears it, then closes.
// Data (k4-releases data; the panel's R and L lines too):
//   K <kind> <ok|nokey|offline> <fetched>
//   I <tab> <kind> <id> <title> <date> <when> <line> <poster> <followed> <in calendar> <trailers> <old date>
//   O|P|F|G|U <kind> <id> <text>   overview, people, facts, rating, page
//   E <kind> <id> <date> <label> · V <kind> <id> <youtube id> <name> · Q <kind> <query>
// The runner's verbs: play KIND ID [N], cal KIND ID, follow KIND ID, open KIND ID, search KIND Q,
// clear, refresh, key tmdb|hardcover (the secret).

REL_W, REL_H :: 1100, 680
REL_PW, REL_PH :: 420, 560

Rel_Item :: struct { tab, kind, id, title, date, when_, line, poster, old: string, followed, incal: bool, trailers: int }
Rel_Detail :: struct { overview, people, facts, rating, url: string, dates: [dynamic][2]string, trailers: [dynamic][2]string, genres: []string }
Rel_Tab :: enum { Movies, TV, Games, Books, Following }

Releases :: struct {
	using pn: Panel,
	arena:    vmem.Arena,
	items:    [dynamic]Rel_Item,
	details:  map[string]Rel_Detail,
	state:    [4]string, // per kind: ok, nokey, offline
	fetched:  [4]i64,
	searched: string, // Q: the query the search tab holds
	search_kind: string,
	tab:      Rel_Tab,
	cat:      [5]string, // the category each tab filters by ("" all)
	cur:      int,
	trailer:  int, // the trailer t picked
	q:        [dynamic]u8, // the search (or a pasted key, on a tab without one)
	typing:   bool,
	f20b:     ^Font,
	select:   string, // K4_RELEASES_SELECT: kind:id to open on
}

@(private = "file") REL_KINDS := [4]string{"movies", "tv", "games", "books"}
@(private = "file") REL_TABS := [5]string{"Movies", "TV", "Games", "Books", "Following"}

releases_setup :: proc(a: ^App, data: string) {
	m := new(Releases)
	_ = vmem.arena_init_growing(&m.arena)
	m.mode = {draw = rel_draw, key = rel_key, click = rel_click, scroll = rel_scroll, loaded = rel_loaded, dump = rel_dump}
	m.f20b = font_sized(&a.font, 20)
	if b, ok := bold_font(a, 20); ok do m.f20b = b
	append(&a.fonts, m.f20b)
	m.select = strings.clone(os.get_env("K4_RELEASES_SELECT", context.temp_allocator))
	panel_init(a, &m.pn, "releases", data)
	a.width, a.height = m.popup ? REL_PW : REL_W, m.popup ? REL_PH : REL_H
}

@(private = "file")
RL :: proc(a: ^App) -> ^Releases { return (^Releases)(a.pn) }

@(private = "file")
rel_kind_i :: proc(k: string) -> int { for x, i in REL_KINDS do if x == k do return i; return -1 }

@(private = "file")
rel_loaded :: proc(a: ^App, data: string) {
	m := RL(a)
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al := context.allocator) -> string { return s == "-" ? "" : strings.clone(s, al) }
	m.items = make([dynamic]Rel_Item, al)
	m.details = make(map[string]Rel_Detail, 64, al)
	m.searched, m.search_kind = "", ""
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "K":
			if i := rel_kind_i(fget(f, 1)); i >= 0 { m.state[i] = c(fget(f, 2), al); m.fetched[i], _ = strconv.parse_i64(fget(f, 3)) }
		case "I":
			n, _ := strconv.parse_int(fget(f, 11))
			append(&m.items, Rel_Item{tab = c(fget(f, 1), al), kind = c(fget(f, 2), al), id = c(fget(f, 3), al), title = c(fget(f, 4), al), date = c(fget(f, 5), al),
				when_ = c(fget(f, 6), al), line = c(fget(f, 7), al), poster = c(fget(f, 8), al), followed = fget(f, 9) == "1", incal = fget(f, 10) == "1", trailers = n, old = c(fget(f, 12), al)})
		case "O", "P", "F", "G", "U", "E", "V", "C":
			k := strings.concatenate({fget(f, 1), ":", fget(f, 2)}, al)
			d := m.details[k] or_else Rel_Detail{dates = make([dynamic][2]string, al), trailers = make([dynamic][2]string, al)}
			switch f[0] {
			case "O": d.overview = c(fget(f, 3), al)
			case "P": d.people = c(fget(f, 3), al)
			case "F": d.facts = c(fget(f, 3), al)
			case "G": d.rating = c(fget(f, 3), al)
			case "U": d.url = c(fget(f, 3), al)
			case "E": append(&d.dates, [2]string{c(fget(f, 3), al), c(fget(f, 4), al)})
			case "V": append(&d.trailers, [2]string{c(fget(f, 3), al), c(fget(f, 4), al)})
			case "C": d.genres = strings.split(c(fget(f, 3), al), "|", al)
			}
			m.details[k] = d
		case "Q": m.search_kind, m.searched = c(fget(f, 1), al), c(fget(f, 2), al)
		}
	}
	if m.select != "" { // opened on a title (the launcher): its tab, its row
		kind, _, id := strings.partition(m.select, ":")
		if i := rel_kind_i(kind); i >= 0 {
			m.tab = Rel_Tab(i)
			for x, j in rel_list(m) do if x.id == id { m.cur = j; break }
		}
		m.select = ""
	}
	m.cur = clamp(m.cur, 0, max(len(rel_list(m)) - 1, 0))
	// a list being fetched in the background: look again every 2 s until it is in
	m.refresh_ms = 0
	for st in m.state do if st == "refreshing" do m.refresh_ms = 2000
}

// The shown tab's rows: its list, or the search's results while one is shown for it.
@(private = "file")
rel_searching :: proc(m: ^Releases) -> bool {
	return m.tab != .Following && m.searched != "" && m.search_kind == REL_KINDS[int(m.tab)]
}

// The shown tab's titles before the category filter.
@(private = "file")
rel_all :: proc(m: ^Releases) -> []Rel_Item {
	tab := m.tab == .Following ? "following" : (rel_searching(m) ? "search" : REL_KINDS[int(m.tab)])
	out := make([dynamic]Rel_Item, 0, 32, context.temp_allocator)
	for x in m.items do if x.tab == tab do append(&out, x)
	return out[:]
}

@(private = "file")
rel_genres :: proc(m: ^Releases, x: Rel_Item) -> []string {
	return m.details[strings.concatenate({x.kind, ":", x.id}, context.temp_allocator)].genres
}

// The shown rows: the tab's titles in its category.
@(private = "file")
rel_list :: proc(m: ^Releases) -> []Rel_Item {
	cat := m.cat[int(m.tab)]
	all := rel_all(m)
	if cat == "" do return all
	out := make([dynamic]Rel_Item, 0, len(all), context.temp_allocator)
	for x in all do for g in rel_genres(m, x) do if g == cat { append(&out, x); break }
	return out[:]
}

// The tab's categories, the most common first ("" = all, always first).
@(private = "file")
rel_cats :: proc(m: ^Releases) -> []string {
	count := make(map[string]int, 32, context.temp_allocator)
	order := make([dynamic]string, 0, 32, context.temp_allocator)
	for x in rel_all(m) do for g in rel_genres(m, x) {
		if g not_in count do append(&order, g)
		count[g] += 1
	}
	for i in 1 ..< len(order) { // most titles first (stable)
		j := i
		for j > 0 && count[order[j - 1]] < count[order[j]] { order[j - 1], order[j] = order[j], order[j - 1]; j -= 1 }
	}
	out := make([dynamic]string, 0, len(order) + 1, context.temp_allocator)
	append(&out, "")
	for g in order do append(&out, g)
	return out[:]
}

@(private = "file")
rel_step_cat :: proc(m: ^Releases, n: int) {
	cs := rel_cats(m)
	cur := 0
	for c, i in cs do if c == m.cat[int(m.tab)] do cur = i
	m.cat[int(m.tab)] = cs[((cur + n) % len(cs) + len(cs)) % len(cs)]
	m.cur, m.trailer = 0, 0
}

@(private = "file")
rel_pick :: proc(m: ^Releases) -> (Rel_Item, bool) {
	l := rel_list(m)
	if m.cur < len(l) do return l[m.cur], true
	return {}, false
}

// ---------- words ----------

@(private = "file")
rel_days :: proc(date: string) -> int {
	if len(date) < 10 do return 9999
	nd, _ := cal_now()
	return day_of(date) - nd
}

@(private = "file")
rel_day :: proc(date: string) -> string {
	if len(date) < 10 do return "no date yet"
	d := day_of(date)
	_, mo, dd := civil_from_days(d)
	return fmt.tprintf("%s %d %s", DOW3[weekday(d)], dd, MON3[mo - 1])
}

@(private = "file")
rel_in :: proc(date: string) -> string {
	n := rel_days(date)
	switch {
	case n == 9999: return ""
	case n < 0: return "out"
	case n == 0: return "today"
	case n == 1: return "tomorrow"
	}
	return fmt.tprintf("in %d d", n)
}

// The week heading a date belongs to.
@(private = "file")
rel_group :: proc(date: string) -> string {
	n := rel_days(date)
	nd, _ := cal_now()
	to_sunday := 6 - weekday(nd) // (days left in this week, Mon–Sun)
	switch {
	case n == 9999: return "No date yet"
	case n <= to_sunday: return "This week"
	case n <= to_sunday + 7: return "Next week"
	}
	_, mo, _ := civil_from_days(day_of(date))
	return MONTHS[mo - 1]
}

// ---------- keys ----------

@(private = "file")
rel_set_tab :: proc(m: ^Releases, t: Rel_Tab) {
	m.tab, m.cur, m.trailer, m.typing = t, 0, 0, false
	clear(&m.q)
}

@(private = "file")
rel_nokey :: proc(m: ^Releases) -> string {
	if m.tab == .Following do return ""
	return m.state[int(m.tab)] == "nokey" ? REL_KINDS[int(m.tab)] : ""
}

@(private = "file")
rel_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := RL(a)
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	plain := text != "" && k == .None && !ctrl && !alt
	l := rel_list(m)
	if ctrl && (low == 'c' || low == 'g') { panel_close(a); return true }
	if alt && ch >= '1' && ch <= '5' { rel_set_tab(m, Rel_Tab(int(ch - '1'))); return true }
	if k == .Tab || k == .Back_Tab { rel_set_tab(m, Rel_Tab((int(m.tab) + (k == .Tab ? 1 : 4)) % 5)); return true }
	if m.typing {
		nk := rel_nokey(m)
		switch {
		case k == .Enter:
			q := strings.trim_space(string(m.q[:]))
			if q != "" {
				if nk == "movies" || nk == "tv" do panel_run(a, "key", "tmdb", secret = strings.clone(q, context.temp_allocator))
				else if nk == "books" do panel_run(a, "key", "hardcover", secret = strings.clone(q, context.temp_allocator))
				else if nk == "" do panel_run(a, "search", REL_KINDS[int(m.tab)], q)
			}
			clear(&m.q); m.typing, m.cur = false, 0
		case k == .Escape: clear(&m.q); m.typing = false
		case k == .Backspace: if len(m.q) > 0 do pop(&m.q)
		case k == .Down: m.typing = false
		case ctrl && low == 'v': append(&m.q, ..transmute([]u8)strings.trim_space(msg_clipboard()))
		case plain: append(&m.q, ..transmute([]u8)text)
		case: return false
		}
		return true
	}
	x, ok := rel_pick(m)
	switch {
	case k == .Down: m.cur, m.trailer = min(m.cur + 1, max(len(l) - 1, 0)), 0
	case k == .Up:
		if m.cur == 0 && m.tab != .Following do m.typing = true
		else do m.cur, m.trailer = max(m.cur - 1, 0), 0
	case k == .Right: rel_step_cat(m, 1)
	case k == .Left: rel_step_cat(m, -1)
	case k == .Page_Down: m.cur, m.trailer = min(m.cur + 6, max(len(l) - 1, 0)), 0
	case k == .Page_Up: m.cur, m.trailer = max(m.cur - 6, 0), 0
	case k == .Enter: if ok do panel_run(a, "play", x.kind, x.id, fmt.tprint(m.trailer))
	case text == "t":
		if ok && x.trailers > 1 { m.trailer = (m.trailer + 1) % x.trailers; panel_run(a, "play", x.kind, x.id, fmt.tprint(m.trailer)) }
		else if ok do panel_say(&m.pn, x.trailers == 0 ? "No trailer for this one" : "Only one trailer")
	case text == "c": if ok do panel_run(a, "cal", x.kind, x.id)
	case text == "f": if ok do panel_run(a, "follow", x.kind, x.id)
	case text == "o": if ok do panel_run(a, "open", x.kind, x.id)
	case ctrl && low == 'r': panel_run(a, "refresh")
	case k == .Escape:
		if rel_searching(m) do panel_run(a, "clear")
		else do panel_close(a)
	case ctrl && low == 'v' && rel_nokey(m) != "": m.typing = true; append(&m.q, ..transmute([]u8)strings.trim_space(msg_clipboard()))
	case plain && text != " " && m.tab != .Following: m.typing = true; append(&m.q, ..transmute([]u8)text)
	case: return false
	}
	return true
}

@(private = "file")
rel_scroll :: proc(a: ^App, n: int) -> bool {
	m := RL(a)
	m.cur = clamp(m.cur - n, 0, max(len(rel_list(m)) - 1, 0))
	return true
}

// Hits: .Row a row, .Tab a tab, .Chip the detail's buttons (0 play, 1 calendar, 2 follow, 3 page), the field (9).
@(private = "file")
rel_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := RL(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row: m.cur, m.trailer, m.typing = h.a, 0, false
	case .Tab: rel_set_tab(m, Rel_Tab(h.a))
	case .Item: // a category chip
		cs := rel_cats(m)
		if h.a < len(cs) { m.cat[int(m.tab)] = cs[h.a]; m.cur, m.trailer = 0, 0 }
	case .Chip:
		keys := [4]string{"", "c", "f", "o"}
		if h.a == 0 do rel_key(a, .Enter, false, false, 0, "")
		else if h.a < 4 do rel_key(a, .None, false, false, rune(keys[h.a][0]), keys[h.a])
		else if h.a == 9 do m.typing = true
	case: return false
	}
	return true
}

// ---------- drawing ----------

@(private = "file")
rel_glyph :: proc(kind: string) -> string {
	switch kind {
	case "movies": return "󰿎"
	case "tv": return "󰔂"
	case "games": return "󰊗"
	case "books": return "󰂺"
	}
	return "·"
}

@(private = "file")
rel_poster :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, path, kind: string, x, y, w, h: int) {
	m := RL(a)
	fill_rect(cv, x, y, w, h, argb(mix(H.bg, H.acc, 0.08), 0xff))
	drawn := false
	if path != "" do if img := image_cover(a, path, w, h); img.ok { blit_image(cv, img.px, img.w, img.h, x, y); drawn = true }
	if !drawn {
		g := rel_glyph(kind)
		f := w > 80 * S ? m.f20b : m.f13
		text_in(cv, f, g, x + (w - tw(f, g)) / 2, y, h, argb(H.dim, 0xff))
	}
	rounded_rect(cv, x, y, w, h, 0, 0, f32(S), argb(H.line, 0xff))
}

@(private = "file")
rel_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := RL(a)
	H := panel_ground(a, cv)
	tn := msg_tones(a, H)
	w := cv.w
	px := 14 * S
	// the head: RELEASES › TAB, the search, the count
	hh := 44 * S
	crumb := fmt.tprintf("RELEASES › %s", strings.to_upper(REL_TABS[int(m.tab)], context.temp_allocator))
	if m.popup do crumb = "RELEASES"
	cw := tw(m.f11b, crumb) + 12 * S
	fill_rect(cv, px, (hh - 20 * S) / 2, cw, 20 * S, argb(H.acc, 0xff))
	text_in(cv, m.f11b, crumb, px + 6 * S, (hh - 20 * S) / 2, 20 * S, argb(H.bg, 0xff))
	l := rel_list(m)
	count := fmt.tprintf("%d %s", len(l), m.tab == .Following ? "followed" : "upcoming")
	if rel_searching(m) do count = fmt.tprintf("%d found", len(l))
	text_in(cv, m.f11, count, w - px - tw(m.f11, count), 0, hh, argb(H.dim, 0xff))
	qx := px + cw + 14 * S
	q := string(m.q[:])
	nk := rel_nokey(m)
	ph := m.tab == .Following ? "" : (nk != "" ? "Paste the key here (⌃V), ↵ saves it" : fmt.tprintf("Search %s…", strings.to_lower(REL_TABS[int(m.tab)], context.temp_allocator)))
	if rel_searching(m) && q == "" do ph = fmt.tprintf("Results for “%s” · Esc goes back", m.searched)
	shown := nk != "" && q != "" ? strings.repeat("•", min(len(q), 40), context.temp_allocator) : q
	if q == "" do text_in(cv, m.f13, ph, qx, 0, hh, argb(H.faint, 0xff))
	text_in(cv, m.f13, shown, qx, 0, hh, argb(H.fg, 0xff))
	if m.typing do fill_rect(cv, qx + (q != "" ? tw(m.f13, shown) + S : 0), (hh - 18 * S) / 2, 2 * S, 18 * S, argb(H.acc, 0xff))
	hit_add(a, qx, 0, w - qx - 100 * S, hh, .Chip, 9, 0)
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	y := hh + S
	// the tabs
	th := 34 * S
	tx := 10 * S
	for name, i in REL_TABS {
		on := int(m.tab) == i
		n := 0
		tab := i == 4 ? "following" : REL_KINDS[min(i, 3)]
		for x in m.items do if x.tab == tab do n += 1
		nl := n > 0 ? fmt.tprint(n) : ""
		kl := m.popup ? "" : fmt.tprintf("Alt+%d", i + 1)
		tbw := 24 * S + tw(m.f11b, name) + (nl != "" ? tw(m.f10, nl) + 14 * S : 0) + (kl != "" ? tw(m.f9, kl) + 6 * S : 0)
		if m.popup && tx + tbw > w do break
		if on { fill_rect(cv, tx, y, tbw, th, argb(H.acc, 0x0f)); fill_rect(cv, tx, y + th - 2 * S, tbw, 2 * S, argb(H.acc, 0xff)) }
		hit_add(a, tx, y, tbw, th, .Tab, i, 0)
		lx := tx + 12 * S
		if kl != "" { text_in(cv, m.f9, kl, lx, y, th, argb(on ? H.acc : H.faint, 0xff)); lx += tw(m.f9, kl) + 6 * S }
		text_in(cv, m.f11b, name, lx, y, th, argb(on ? H.fg : H.dim, 0xff))
		lx += tw(m.f11b, name) + 6 * S
		if nl != "" {
			nw := tw(m.f10, nl) + 8 * S
			rounded_rect(cv, lx, y + (th - 15 * S) / 2, nw, 15 * S, 0, 0, f32(S), argb(on ? mix(H.bg, H.acc, 0.6) : H.line, 0xff))
			text_in(cv, m.f10, nl, lx + 4 * S, y + (th - 15 * S) / 2, 15 * S, argb(on ? H.acc : H.dim, 0xff))
		}
		tx += tbw + 2 * S
	}
	fill_rect(cv, 0, y + th - S, w, S, argb(H.line, 0xff))
	y += th
	// the categories: All and the tab's genres, the most common first
	if cs := rel_cats(m); len(cs) > 1 && rel_nokey(m) == "" {
		ch := 30 * S
		cx := px
		for c, i in cs {
			label := c == "" ? "All" : c
			cw_ := tw(m.f10b, label) + 16 * S
			if cx + cw_ > w - px do break
			on := c == m.cat[int(m.tab)]
			cy := y + (ch - 20 * S) / 2
			if on do fill_rect(cv, cx, cy, cw_, 20 * S, argb(H.acc, 0xff))
			rounded_rect(cv, cx, cy, cw_, 20 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
			text_in(cv, m.f10b, label, cx + 8 * S, cy, 20 * S, argb(on ? H.bg : H.dim, 0xff))
			hit_add(a, cx, cy, cw_, 20 * S, .Item, i, 0)
			cx += cw_ + 6 * S
		}
		fill_rect(cv, 0, y + ch - S, w, S, argb(H.line, 0x80))
		y += ch
	}
	// the foot
	hints: [][2]string
	switch {
	case m.typing && nk != "": hints = msg_keys({"⌃V", "Paste"}, {"↵", "Save the key"}, {"Esc", "Cancel"})
	case m.typing: hints = msg_keys({"↵", "Search"}, {"↓", "List"}, {"Esc", "Clear"})
	case: hints = msg_keys({"↑↓", "Move"}, {"← →", "Category"}, {"↵", "Trailer"}, {"t", "Next trailer"}, {"c", "Calendar"}, {"f", "Follow"}, {"o", "Page"}, {"type", "Search"}, {"Esc", rel_searching(m) ? "Back" : "Close"})
	}
	if m.popup && len(hints) > 4 do hints = hints[:4]
	fy := panel_foot(a, cv, S, H, hints, false)
	bh := fy - y
	lw := m.popup ? w : 470 * S
	// a tab without its key, or offline: a card
	if nk != "" || (m.tab != .Following && m.state[int(m.tab)] == "offline" && len(l) == 0) {
		title, line: string
		if nk == "movies" || nk == "tv" do title, line = "TMDB needs a key", "1 · Sign up at themoviedb.org (free)  2 · Settings › API › API Read Access Token (the long one)  3 · Paste it here (⌃V), ↵ keeps it in the keyring."
		else if nk == "books" do title, line = "Hardcover needs a key", "1 · Sign up at hardcover.app (free)  2 · Settings › Hardcover API › copy the token  3 · Paste it here (⌃V), ↵ keeps it in the keyring."
		else do title, line = "Offline", "Nothing cached for this tab yet · Ctrl+R tries again."
		ls := wrap_text(m.f11, line, w - 2 * px - 40 * S)
		ch := 20 * S + 20 * S + len(ls) * 17 * S + 16 * S
		cx, cy := px, y + 16 * S
		fill_rect(cv, cx, cy, w - 2 * px, ch, argb(tn.yellow, 0x0d))
		rounded_rect(cv, cx, cy, w - 2 * px, ch, 0, 0, f32(S), argb(tn.yellow, 0xff))
		fill_rect(cv, cx, cy, 3 * S, ch, argb(tn.yellow, 0xff))
		text_in(cv, m.f13b, title, cx + 16 * S, cy + 12 * S, 20 * S, argb(tn.yellow, 0xff))
		for s, i in ls do text_in(cv, m.f11, s, cx + 16 * S, cy + 36 * S + i * 17 * S, 17 * S, argb(tn.soft, 0xff))
		return
	}
	if len(l) == 0 {
		e := m.tab == .Following ? "Nothing followed yet · f on a title follows it: a card when it nears or its date moves" : (rel_searching(m) ? "Nothing found" : "Nothing upcoming here yet")
		if m.tab != .Following && m.state[int(m.tab)] == "refreshing" do e = "Fetching… it shows here in a few seconds"
		if m.cat[int(m.tab)] != "" do e = fmt.tprintf("Nothing in %s · ← → another category", m.cat[int(m.tab)])
		text_in(cv, m.f12, e, px + 6 * S, y + 20 * S, 20 * S, argb(H.dim, 0xff))
		return
	}
	// the list, grouped by week
	rh := (m.popup ? 54 : 64) * S
	gh := 24 * S
	ly := y + 6 * S
	first := 0
	span :: proc(l: []Rel_Item, from, to, rh, gh: int) -> int {
		h := gh
		for i in from ..= to do if i > from && rel_group(l[i].date) != rel_group(l[i - 1].date) do h += gh
		return h + (to - from + 1) * rh
	}
	for first < m.cur && span(l, first, m.cur, rh, gh) > bh - 12 * S do first += 1
	for i in first ..< len(l) {
		x := l[i]
		if i == first || rel_group(x.date) != rel_group(l[i - 1].date) {
			if ly + gh + rh > fy do break
			spaced(cv, m.f9b, strings.to_upper(rel_group(x.date), context.temp_allocator), px, ly + 8 * S, 14 * S, H.faint, S)
			ly += gh
		}
		if ly + rh > fy do break
		on := i == m.cur && !m.typing
		if on {
			fill_rect(cv, 0, ly, lw, rh, argb(H.acc, 0x14))
			fill_rect(cv, 0, ly, 3 * S, rh, argb(H.acc, 0xff))
			mark_sel(a, 0, ly, lw, rh)
		}
		hit_add(a, 0, ly, lw, rh, .Row, i, 0)
		pw, ph_ := (m.popup ? 30 : 40) * S, (m.popup ? 45 : 60) * S
		rel_poster(a, cv, S, H, x.poster, x.kind, px, ly + (rh - ph_) / 2, pw, ph_)
		tx := px + pw + 12 * S
		rx := lw - px
		// the right: date and "in 12 d"
		dl := rel_day(x.date)
		inl := rel_in(x.date)
		dw := max(tw(m.f11b, dl), tw(m.f10, inl))
		text_in(cv, m.f11b, dl, rx - tw(m.f11b, dl), ly + 12 * S, 16 * S, argb(x.old != "" ? tn.yellow : H.fg, 0xff))
		text_in(cv, m.f10, inl, rx - tw(m.f10, inl), ly + 30 * S, 14 * S, argb(rel_days(x.date) <= 7 ? H.acc : H.dim, 0xff))
		// marks: followed, trailer, in the calendar
		mk := strings.concatenate({x.followed ? "★ " : "", x.trailers > 0 ? "▶ " : "", x.incal ? "󰃭" : ""}, context.temp_allocator)
		mw := tw(m.f11, mk)
		tw_ := rx - dw - 14 * S - mw - tx
		text_in(cv, m.f12b, ellipsize(m.f12b, x.title, tw_), tx, ly + 11 * S, 18 * S, argb(H.fg, 0xff))
		text_in(cv, m.f11, mk, rx - dw - 10 * S - mw, ly + 11 * S, 18 * S, argb(H.acc, 0xff))
		sub := x.when_ != "" ? fmt.tprintf("%s · %s", x.when_, x.line) : x.line
		if m.tab == .Following do sub = fmt.tprintf("%s · %s", strings.to_upper(x.kind[:1], context.temp_allocator), sub)
		text_in(cv, m.f10, ellipsize(m.f10, sub, rx - dw - 14 * S - tx), tx, ly + 32 * S, 14 * S, argb(H.dim, 0xff))
		if x.old != "" do text_in(cv, m.f10, fmt.tprintf("was %s", rel_day(x.old)), tx, ly + 47 * S, 13 * S, argb(tn.yellow, 0xff))
		ly += rh
	}
	if m.popup do return
	// the detail
	fill_rect(cv, lw, y, S, bh, argb(H.line, 0xff))
	x, ok := rel_pick(m)
	if !ok do return
	d := m.details[strings.concatenate({x.kind, ":", x.id}, context.temp_allocator)]
	dx := lw + 20 * S
	dw := w - dx - 20 * S
	dy := y + 16 * S
	ppw, pph := 150 * S, 225 * S
	rel_poster(a, cv, S, H, x.poster, x.kind, dx, dy, ppw, pph)
	ix := dx + ppw + 18 * S
	iw := dw - ppw - 18 * S
	tl := wrap_text(m.f20b, x.title, iw)
	iy := dy
	for t, i in tl { if i >= 2 do break; text_in(cv, m.f20b, t, ix, iy, 26 * S, argb(H.fg, 0xff)); iy += 26 * S }
	if d.facts != "" { text_in(cv, m.f11, ellipsize(m.f11, d.facts, iw), ix, iy + 2 * S, 16 * S, argb(tn.soft, 0xff)); iy += 22 * S }
	iy += 6 * S
	spaced(cv, m.f9b, "RELEASE", ix, iy, 14 * S, H.faint, S)
	iy += 18 * S
	if len(d.dates) == 0 { text_in(cv, m.f12b, rel_day(x.date), ix, iy, 18 * S, argb(H.fg, 0xff)); iy += 20 * S }
	for dt_, i in d.dates {
		if i >= 4 do break
		dl := rel_day(dt_[0])
		text_in(cv, m.f12b, dl, ix, iy, 18 * S, argb(dt_[0] == x.date ? H.acc : H.fg, 0xff))
		text_in(cv, m.f11, ellipsize(m.f11, dt_[1], iw - 120 * S), ix + 110 * S, iy, 18 * S, argb(tn.soft, 0xff))
		iy += 20 * S
	}
	if x.old != "" { text_in(cv, m.f11, fmt.tprintf("moved from %s", rel_day(x.old)), ix, iy, 16 * S, argb(tn.yellow, 0xff)); iy += 18 * S }
	if d.rating != "" { iy += 4 * S; text_in(cv, m.f11b, d.rating, ix, iy, 16 * S, argb(H.acc, 0xff)); iy += 18 * S }
	if d.people != "" { text_in(cv, m.f11, ellipsize(m.f11, d.people, iw), ix, iy, 16 * S, argb(H.dim, 0xff)); iy += 18 * S }
	// the buttons
	by := max(iy + 8 * S, dy + pph - 26 * S)
	bx := ix
	labels := [4][2]string{{x.trailers > 0 ? "Play trailer" : "No trailer", "↵"}, {x.incal ? "In calendar" : "Add to calendar", "c"}, {x.followed ? "Following" : "Follow", "f"}, {"Page", "o"}}
	for b, i in labels {
		if bx + panel_btn_w(a, S, b[0], b[1]) > dx + dw do break
		kind := Btn_Kind.Plain
		if i == 0 && x.trailers > 0 do kind = .Prime
		bx += panel_btn(a, cv, S, bx, by, 26 * S, H, b[0], b[1], kind, i) + 6 * S
	}
	// the overview, the trailers
	oy := max(dy + pph, by + 26 * S) + 16 * S
	if d.overview != "" {
		ls := wrap_text(m.f12, d.overview, dw)
		for s, i in ls {
			if oy + 18 * S > fy - (len(d.trailers) > 0 ? 70 * S : 10 * S) { break }
			text_in(cv, m.f12, s, dx, oy, 18 * S, argb(tn.soft, 0xff))
			oy += 18 * S
			_ = i
		}
	}
	if len(d.trailers) > 0 {
		oy += 10 * S
		spaced(cv, m.f9b, fmt.tprintf("TRAILERS · %d", len(d.trailers)), dx, oy, 14 * S, H.faint, S)
		oy += 18 * S
		for t, i in d.trailers {
			if oy + 18 * S > fy - 4 * S do break
			on := i == m.trailer
			text_in(cv, m.f11, on ? "▶" : "·", dx, oy, 18 * S, argb(on ? H.acc : H.dim, 0xff))
			text_in(cv, m.f11, ellipsize(m.f11, t[1], dw - 20 * S), dx + 16 * S, oy, 18 * S, argb(on ? H.fg : H.dim, 0xff))
			oy += 18 * S
		}
	}
}

rel_dump :: proc(a: ^App) -> string {
	m := RL(a)
	sb := strings.builder_make(context.temp_allocator)
	l := rel_list(m)
	fmt.sbprintfln(&sb, "releases %s · %d%s%s", REL_TABS[int(m.tab)], len(l), rel_searching(m) ? fmt.tprintf(" · search %s", m.searched) : "",
		m.tab != .Following && m.state[int(m.tab)] == "refreshing" ? " · refreshing" : "")
	if nk := rel_nokey(m); nk != "" do fmt.sbprintfln(&sb, "nokey %s", nk)
	if cs := rel_cats(m); len(cs) > 1 {
		parts := make([dynamic]string, 0, len(cs), context.temp_allocator)
		for c in cs do append(&parts, fmt.tprintf("%s%s", c == m.cat[int(m.tab)] ? "*" : "", c == "" ? "All" : c))
		fmt.sbprintfln(&sb, "categories %s", strings.join(parts[:], " · ", context.temp_allocator))
	}
	if len(m.q) > 0 do fmt.sbprintfln(&sb, "%sfield %s", m.typing ? "* " : "", rel_nokey(m) != "" ? "(hidden)" : string(m.q[:]))
	group := ""
	for x, i in l {
		if g := rel_group(x.date); g != group { group = g; fmt.sbprintfln(&sb, "  %s", strings.to_upper(g, context.temp_allocator)) }
		fmt.sbprintfln(&sb, "%s %s · %s %s · %s%s%s%s%s", i == m.cur && !m.typing ? "*" : " ", x.title, rel_day(x.date), rel_in(x.date), x.when_ != "" ? fmt.tprintf("%s · ", x.when_) : "", x.line,
			x.followed ? " ★" : "", x.trailers > 0 ? fmt.tprintf(" ▶%d", x.trailers) : "", x.incal ? " cal" : "")
	}
	if x, ok := rel_pick(m); ok {
		d := m.details[strings.concatenate({x.kind, ":", x.id}, context.temp_allocator)]
		fmt.sbprintfln(&sb, "detail %s · %s", x.title, d.facts)
		for dt_ in d.dates do fmt.sbprintfln(&sb, "  date %s %s", dt_[0], dt_[1])
		if d.people != "" do fmt.sbprintfln(&sb, "  people %s", d.people)
		for t, i in d.trailers do fmt.sbprintfln(&sb, "  %strailer %s", i == m.trailer ? "* " : "", t[1])
	}
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
