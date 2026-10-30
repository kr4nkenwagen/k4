package k4

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// --wow: World of Warcraft Forever (k4-wow, wow.py), the Kestrel design's KWow boards (KWowWindow,
// KWowStates), 1100×680: the head (the realm, the WoW Token), a strip (weekly reset, today, this
// week, account gold), a banner when something is off, three tabs (Alt+1–3, Tab):
//   Characters  newest seen first, a row each: the class colour on its edge, initial, name, realm,
//               race class level and item level, a dot when a profession cooldown is ready, gold;
//               rested (a bar to 150 %), where, last seen. ↵ unfolds: lockouts with a pip per boss,
//               cooldowns, played, bags and professions.
//   Addons      k4's companion first, then the ones with updates (an accent chip), then the rest.
//               Typing filters them; ↵ in the field searches Wago and CurseForge (a card asks for
//               a key one lacks: ^V pastes it, ↵ keeps it); ↵ on a hit installs. ^U updates all,
//               ^Z undoes the last update. While the game runs: "Close WoW first", rows locked.
//   Raid nights the weekly ones (also in Calendar): typing "thu 20:00 mc" and ↵ adds one, Del
//               removes the picked one, ↵ opens Calendar.
// ^P plays, r asks Blizzard again, Esc goes back (the field, then Characters, then closes).
// Not installed, and never played: a card fills the window instead. --popup (the bar's module)
// 420×560: the same, smaller.
// The data comes from k4-wow (panel lines R and L, panel.odin), again every 10 s while open:
//   S <ok|missing|noflavor> <version> <product> <running 1|0> <companion 1|0>
//   P <played today> <this week> <last session's end>
//   C <key> <name> <realm> <CLASS> <colour hex> <race> <level> <class name> <copper> <rested %, -1 none>
//     <played> <at this level> <item level> <zone> <subzone> <bags free> <seen> <resting 1|0> <bags> <professions>
//   X <key> <instance> <killed> <bosses> <reset unix> <raid 1|0>      a lockout
//   K <key> <cooldown> <ready unix, 0 now>
//   W realm <name> <UP|DOWN> <population> <queue 1|0> · W token <copper> · W why <noclient|notinapi|offline>
//   T <next reset unix> <now unix> · A <addons> <updates>
//   N <folder> <title> <version> <author> <notes> <source k4|wago|curseforge|github|> <newer version>
//   Q <searched for> <wago key 1|0> <curseforge key 1|0> · H <source> <id> <name> <summary>
//   D <n> <day> <HH:MM> <name> <next unix> · U <title> <old version> <new version> <when>
// The runner's verbs: play, install-companion, world, apps, update all, undo, add SOURCE ID,
// search Q, key wago|curseforge ($K4_INPUT), raid add DAY HH:MM NAME, raid remove N, calendar.

WOW_W, WOW_H :: 1100, 680
WOW_PW, WOW_PH :: 420, 560

Wow_Char :: struct { key, name, realm, class, race, cname, zone, subzone, profs: string, color: u32, level, rested, ilvl, bags, slots: int, gold, played, plevel, seen: i64, resting: bool }
Wow_Lock :: struct { key, name: string, killed, bosses: int, reset: i64, raid: bool }
Wow_Cd :: struct { key, name: string, ready: i64 }
Wow_Realm :: struct { name, status, pop: string, queue: bool }
Wow_Addon :: struct { folder, title, version, author, notes, source, update: string }
Wow_Hit :: struct { source, id, name, summary: string }
Wow_Raid :: struct { n: int, day, time, name: string, next: i64 }
Wow_Tab :: enum { Chars, Addons, Raids }

Wow :: struct {
	using pn: Panel,
	arena:  vmem.Arena,
	state, version, product, why: string,
	running, companion: bool,
	today, week, last, reset, now, token: i64,
	nups:   int,
	chars:  [dynamic]Wow_Char,
	locks:  [dynamic]Wow_Lock,
	cds:    [dynamic]Wow_Cd,
	realms: [dynamic]Wow_Realm,
	addons: [dynamic]Wow_Addon,
	hits:   [dynamic]Wow_Hit,
	raids:  [dynamic]Wow_Raid,
	searched: string,
	wago_key, cf_key: bool,
	undo:   [4]string, // title, old, new, when
	// what you do
	tab:    Wow_Tab,
	cur:    int,
	open:   int, // the unfolded character (-1 none)
	field:  bool, // the addons' field has the keys
	q:      [dynamic]u8, // the addons' filter / search; the raid nights' new line
	key:    [dynamic]u8, // a pasted API key (the card)
}

wow_setup :: proc(a: ^App, data: string) {
	m := new(Wow)
	_ = vmem.arena_init_growing(&m.arena)
	m.open = -1
	m.mode = {draw = wow_draw, key = wow_key, click = wow_click, scroll = wow_scroll, loaded = wow_loaded, dump = wow_dump}
	panel_init(a, &m.pn, "wow", data)
	m.refresh_ms = 10000
	a.width, a.height = m.popup ? WOW_PW : WOW_W, m.popup ? WOW_PH : WOW_H
	switch os.get_env("K4_WOW_TAB", context.temp_allocator) {
	case "addons": m.tab = .Addons
	case "raids": m.tab = .Raids
	}
}

@(private = "file")
WW :: proc(a: ^App) -> ^Wow { return (^Wow)(a.pn) }

@(private = "file")
wow_loaded :: proc(a: ^App, data: string) {
	m := WW(a)
	vmem.arena_free_all(&m.arena)
	al := vmem.arena_allocator(&m.arena)
	c :: proc(s: string, al: runtime.Allocator) -> string { return strings.clone(s, al) }
	i64_ :: proc(s: string) -> i64 { v, _ := strconv.parse_i64(s); return v }
	int_ :: proc(s: string) -> int { v, _ := strconv.parse_int(s); return v }
	m.chars, m.locks, m.cds = make([dynamic]Wow_Char, al), make([dynamic]Wow_Lock, al), make([dynamic]Wow_Cd, al)
	m.realms, m.addons, m.hits, m.raids = make([dynamic]Wow_Realm, al), make([dynamic]Wow_Addon, al), make([dynamic]Wow_Hit, al), make([dynamic]Wow_Raid, al)
	m.why, m.token, m.searched, m.undo = "", 0, "", {}
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := fields(line)
		switch f[0] {
		case "S":
			m.state, m.version, m.product = c(fget(f, 1), al), c(fget(f, 2), al), c(fget(f, 3), al)
			m.running, m.companion = fget(f, 4) == "1", fget(f, 5) == "1"
		case "P": m.today, m.week, m.last = i64_(fget(f, 1)), i64_(fget(f, 2)), i64_(fget(f, 3))
		case "C":
			col, _ := strconv.parse_uint(fget(f, 5), 16)
			append(&m.chars, Wow_Char{key = c(fget(f, 1), al), name = c(fget(f, 2), al), realm = c(fget(f, 3), al), class = c(fget(f, 4), al), color = u32(col),
				race = c(fget(f, 6), al), level = int_(fget(f, 7)), cname = c(fget(f, 8), al), gold = i64_(fget(f, 9)), rested = int_(fget(f, 10)),
				played = i64_(fget(f, 11)), plevel = i64_(fget(f, 12)), ilvl = int_(fget(f, 13)), zone = c(fget(f, 14), al), subzone = c(fget(f, 15), al),
				bags = int_(fget(f, 16)), seen = i64_(fget(f, 17)), resting = fget(f, 18) == "1", slots = int_(fget(f, 19)), profs = c(fget(f, 20), al)})
		case "X": append(&m.locks, Wow_Lock{key = c(fget(f, 1), al), name = c(fget(f, 2), al), killed = int_(fget(f, 3)), bosses = int_(fget(f, 4)), reset = i64_(fget(f, 5)), raid = fget(f, 6) == "1"})
		case "K": append(&m.cds, Wow_Cd{key = c(fget(f, 1), al), name = c(fget(f, 2), al), ready = i64_(fget(f, 3))})
		case "W":
			switch fget(f, 1) {
			case "realm": append(&m.realms, Wow_Realm{name = c(fget(f, 2), al), status = c(fget(f, 3), al), pop = c(fget(f, 4), al), queue = fget(f, 5) == "1"})
			case "token": m.token = i64_(fget(f, 2))
			case "why": m.why = c(fget(f, 2), al)
			}
		case "T": m.reset, m.now = i64_(fget(f, 1)), i64_(fget(f, 2))
		case "A": m.nups = int_(fget(f, 2))
		case "N": append(&m.addons, Wow_Addon{folder = c(fget(f, 1), al), title = c(fget(f, 2), al), version = c(fget(f, 3), al), author = c(fget(f, 4), al), notes = c(fget(f, 5), al), source = c(fget(f, 6), al), update = c(fget(f, 7), al)})
		case "Q": m.searched, m.wago_key, m.cf_key = c(fget(f, 1), al), fget(f, 2) == "1", fget(f, 3) == "1"
		case "H": append(&m.hits, Wow_Hit{source = c(fget(f, 1), al), id = c(fget(f, 2), al), name = c(fget(f, 3), al), summary = c(fget(f, 4), al)})
		case "D": append(&m.raids, Wow_Raid{n = int_(fget(f, 1)), day = c(fget(f, 2), al), time = c(fget(f, 3), al), name = c(fget(f, 4), al), next = i64_(fget(f, 5))})
		case "U": m.undo = {c(fget(f, 1), al), c(fget(f, 2), al), c(fget(f, 3), al), c(fget(f, 4), al)}
		}
	}
	if m.now == 0 do m.now = time.to_unix_seconds(time.now())
	if v, ok := strconv.parse_i64(os.get_env("K4_WOW_NOW", context.temp_allocator)); ok do m.now = v
	m.cur = clamp(m.cur, 0, max(wow_len(m) - 1, 0))
}

// ---------- words ----------

@(private = "file")
wow_gsc :: proc(copper: i64) -> (g, s, c: string) {
	gg, ss, cc := copper / 10000, copper / 100 % 100, copper % 100
	if gg > 0 do g = fmt.tprintf("%dg ", gg)
	if gg > 0 || ss > 0 do s = fmt.tprintf("%ds ", ss)
	return g, s, fmt.tprintf("%dc", cc)
}

@(private = "file")
wow_money :: proc(copper: i64) -> string { g, s, c := wow_gsc(copper); return strings.concatenate({g, s, c}, context.temp_allocator) }

@(private = "file")
wow_span :: proc(secs: i64) -> string {
	s := max(secs, 0)
	d, h, mi := s / 86400, s / 3600 % 24, s / 60 % 60
	if d > 0 do return fmt.tprintf("%d d %d h", d, h)
	if h > 0 do return fmt.tprintf("%d h %d m", h, mi)
	return fmt.tprintf("%d m", mi)
}

@(private = "file")
wow_ago :: proc(t, now: i64, short: bool) -> string {
	d := now - t
	if short do return d < 3600 ? fmt.tprintf("%d m", d / 60) : (d < 86400 ? fmt.tprintf("%d h", d / 3600) : fmt.tprintf("%d d", d / 86400))
	switch {
	case d < 120: return "just now"
	case d < 3600: return fmt.tprintf("%d min ago", d / 60)
	case d < 86400: return fmt.tprintf("%d h ago", d / 3600)
	}
	return fmt.tprintf("%d d ago", d / 86400)
}

// "Tue 09:00", "Thu 5 Nov"
@(private = "file")
wow_day :: proc(t: i64, with_date: bool) -> string {
	tm := time.unix(t, 0)
	days := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	_, mo, dd := time.date(tm)
	if with_date do return fmt.tprintf("%s %d %s", days[int(time.weekday(tm))], dd, months[int(mo) - 1])
	return fmt.tprintf("%s %s", days[int(time.weekday(tm))], msg_clock(t))
}

// ---------- the lists ----------

@(private = "file")
wow_lower :: proc(s: string) -> string { return strings.to_lower(s, context.temp_allocator) }

// The addons' rows: a heading, or an addon (i), or a search hit (i, hit).
Wow_Row :: struct { head: string, i: int, hit: bool }

@(private = "file")
wow_searching :: proc(m: ^Wow) -> bool {
	q := wow_lower(strings.trim_space(string(m.q[:])))
	return q != "" && q == wow_lower(m.searched)
}

@(private = "file")
wow_addon_rows :: proc(m: ^Wow) -> []Wow_Row {
	out := make([dynamic]Wow_Row, 0, len(m.addons) + len(m.hits) + 4, context.temp_allocator)
	q := wow_lower(strings.trim_space(string(m.q[:])))
	shown := make([dynamic]int, 0, len(m.addons), context.temp_allocator)
	for x, i in m.addons do if q == "" || strings.contains(wow_lower(strings.concatenate({x.title, " ", x.notes}, context.temp_allocator)), q) do append(&shown, i)
	if wow_searching(m) {
		append(&out, Wow_Row{head = fmt.tprintf("INSTALLED · %d", len(shown))})
		for i in shown do append(&out, Wow_Row{i = i})
		append(&out, Wow_Row{head = fmt.tprintf("FROM WAGO AND CURSEFORGE · %d", len(m.hits))})
		for _, i in m.hits do append(&out, Wow_Row{i = i, hit = true})
		return out[:]
	}
	own := -1
	ups := make([dynamic]int, 0, 8, context.temp_allocator)
	rest := make([dynamic]int, 0, 32, context.temp_allocator)
	for i in shown {
		switch {
		case m.addons[i].source == "k4": own = i
		case m.addons[i].update != "": append(&ups, i)
		case: append(&rest, i)
		}
	}
	if own >= 0 { append(&out, Wow_Row{head = "K4"}); append(&out, Wow_Row{i = own}) }
	if len(ups) > 0 { append(&out, Wow_Row{head = fmt.tprintf("UPDATES · %d", len(ups))}); for i in ups do append(&out, Wow_Row{i = i}) }
	if len(rest) > 0 { append(&out, Wow_Row{head = "UP TO DATE"}); for i in rest do append(&out, Wow_Row{i = i}) }
	return out[:]
}

// What ↑↓ move over in the shown tab.
@(private = "file")
wow_len :: proc(m: ^Wow) -> int {
	switch m.tab {
	case .Chars: return len(m.chars)
	case .Raids: return len(m.raids)
	case .Addons:
		n := 0
		for r in wow_addon_rows(m) do if r.head == "" do n += 1
		return n
	}
	return 0
}

@(private = "file")
wow_pick :: proc(m: ^Wow) -> (Wow_Row, bool) {
	k := 0
	for r in wow_addon_rows(m) do if r.head == "" { if k == m.cur do return r, true; k += 1 }
	return {}, false
}

@(private = "file")
wow_view :: proc(m: ^Wow) -> string {
	if m.state != "ok" do return "notinstalled"
	if len(m.chars) == 0 && m.tab == .Chars do return "neverplayed"
	return "main"
}

// The key card: a search was made and one of the two sources has no key.
@(private = "file")
wow_keycard :: proc(m: ^Wow) -> string {
	if m.tab != .Addons || !wow_searching(m) do return ""
	if !m.cf_key do return "curseforge"
	if !m.wago_key do return "wago"
	return ""
}

// ---------- keys ----------

@(private = "file")
wow_set_tab :: proc(m: ^Wow, t: Wow_Tab) {
	m.tab, m.cur, m.field = t, 0, false
	clear(&m.q)
}

@(private = "file")
wow_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	m := WW(a)
	low := ch >= 'A' && ch <= 'Z' ? ch + 32 : ch
	plain := text != "" && k == .None && !ctrl && !alt
	n := wow_len(m)
	if ctrl && (low == 'c' || low == 'g') { panel_close(a); return true }
	if ctrl && low == 'p' { panel_run(a, "play"); return true }
	if wow_view(m) == "notinstalled" {
		switch {
		case k == .Enter: panel_run(a, "apps")
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	if alt && ch >= '1' && ch <= '3' { wow_set_tab(m, Wow_Tab(int(ch - '1'))); return true }
	if k == .Tab || k == .Back_Tab { wow_set_tab(m, Wow_Tab((int(m.tab) + (k == .Tab ? 1 : 2)) % 3)); return true }
	if wow_view(m) == "neverplayed" {
		switch {
		case k == .Enter: panel_run(a, m.companion ? "play" : "install-companion")
		case text == "a": wow_set_tab(m, .Addons)
		case k == .Escape: panel_close(a)
		case: return false
		}
		return true
	}
	switch m.tab {
	case .Chars:
		switch {
		case k == .Down: m.cur = min(m.cur + 1, max(n - 1, 0))
		case k == .Up: m.cur = max(m.cur - 1, 0)
		case k == .Enter: m.open = m.open == m.cur ? -1 : m.cur
		case text == "a": wow_set_tab(m, .Addons)
		case text == "r": panel_run(a, "world")
		case k == .Escape:
			if m.open >= 0 do m.open = -1
			else do panel_close(a)
		case: return false
		}
	case .Addons:
		card := wow_keycard(m)
		if card != "" && ctrl && low == 'v' { clear(&m.key); append(&m.key, ..transmute([]u8)strings.trim_space(msg_clipboard())); return true }
		if card != "" && len(m.key) > 0 && k == .Enter && !m.field {
			panel_run(a, "key", card, secret = strings.clone(string(m.key[:]), context.temp_allocator))
			clear(&m.key)
			return true
		}
		switch {
		case ctrl && low == 'u':
			switch {
			case m.running: panel_say(&m.pn, "Close WoW first · updates wait until it quits", a.theme.yellow)
			case m.nups == 0: panel_say(&m.pn, "Everything is up to date")
			case: panel_run(a, "update", "all")
			}
		case ctrl && low == 'z':
			if m.running do panel_say(&m.pn, "Close WoW first", a.theme.yellow)
			else do panel_run(a, "undo")
		case m.field:
			switch {
			case k == .Enter:
				q := strings.trim_space(string(m.q[:]))
				if q != "" do panel_run(a, "search", q)
				m.field, m.cur = false, 0
			case k == .Down: m.field = false
			case k == .Escape: clear(&m.q); m.field = false
			case k == .Backspace: if len(m.q) > 0 do pop(&m.q)
			case ctrl && low == 'v': append(&m.q, ..transmute([]u8)msg_clipboard())
			case plain: append(&m.q, ..transmute([]u8)text); m.cur = 0
			case: return false
			}
		case k == .Down: m.cur = min(m.cur + 1, max(n - 1, 0))
		case k == .Up:
			if m.cur == 0 do m.field = true
			else do m.cur -= 1
		case k == .Enter:
			r, ok := wow_pick(m)
			if !ok do return true
			if !r.hit {
				x := m.addons[r.i]
				panel_say(&m.pn, x.notes != "" ? x.notes : fmt.tprintf("%s %s · %s", x.title, x.version, x.source != "" ? x.source : "untracked"))
				return true
			}
			if m.running { panel_say(&m.pn, "Close WoW first", a.theme.yellow); return true }
			h := m.hits[r.i]
			panel_run(a, "add", h.source, h.id)
		case k == .Escape:
			if len(m.q) > 0 do clear(&m.q)
			else do wow_set_tab(m, .Chars)
		case k == .Backspace: if len(m.q) > 0 { pop(&m.q); m.field = true }
		case plain: m.field = true; append(&m.q, ..transmute([]u8)text); m.cur = 0
		case: return false
		}
	case .Raids:
		switch {
		case k == .Down: m.cur = min(m.cur + 1, max(n - 1, 0))
		case k == .Up: m.cur = max(m.cur - 1, 0)
		case k == .Enter:
			if len(m.q) > 0 {
				words := strings.fields(string(m.q[:]), context.temp_allocator)
				if len(words) < 3 { panel_say(&m.pn, "Day, time and name: thu 20:00 mc", a.theme.yellow); return true }
				args := make([dynamic]string, 0, len(words) + 1, context.temp_allocator)
				append(&args, "add")
				for w in words do append(&args, w)
				panel_run(a, "raid", ..args[:])
				clear(&m.q)
			} else do panel_run(a, "calendar")
		case k == .Delete: if m.cur < len(m.raids) do panel_run(a, "raid", "remove", fmt.tprint(m.raids[m.cur].n))
		case k == .Backspace: if len(m.q) > 0 do pop(&m.q)
		case k == .Escape:
			if len(m.q) > 0 do clear(&m.q)
			else do wow_set_tab(m, .Chars)
		case plain: append(&m.q, ..transmute([]u8)text)
		case: return false
		}
	}
	return true
}

@(private = "file")
wow_scroll :: proc(a: ^App, n: int) -> bool {
	m := WW(a)
	m.cur = clamp(m.cur - n, 0, max(wow_len(m) - 1, 0))
	return true
}

// Hits: .Row a row (a: its place), .Item b 1 a tab (a), .Chip a card's button (0, 1), Update all
// (2), the addons' field (9).
@(private = "file")
wow_click :: proc(a: ^App, x, y, button: int) -> bool {
	m := WW(a)
	h, ok := hit_at(a, x, y)
	if !ok do return false
	#partial switch h.kind {
	case .Row:
		if m.tab == .Chars && h.a == m.cur do m.open = m.open == m.cur ? -1 : m.cur
		m.cur, m.field = h.a, false
	case .Item: if h.b == 1 do wow_set_tab(m, Wow_Tab(h.a))
	case .Chip:
		switch h.a {
		case 0: wow_key(a, .Enter, false, false, 0, "")
		case 1: wow_set_tab(m, .Addons)
		case 2: wow_key(a, .None, true, false, 'u', "")
		case 9: m.field = true
		}
	case: return false
	}
	return true
}

// ---------- drawing ----------

WOW_GOLD :: 0xFFC857
WOW_SILVER :: 0xC7D3DA
WOW_COPPER :: 0xD08A55
WOW_ORANGE :: 0xE8A33D

@(private = "file")
Wow_Rect :: struct { x, y, w, h: int }

// Gold, silver and copper, each in its colour, from x; returns the width.
@(private = "file")
wow_draw_money :: proc(cv: ^Canvas, f: ^Font, copper: i64, x, y, h: int) -> int {
	g, s, c := wow_gsc(copper)
	gx := x
	parts := [3]string{g, s, c}
	cols := [3]u32{WOW_GOLD, WOW_SILVER, WOW_COPPER}
	for p, i in parts {
		if cv != nil do text_in(cv, f, p, gx, y, h, argb(cols[i], 0xff))
		gx += tw(f, p)
	}
	return gx - x
}

@(private = "file")
wow_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	m := WW(a)
	H := panel_ground(a, cv)
	tn := msg_tones(a, H)
	w := cv.w
	px := 14 * S
	view := wow_view(m)
	// the head: WOW › TAB, the game, the realm, the token
	hh := 40 * S
	crumb := view == "notinstalled" ? "WOW" : (m.tab == .Chars ? "WOW › CHARACTERS" : (m.tab == .Addons ? "WOW › ADDONS" : "WOW › RAID NIGHTS"))
	cw := tw(m.f11b, crumb) + 12 * S
	fill_rect(cv, px, (hh - 20 * S) / 2, cw, 20 * S, argb(H.acc, 0xff))
	text_in(cv, m.f11b, crumb, px + 6 * S, (hh - 20 * S) / 2, 20 * S, argb(H.bg, 0xff))
	rx := w - px
	api_off := m.why != "" || len(m.realms) == 0
	if view != "notinstalled" {
		if !m.popup {
			tok := api_off || m.token == 0 ? "—" : wow_money(m.token)
			rx -= tw(m.f11b, tok)
			text_in(cv, m.f11b, tok, rx, 0, hh, argb(api_off ? H.dim : WOW_GOLD, 0xff))
			rx -= tw(m.f11, "Token ")
			text_in(cv, m.f11, "Token ", rx, 0, hh, argb(H.dim, 0xff))
			rx -= 14 * S
		}
		rl, rc := "realm · —", H.dim
		if len(m.realms) > 0 && m.why == "" {
			r := m.realms[0]
			switch {
			case r.status == "DOWN": rl, rc = fmt.tprintf("%s · down", r.name), tn.red
			case r.queue: rl, rc = m.popup ? "queue" : fmt.tprintf("%s · up · queue", r.name), tn.yellow
			case: rl, rc = fmt.tprintf("%s · up", r.name), tn.green
			}
		} else if len(m.chars) > 0 do rl = fmt.tprintf("%s · %s", m.chars[0].realm, m.why == "offline" ? "?" : "—")
		rx -= tw(m.f11, rl)
		text_in(cv, m.f11, rl, rx, 0, hh, argb(rc, 0xff))
		rx -= 13 * S
		rounded_rect(cv, rx, (hh - 7 * S) / 2, 7 * S, 7 * S, f32(S) * 3.5, argb(rc, 0xff))
		rx -= 10 * S
	}
	head := m.popup ? "Forever" : fmt.tprintf("World of Warcraft · Forever%s", m.running ? fmt.tprintf(" · playing %s", wow_span(m.today)) : "")
	tx := px + cw + 10 * S
	text_in(cv, m.f12, ellipsize(m.f12, head, rx - tx), tx, 0, hh, argb(tn.soft, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	y := hh + S
	// the foot
	hints: [][2]string
	switch {
	case view == "notinstalled": hints = msg_keys({"↵", "Battle.net"}, {"Esc", "Close"})
	case view == "neverplayed": hints = msg_keys({"↵", m.companion ? "Play" : "Install the companion"}, {"a", "Addons"}, {"Tab", "Next tab"}, {"Esc", "Close"})
	case m.tab == .Chars: hints = msg_keys({"↑↓", "Pick"}, {"↵", m.open >= 0 ? "Fold" : "Expand"}, {"^P", "Play"}, {"a", "Addons"}, {"r", "Refresh"}, {"Tab", "Next tab"}, {"Esc", "Close"})
	case m.tab == .Addons: hints = m.field ? msg_keys({"↵", "Search Wago, CurseForge"}, {"↓", "List"}, {"Esc", "Clear"}) : msg_keys({"type", "Find"}, {"↑↓", "Move"}, {"↵", wow_searching(m) ? "Install" : "Details"}, {"^U", "Update all"}, {"^Z", "Undo"}, {"Esc", "Back"})
	case: hints = msg_keys({"↑↓", "Move"}, {"↵", len(m.q) > 0 ? "Add" : "Open in Calendar"}, {"type", "New"}, {"Del", "Remove"}, {"Esc", "Back"})
	}
	if m.popup && len(hints) > 4 do hints = hints[:4]
	fy := panel_foot(a, cv, S, H, hints, false)
	if view == "notinstalled" { wow_draw_card(a, cv, S, H, 0, y, w, fy - y, view); return }
	// the strip: reset, today, this week, gold
	sh := 32 * S
	fill_rect(cv, 0, y, w, sh, argb(H.panel, 0xff))
	gold: i64 = 0
	for c in m.chars do gold += c.gold
	label :: proc(cv: ^Canvas, m: ^Wow, S, x, y, h: int, l: string, H: HUD) -> int {
		spaced(cv, m.f9, l, x, y, h, H.dim, S)
		return x + spaced_w(m.f9, l, S) + 6 * S
	}
	value :: proc(cv: ^Canvas, m: ^Wow, S, x, y, h: int, v: string, c: u32) -> int {
		text_in(cv, m.f11b, v, x, y, h, argb(c, 0xff))
		return x + tw(m.f11b, v) + (m.popup ? 12 : 22) * S
	}
	sx := px
	if m.popup {
		sx = value(cv, m, S, label(cv, m, S, sx, y, sh, "RESET", H), y, sh, wow_span(m.reset - m.now), H.fg)
		gx := label(cv, m, S, sx, y, sh, "GOLD", H)
		g, s, _ := wow_gsc(gold)
		text_in(cv, m.f11b, strings.concatenate({g, s}, context.temp_allocator), gx, y, sh, argb(WOW_GOLD, 0xff))
	} else {
		sx = value(cv, m, S, label(cv, m, S, sx, y, sh, "WEEKLY RESET", H), y, sh, fmt.tprintf("%s · %s", wow_span(m.reset - m.now), wow_day(m.reset, false)), H.fg)
		sx = value(cv, m, S, label(cv, m, S, sx, y, sh, "TODAY", H), y, sh, wow_span(m.today), tn.soft)
		sx = value(cv, m, S, label(cv, m, S, sx, y, sh, "THIS WEEK", H), y, sh, wow_span(m.week), tn.soft)
		wow_draw_money(cv, m.f11b, gold, label(cv, m, S, sx, y, sh, "ACCOUNT GOLD", H), y, sh)
	}
	fill_rect(cv, 0, y + sh, w, S, argb(H.line, 0xff))
	y += sh + S
	// the banner
	bt, bsub, bact := "", "", ""
	bc := tn.yellow
	switch {
	case m.running && m.tab == .Addons: bt, bsub, bact = "Close WoW first", "addons can’t change while the game runs · updates and installs wait until it quits", fmt.tprintf("playing %s", wow_span(m.today))
	case len(m.realms) > 0 && m.realms[0].status == "DOWN": bt, bsub, bc = fmt.tprintf("%s is down", m.realms[0].name), "you get a card when it is back", tn.red
	case !m.companion && len(m.chars) > 0: bt, bsub, bact = "Companion addon missing", "characters are from your last session with it · install it and log in once to refresh gold, rested and lockouts", "Install · Addons"
	case m.why == "noclient": bt, bsub, bact, bc = "No Blizzard API client", "realm status and the token need one · develop.battle.net › API access › Create client · then k4-wow act client ID", "Set up", H.acc
	case m.why == "notinapi": bt, bsub, bc = "Forever isn’t in Blizzard’s API yet", "realm status and the token show “—” until Blizzard adds the Forever realms · characters and addons work", H.dim
	case m.why == "offline": bt, bsub = "Offline", "realm, token and addon updates wait · characters are from your last logout"
	}
	if bt != "" && view == "main" {
		bh := 30 * S
		fill_rect(cv, 0, y, w, bh, argb(bc, 0x12))
		fill_rect(cv, 0, y, 3 * S, bh, argb(bc, 0xff))
		fill_rect(cv, 0, y + bh - S, w, S, argb(bc, 0xff))
		text_in(cv, m.f11b, bt, px, y, bh, argb(bc, 0xff))
		ax := w - px
		if bact != "" {
			aw := tw(m.f10b, bact) + 14 * S
			ax -= aw
			rounded_rect(cv, ax, y + (bh - 18 * S) / 2, aw, 18 * S, 0, 0, f32(S), argb(bc, 0xff))
			text_in(cv, m.f10b, bact, ax + 7 * S, y + (bh - 18 * S) / 2, 18 * S, argb(bc, 0xff))
			ax -= 10 * S
		}
		bx := px + tw(m.f11b, bt) + 10 * S
		text_in(cv, m.f10, ellipsize(m.f10, bsub, ax - bx), bx, y, bh, argb(tn.soft, 0xff))
		y += bh
	}
	// the tabs
	th := 32 * S
	tabx := 10 * S
	names := [3]string{"Characters", "Addons", "Raid nights"}
	counts := [3]int{len(m.chars), m.nups, len(m.raids)}
	for name, i in names {
		on := int(m.tab) == i
		hot := i == 1 && m.nups > 0
		nl := counts[i] > 0 ? fmt.tprint(counts[i]) : ""
		kl := m.popup ? "" : fmt.tprintf("Alt+%d", i + 1)
		tw_ := tw(m.f11b, name) + (nl != "" ? tw(m.f10, nl) + 14 * S : 0) + (kl != "" ? tw(m.f9, kl) + 6 * S : 0) + 24 * S
		if on {
			fill_rect(cv, tabx, y, tw_, th, argb(H.acc, 0x0f))
			fill_rect(cv, tabx, y + th - 2 * S, tw_, 2 * S, argb(H.acc, 0xff))
		}
		hit_add(a, tabx, y, tw_, th, .Item, i, 1)
		lx := tabx + 12 * S
		text_in(cv, m.f11b, name, lx, y, th, argb(on ? H.fg : H.dim, 0xff))
		lx += tw(m.f11b, name) + 6 * S
		if nl != "" {
			nw := tw(m.f10, nl) + 8 * S
			if hot do fill_rect(cv, lx, y + (th - 15 * S) / 2, nw, 15 * S, argb(H.acc, 0xff))
			rounded_rect(cv, lx, y + (th - 15 * S) / 2, nw, 15 * S, 0, 0, f32(S), argb(hot ? H.acc : H.line, 0xff))
			text_in(cv, m.f10, nl, lx + 4 * S, y + (th - 15 * S) / 2, 15 * S, argb(hot ? H.bg : (on ? H.acc : H.dim), 0xff))
			lx += nw + 6 * S
		}
		if kl != "" do text_in(cv, m.f9, kl, lx, y, th, argb(H.faint, 0xff))
		tabx += tw_ + 2 * S
	}
	if !m.popup {
		note := m.tab == .Addons ? fmt.tprintf("%d installed · Interface/AddOns", len(m.addons)) : (m.tab == .Chars ? "newest seen first" : "also in Calendar")
		text_in(cv, m.f10, note, w - px - tw(m.f10, note), y, th, argb(H.dim, 0xff))
	}
	fill_rect(cv, 0, y + th - S, w, S, argb(H.line, 0xff))
	y += th
	body := Wow_Rect{12 * S, y + 10 * S, w - 24 * S, fy - y - 20 * S}
	switch {
	case view == "neverplayed": wow_draw_card(a, cv, S, H, 0, y, w, fy - y, view)
	case m.tab == .Chars: wow_draw_chars(a, cv, S, H, body)
	case m.tab == .Addons: wow_draw_addons(a, cv, S, H, body)
	case: wow_draw_raids(a, cv, S, H, body)
	}
}

// The characters: a row each; the picked one unfolded.
@(private = "file")
wow_draw_chars :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: Wow_Rect) {
	m := WW(a)
	tn := msg_tones(a, H)
	gap := 8 * S
	row := (m.popup ? 54 : 64) * S
	unf := m.open >= 0 && !m.popup ? wow_unfold_h(m, S) : 0
	first := 0
	for {
		used := 0
		for i in first ..= min(m.cur, len(m.chars) - 1) do used += row + gap + (i == m.open ? unf : 0)
		if used <= r.h || first >= m.cur do break
		first += 1
	}
	y := r.y
	for i in first ..< len(m.chars) {
		c := m.chars[i]
		h := row + (i == m.open && !m.popup ? unf : 0)
		if y + h > r.y + r.h && i > first do break
		on := i == m.cur
		cc := c.color != 0 ? c.color : H.acc
		bg := on ? mix(H.bg, H.acc, 0.06) : H.panel
		fill_rect(cv, r.x, y, r.w, h, argb(bg, 0xff))
		rounded_rect(cv, r.x, y, r.w, h, 0, 0, f32(S), argb(on ? mix(H.bg, H.acc, 0.55) : H.line, 0xff))
		fill_rect(cv, r.x, y, 4 * S, h, argb(cc, 0xff))
		if on do mark_sel(a, r.x, y, r.w, h)
		hit_add(a, r.x, y, r.w, h, .Row, i, 0)
		pad := (m.popup ? 12 : 14) * S
		av := (m.popup ? 30 : 40) * S
		ax, ay := r.x + pad, y + (row - av) / 2
		fill_rect(cv, ax, ay, av, av, argb(cc, 0xff))
		fill_rect(cv, ax + av - 7 * S, ay, 7 * S, 7 * S, argb(bg, 0xff)) // (the cut corner)
		ini := c.name[:min(len(c.name), 1)]
		af := m.popup ? m.f13b : m.f15b
		text_in(cv, af, ini, ax + (av - tw(af, ini)) / 2, ay, av, argb(H.bg, 0xff))
		tx := ax + av + 12 * S
		rx := r.x + r.w - pad
		// the first line: name, realm, what, the cooldown dot; gold at the right
		l1 := y + (m.popup ? 9 : 12) * S
		nf := m.popup ? m.f13b : m.f15b
		gw := wow_draw_money(nil, m.f12b, c.gold, 0, 0, 0)
		wow_draw_money(cv, m.f12b, c.gold, rx - gw, l1, 18 * S)
		text_in(cv, nf, c.name, tx, l1, 18 * S, argb(cc, 0xff))
		lx := tx + tw(nf, c.name) + 8 * S
		if !m.popup { text_in(cv, m.f11, c.realm, lx, l1, 18 * S, argb(H.dim, 0xff)); lx += tw(m.f11, c.realm) + 8 * S }
		what := m.popup ? fmt.tprintf("%d %s", c.level, c.cname) : fmt.tprintf("%s %s %d%s", c.race, c.cname, c.level, c.ilvl > 0 ? fmt.tprintf(" · ilvl %d", c.ilvl) : "")
		wl := ellipsize(m.f11, what, rx - gw - 30 * S - lx)
		text_in(cv, m.f11, wl, lx, l1, 18 * S, argb(tn.soft, 0xff))
		lx += tw(m.f11, wl) + 8 * S
		for k in m.cds do if k.key == c.key && k.ready <= m.now { rounded_rect(cv, lx, l1 + 6 * S, 7 * S, 7 * S, f32(S) * 3.5, argb(H.acc, 0xff)); break }
		// the second line: rested, where, seen
		l2 := l1 + 22 * S
		bx := tx
		if c.rested >= 0 {
			bw := (m.popup ? 60 : 90) * S
			full := c.rested >= 150
			rc := full ? tn.green : (c.rested >= 50 ? a.theme.blue : H.dim)
			fill_rect(cv, bx, l2 + 5 * S, bw, 6 * S, argb(H.line, 0xff))
			fill_rect(cv, bx, l2 + 5 * S, bw * min(c.rested, 150) / 150, 6 * S, argb(rc, 0xff))
			fill_rect(cv, bx + bw * 2 / 3, l2 + 3 * S, S, 10 * S, argb(H.dim, 0xff))
			rl := full ? "rested full" : fmt.tprintf("rested %d %%", c.rested)
			text_in(cv, m.f10b, rl, bx + bw + 6 * S, l2, 16 * S, argb(rc, 0xff))
			bx += bw + 6 * S + tw(m.f10b, rl) + 12 * S
		}
		seen := m.running && i == 0 ? "playing now" : (m.popup ? wow_ago(c.seen, m.now, true) : fmt.tprintf("seen %s", wow_ago(c.seen, m.now, false)))
		text_in(cv, m.f10, seen, rx - tw(m.f10, seen), l2, 16 * S, argb(H.dim, 0xff))
		at := c.zone != "" ? (c.subzone != "" && c.subzone != c.zone ? fmt.tprintf("%s · %s", c.zone, c.subzone) : c.zone) : ""
		if !m.popup && c.zone != "" do at = fmt.tprintf("%s · bags %d free", at, c.bags)
		text_in(cv, m.f10, ellipsize(m.f10, at, rx - tw(m.f10, seen) - 12 * S - bx), bx, l2, 16 * S, argb(H.dim, 0xff))
		if i == m.open && !m.popup do wow_draw_unfold(a, cv, S, H, c, r.x + 70 * S, y + row, r.w - 86 * S)
		y += h + gap
	}
}

@(private = "file")
wow_unfold_h :: proc(m: ^Wow, S: int) -> int {
	if m.open < 0 || m.open >= len(m.chars) do return 0
	k := m.chars[m.open].key
	nl, nk := 0, 0
	for l in m.locks do if l.key == k do nl += 1
	for c in m.cds do if c.key == k do nk += 1
	return 18 * S + max(nl, nk, 5) * 18 * S + 14 * S
}

// The unfolded part: lockouts (a pip per boss), cooldowns, played, bags and professions.
@(private = "file")
wow_draw_unfold :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, c: Wow_Char, x, y, w: int) {
	m := WW(a)
	tn := msg_tones(a, H)
	colw := [3]int{w * 13 / 33, w * 10 / 33, w * 10 / 33}
	cx := x
	yy := y + 4 * S
	spaced(cv, m.f9b, fmt.tprintf("LOCKOUTS · RESET %s", wow_span(m.reset - m.now)), cx, yy, 12 * S, H.faint, S)
	ly := yy + 18 * S
	any := false
	for l in m.locks {
		if l.key != c.key do continue
		any = true
		lc := l.killed > 0 ? H.fg : H.dim
		text_in(cv, m.f11, ellipsize(m.f11, l.name, 130 * S), cx, ly, 16 * S, argb(lc, 0xff))
		px := cx + 138 * S
		for b in 0 ..< min(l.bosses, 16) { fill_rect(cv, px, ly + 3 * S, 7 * S, 10 * S, argb(b < l.killed ? WOW_ORANGE : H.line, 0xff)); px += 9 * S }
		text_in(cv, m.f11b, fmt.tprintf("%d/%d", l.killed, l.bosses), px + 6 * S, ly, 16 * S, argb(lc, 0xff))
		ly += 18 * S
	}
	if !any do text_in(cv, m.f11, "no raid lockouts yet", cx, ly, 16 * S, argb(H.dim, 0xff))
	cx += colw[0] + 16 * S
	spaced(cv, m.f9b, "COOLDOWNS", cx, yy, 12 * S, H.faint, S)
	ky := yy + 18 * S
	anyk := false
	for k in m.cds {
		if k.key != c.key do continue
		anyk = true
		ready := k.ready <= m.now
		t := ready ? "ready" : fmt.tprintf("in %s", wow_span(k.ready - m.now))
		text_in(cv, m.f11b, t, cx + colw[1] - tw(m.f11b, t), ky, 16 * S, argb(ready ? H.acc : H.dim, 0xff))
		text_in(cv, m.f11, ellipsize(m.f11, k.name, colw[1] - tw(m.f11b, t) - 10 * S), cx, ky, 16 * S, argb(tn.soft, 0xff))
		ky += 18 * S
	}
	if !anyk do text_in(cv, m.f11, "none tracked", cx, ky, 16 * S, argb(H.faint, 0xff))
	cx += colw[1] + 16 * S
	spaced(cv, m.f9b, "PLAYED", cx, yy, 12 * S, H.faint, S)
	py := yy + 18 * S
	text_in(cv, m.f11, c.played > 0 ? fmt.tprintf("%s total", wow_span(c.played)) : "—", cx, py, 16 * S, argb(tn.soft, 0xff))
	if c.plevel > 0 do text_in(cv, m.f11, fmt.tprintf("%s at level %d", wow_span(c.plevel), c.level), cx, py + 18 * S, 16 * S, argb(H.dim, 0xff))
	spaced(cv, m.f9b, "BAGS · PROFESSIONS", cx, py + 42 * S, 12 * S, H.faint, S)
	text_in(cv, m.f11, c.slots > 0 ? fmt.tprintf("%d free of %d", c.bags, c.slots) : fmt.tprintf("%d free", c.bags), cx, py + 60 * S, 16 * S, argb(tn.soft, 0xff))
	text_in(cv, m.f11, ellipsize(m.f11, c.profs != "" ? c.profs : "—", colw[2]), cx, py + 78 * S, 16 * S, argb(H.dim, 0xff))
}

// The addons: the field and Update all, the undo line, the key card, the rows.
@(private = "file")
wow_draw_addons :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: Wow_Rect) {
	m := WW(a)
	tn := msg_tones(a, H)
	lock: u8 = m.running ? 0x80 : 0xff
	y := r.y
	busy := panel_busy(&m.pn) && m.run.verb == "update"
	ul := busy ? "Updating…" : (m.nups > 0 ? fmt.tprintf("Update all · %d", m.nups) : "All up to date")
	uw := tw(m.f11b, ul) + tw(m.f11, "^U") + 36 * S
	ux := r.x + r.w - uw
	fh := 34 * S
	hot := m.nups > 0 && !busy && !m.running
	if hot do fill_rect(cv, ux, y, uw, fh, argb(H.acc, 0xff))
	rounded_rect(cv, ux, y, uw, fh, 0, 0, f32(S), argb(m.nups > 0 && !m.running ? H.acc : H.line, lock))
	text_in(cv, m.f11b, ul, ux + 14 * S, y, fh, argb(hot ? H.bg : tn.soft, lock))
	text_in(cv, m.f11, "^U", ux + 14 * S + tw(m.f11b, ul) + 8 * S, y, fh, argb(hot ? H.bg : H.dim, lock))
	hit_add(a, ux, y, uw, fh, .Chip, 2, 0)
	fw := ux - 8 * S - r.x
	fill_rect(cv, r.x, y, fw, fh, argb(H.panel, 0xff))
	rounded_rect(cv, r.x, y, fw, fh, 0, 0, f32(S), argb(m.field ? mix(H.bg, H.acc, 0.5) : H.line, lock))
	fill_rect(cv, r.x, y, 3 * S, fh, argb(H.acc, 0xff))
	text_in(cv, m.f13b, "›", r.x + 10 * S, y, fh, argb(H.acc, 0xff))
	q := string(m.q[:])
	qx := r.x + 10 * S + tw(m.f13b, "›") + 8 * S
	if q == "" do text_in(cv, m.f12, "Filter installed · ↵ searches Wago and CurseForge", qx, y, fh, argb(H.faint, 0xff))
	text_in(cv, m.f12, ellipsize(m.f12, q, fw - (qx - r.x) - 10 * S), qx, y, fh, argb(H.fg, 0xff))
	if m.field do fill_rect(cv, qx + (q != "" ? tw(m.f12, q) + S : 0), y + 9 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
	hit_add(a, r.x, y, fw, fh, .Chip, 9, 0)
	y += fh + 8 * S
	searching := wow_searching(m)
	if m.undo[0] != "" && !searching { // the last update, and its undo
		uh := 26 * S
		panel_dashed(cv, r.x, y, r.w, uh, S, argb(H.faint, 0xff))
		when_, _ := strconv.parse_i64(m.undo[3])
		ut := fmt.tprintf("Updated %s %s → %s · %s · the old copy is kept until the next update", m.undo[0], m.undo[1], m.undo[2], wow_ago(when_, m.now, false))
		text_in(cv, m.f10b, "^Z undo", r.x + r.w - 10 * S - tw(m.f10b, "^Z undo"), y, uh, argb(H.acc, 0xff))
		text_in(cv, m.f10, ellipsize(m.f10, ut, r.w - 30 * S - tw(m.f10b, "^Z undo")), r.x + 10 * S, y, uh, argb(tn.soft, 0xff))
		y += uh + 8 * S
	}
	if card := wow_keycard(m); card != "" { // a source without a key: where to get one, paste it here
		name := card == "curseforge" ? "CurseForge" : "Wago"
		how := card == "curseforge" ? "1 · Sign in at console.curseforge.com  2 · API keys › Generate  3 · Paste it here (^V), ↵ keeps it in the keyring." : "1 · Sign in at addons.wago.io  2 · Account › API keys  3 · Paste it here (^V), ↵ keeps it in the keyring."
		ch := 92 * S
		fill_rect(cv, r.x, y, r.w, ch, argb(tn.yellow, 0x0d))
		rounded_rect(cv, r.x, y, r.w, ch, 0, 0, f32(S), argb(tn.yellow, 0xff))
		fill_rect(cv, r.x, y, 3 * S, ch, argb(tn.yellow, 0xff))
		text_in(cv, m.f12b, fmt.tprintf("%s needs an API key to search", name), r.x + 14 * S, y + 10 * S, 18 * S, argb(tn.yellow, 0xff))
		text_in(cv, m.f11, ellipsize(m.f11, how, r.w - 28 * S), r.x + 14 * S, y + 32 * S, 17 * S, argb(tn.soft, 0xff))
		kx, ky, kw := r.x + 14 * S, y + 56 * S, r.w - 28 * S
		fill_rect(cv, kx, ky, kw, 28 * S, argb(H.bg, 0xff))
		rounded_rect(cv, kx, ky, kw, 28 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, m.f11, "API key", kx + 10 * S, ky, 28 * S, argb(H.dim, 0xff))
		shown := len(m.key) > 0 ? strings.repeat("•", min(len(m.key), 32), context.temp_allocator) : "paste with ^V"
		text_in(cv, m.f11, shown, kx + 80 * S, ky, 28 * S, argb(len(m.key) > 0 ? H.fg : H.faint, 0xff))
		text_in(cv, m.f10, "↵ save", kx + kw - 10 * S - tw(m.f10, "↵ save"), ky, 28 * S, argb(H.dim, 0xff))
		y += ch + 8 * S
	}
	rows := wow_addon_rows(m)
	rh := 44 * S
	// the rows before the picked one that do not fit go up
	skip := 0
	for skip < m.cur {
		used, kk := 0, 0
		for rw in rows {
			if rw.head == "" {
				if kk > m.cur do break
				if kk >= skip do used += rh
				kk += 1
			} else if kk >= skip do used += 22 * S
		}
		if used <= r.y + r.h - y do break
		skip += 1
	}
	k := 0
	for rw in rows {
		if rw.head != "" {
			if k >= skip { spaced(cv, m.f9b, rw.head, r.x + 4 * S, y + 6 * S, 14 * S, H.faint, S); y += 22 * S }
			continue
		}
		if k < skip { k += 1; continue }
		if y + rh > r.y + r.h do break
		on := k == m.cur && !m.field
		title, ver, by, desc, src, st, upd: string
		own := false
		if rw.hit {
			x := m.hits[rw.i]
			title, desc, src = x.name, x.summary, x.source
			installed := false
			for ad in m.addons do if wow_lower(ad.title) == wow_lower(x.name) do installed = true
			st = installed ? "installed" : "Install ↵"
		} else {
			x := m.addons[rw.i]
			title, ver, desc, src, upd = x.title, x.version, x.notes, x.source, x.update
			if x.author != "" do by = fmt.tprintf("by %s", x.author)
			own = src == "k4"
			switch {
			case own: st = "installed"
			case upd != "": st = fmt.tprintf("%s → %s", ver, upd); ver = ""
			case src == "": st = "can’t update"
			case: st = "up to date"
			}
			if busy && upd != "" do st = "updating…"
		}
		if on do fill_rect(cv, r.x, y, r.w, rh, argb(H.acc, 0x12))
		else if own do fill_rect(cv, r.x, y, r.w, rh, argb(H.acc, 0x08))
		if on || own do fill_rect(cv, r.x, y, 3 * S, rh, argb(H.acc, on ? 0xff : 0x66))
		if on do mark_sel(a, r.x, y, r.w, rh)
		fill_rect(cv, r.x, y + rh - S, r.w, S, argb(H.line, 0x66))
		hit_add(a, r.x, y, r.w, rh, .Row, k, 0)
		op: u8 = m.running && !own ? 0x8c : 0xff
		sc := H.faint
		srcl := "UNTRACKED"
		switch src {
		case "k4": sc, srcl = H.acc, "K4"
		case "wago": sc, srcl = a.theme.blue, "WAGO"
		case "github": sc, srcl = tn.soft, "GITHUB"
		case "curseforge": sc, srcl = 0xF16436, "CURSE"
		}
		ix := r.x + 12 * S
		iy := y + (rh - 26 * S) / 2
		ini := strings.to_upper(title[:min(len(title), 1)], context.temp_allocator)
		if len(title) > 1 do ini = strings.concatenate({ini, wow_lower(title[1:2])}, context.temp_allocator)
		if own {
			fill_rect(cv, ix, iy, 26 * S, 26 * S, argb(H.acc, 0xff))
			ini = "k4"
		} else {
			fill_rect(cv, ix, iy, 26 * S, 26 * S, argb(sc, 0x1a))
			rounded_rect(cv, ix, iy, 26 * S, 26 * S, 0, 0, f32(S), argb(sc, 0x66))
		}
		text_in(cv, m.f10b, ini, ix + (26 * S - tw(m.f10b, ini)) / 2, iy, 26 * S, argb(own ? H.bg : sc, op))
		// the status chip and the source tag at the right
		stw := (m.popup ? 84 : 130) * S
		chx := r.x + r.w - 12 * S - stw
		cw := min(tw(m.f10b, st) + 14 * S, stw)
		cx := chx + stw - cw
		chip_fg, chip_bg, chip_bd := H.dim, u32(0), u32(0)
		switch {
		case st == "installed": chip_fg, chip_bd = tn.green, mix(H.bg, tn.green, 0.5)
		case st == "Install ↵" || (upd != "" && !busy): chip_fg, chip_bg, chip_bd = H.bg, H.acc, H.acc
		case st == "updating…": chip_fg, chip_bd = H.acc, H.acc
		case st == "can’t update": chip_fg = H.faint
		}
		if chip_bg != 0 do fill_rect(cv, cx, y + (rh - 18 * S) / 2, cw, 18 * S, argb(chip_bg, op))
		if chip_bd != 0 do rounded_rect(cv, cx, y + (rh - 18 * S) / 2, cw, 18 * S, 0, 0, f32(S), argb(chip_bd, op))
		text_in(cv, m.f10b, ellipsize(m.f10b, st, cw - 14 * S), cx + 7 * S, y + (rh - 18 * S) / 2, 18 * S, argb(chip_fg, op))
		slw := tw(m.f9b, srcl) + 10 * S
		sx := chx - 10 * S - slw
		rounded_rect(cv, sx, y + (rh - 14 * S) / 2, slw, 14 * S, 0, 0, f32(S), argb(mix(H.bg, sc, 0.5), op))
		text_in(cv, m.f9b, srcl, sx + 5 * S, y + (rh - 14 * S) / 2, 14 * S, argb(sc, op))
		tx := ix + 26 * S + 12 * S
		tl := ellipsize(m.f12b, title, sx - 10 * S - tx)
		text_in(cv, m.f12b, tl, tx, y + 6 * S, 17 * S, argb(H.fg, op))
		vx := tx + tw(m.f12b, tl) + 8 * S
		meta := strings.trim_space(strings.join({ver, by}, "  ", context.temp_allocator))
		if vx < sx - 20 * S do text_in(cv, m.f10, ellipsize(m.f10, meta, sx - 10 * S - vx), vx, y + 6 * S, 17 * S, argb(H.dim, op))
		text_in(cv, m.f10, ellipsize(m.f10, desc, sx - 10 * S - tx), tx, y + 23 * S, 15 * S, argb(H.dim, op))
		y += rh
		k += 1
	}
	if len(rows) == 0 {
		e := len(m.addons) == 0 ? "No addons yet · type a name and ↵ to search Wago and CurseForge" : fmt.tprintf("Nothing installed matches “%s” · ↵ searches Wago and CurseForge", q)
		text_in(cv, m.f12, e, r.x + 6 * S, y + 20 * S, 18 * S, argb(H.dim, 0xff))
	}
}

// The raid nights: day and time, the raid, when; the line to add one.
@(private = "file")
wow_draw_raids :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, r: Wow_Rect) {
	m := WW(a)
	tn := msg_tones(a, H)
	y := r.y
	rh := 52 * S
	for x, i in m.raids {
		if y + rh > r.y + r.h - 50 * S do break
		on := i == m.cur
		fill_rect(cv, r.x, y, r.w, rh, argb(on ? mix(H.bg, H.acc, 0.06) : H.panel, 0xff))
		rounded_rect(cv, r.x, y, r.w, rh, 0, 0, f32(S), argb(on ? mix(H.bg, H.acc, 0.5) : H.line, 0xff))
		fill_rect(cv, r.x, y, 3 * S, rh, argb(WOW_ORANGE, 0xff))
		if on do mark_sel(a, r.x, y, r.w, rh)
		hit_add(a, r.x, y, r.w, rh, .Row, i, 0)
		day := wow_day(x.next, true)
		text_in(cv, m.f10, day, r.x + 12 * S + (64 * S - tw(m.f10, day)) / 2, y + 8 * S, 14 * S, argb(H.dim, 0xff))
		text_in(cv, m.f15b, x.time, r.x + 12 * S + (64 * S - tw(m.f15b, x.time)) / 2, y + 22 * S, 22 * S, argb(H.fg, 0xff))
		nx := r.x + 12 * S + 64 * S + 14 * S
		when_ := fmt.tprintf("in %s", wow_span(x.next - m.now))
		text_in(cv, m.f10, when_, r.x + r.w - 12 * S - tw(m.f10, when_), y, rh, argb(i == 0 ? WOW_ORANGE : H.dim, 0xff))
		text_in(cv, m.f13b, ellipsize(m.f13b, x.name, r.x + r.w - 30 * S - tw(m.f10, when_) - nx), nx, y + 9 * S, 18 * S, argb(H.fg, 0xff))
		text_in(cv, m.f10, fmt.tprintf("every %s · Del removes", x.day), nx, y + 29 * S, 14 * S, argb(H.dim, 0xff))
		y += rh + 8 * S
	}
	// the line to add one (typing)
	q := string(m.q[:])
	lh := 40 * S
	panel_dashed(cv, r.x, y, r.w, lh, S, argb(len(q) > 0 ? H.acc : H.faint, 0xff))
	if q != "" {
		text_in(cv, m.f12, q, r.x + 12 * S, y, lh, argb(H.fg, 0xff))
		fill_rect(cv, r.x + 12 * S + tw(m.f12, q) + S, y + 12 * S, 2 * S, 16 * S, argb(H.acc, 0xff))
		text_in(cv, m.f10, "↵ adds it", r.x + r.w - 12 * S - tw(m.f10, "↵ adds it"), y, lh, argb(H.acc, 0xff))
	} else do text_in(cv, m.f11, ellipsize(m.f11, "Type “thu 20:00 mc” to add one. Raid nights show in the bar’s calendar, and 15 min before you get a card with Launch WoW.", r.w - 24 * S), r.x + 12 * S, y, lh, argb(tn.soft, 0xff))
}

// A card for the whole window: not installed, never played.
@(private = "file")
wow_draw_card :: proc(a: ^App, cv: ^Canvas, S: int, H: HUD, x, y, w, h: int, view: string) {
	m := WW(a)
	tn := msg_tones(a, H)
	title, line: string
	steps: []string
	acts: [2][2]string
	if view == "notinstalled" {
		title, line = "World of Warcraft isn’t installed here", "k4 looks for the game in Battle.net (under umu, in ~/Games/battlenet). Install Forever there, then this fills in."
		acts = {{"Open Battle.net", "↵"}, {}}
	} else {
		title, line = "No characters yet", "Characters show here after you log in once with the k4 Companion addon on. It writes a small file when you log out or /reload."
		steps = {m.companion ? "The companion is installed · ✓" : "Install the companion addon (↵)", "Start WoW and log in to each character once", "Log out or type /reload · k4 picks it up within a few seconds"}
		acts = {{m.companion ? "Play" : "Install the companion", m.companion ? "↵ ^P" : "↵"}, {"Addons", "a"}}
	}
	cw := min(560 * S, w - 40 * S)
	iw := cw - 40 * S
	ls := wrap_text(m.f11, line, iw)
	ch := 18 * S + 20 * S + 12 * S + len(ls) * 17 * S + (len(steps) > 0 ? 12 * S + len(steps) * 24 * S : 0) + 12 * S + 28 * S + 18 * S
	cx, cy := x + (w - cw) / 2, y + max((h - ch) / 2, 12 * S)
	fill_rect(cv, cx, cy, cw, ch, argb(H.acc, 0x0d))
	rounded_rect(cv, cx, cy, cw, ch, 0, 0, f32(S), argb(H.acc, 0xff))
	fill_rect(cv, cx, cy, 3 * S, ch, argb(H.acc, 0xff))
	yy := cy + 18 * S
	text_in(cv, m.f13b, title, cx + 20 * S, yy, 20 * S, argb(H.acc, 0xff))
	yy += 20 * S + 12 * S
	for l in ls { text_in(cv, m.f11, l, cx + 20 * S, yy, 17 * S, argb(tn.soft, 0xff)); yy += 17 * S }
	if len(steps) > 0 {
		yy += 12 * S
		for s, i in steps {
			n := fmt.tprint(i + 1)
			text_in(cv, m.f11b, n, cx + 38 * S - tw(m.f11b, n), yy, 17 * S, argb(H.acc, 0xff))
			text_in(cv, m.f11, s, cx + 48 * S, yy, 17 * S, argb(tn.soft, 0xff))
			yy += 24 * S
		}
	}
	yy += 12 * S
	bx := cx + 20 * S
	for b, i in acts {
		if b[0] == "" do continue
		bx += panel_btn(a, cv, S, bx, yy, 28 * S, H, b[0], b[1], i == 0 ? .Prime : .Plain, i) + 6 * S
	}
}

wow_dump :: proc(a: ^App) -> string {
	m := WW(a)
	sb := strings.builder_make(context.temp_allocator)
	gold: i64 = 0
	for c in m.chars do gold += c.gold
	fmt.sbprintfln(&sb, "wow %s · %v · %d characters · %s · reset in %s%s", m.state, m.tab, len(m.chars), wow_money(gold), wow_span(m.reset - m.now), m.running ? " · playing" : "")
	if v := wow_view(m); v != "main" {
		fmt.sbprintfln(&sb, "card %s", v)
		panel_dump_toast(&m.pn, &sb)
		return strings.to_string(sb)
	}
	for r in m.realms do fmt.sbprintfln(&sb, "realm %s %s%s", r.name, r.status, r.queue ? " queue" : "")
	if m.token > 0 do fmt.sbprintfln(&sb, "token %s", wow_money(m.token))
	if m.why != "" do fmt.sbprintfln(&sb, "why %s", m.why)
	if !m.companion && len(m.chars) > 0 do fmt.sbprintln(&sb, "banner companion missing")
	if m.running && m.tab == .Addons do fmt.sbprintln(&sb, "banner close WoW first")
	switch m.tab {
	case .Chars:
		for c, i in m.chars {
			fmt.sbprintfln(&sb, "%s %s %d %s · %s%s", i == m.cur ? "*" : " ", c.name, c.level, c.cname, wow_money(c.gold), c.rested >= 0 ? fmt.tprintf(" · rested %d%%", c.rested) : "")
			if i == m.open {
				for l in m.locks do if l.key == c.key do fmt.sbprintfln(&sb, "    lockout %s %d/%d", l.name, l.killed, l.bosses)
				for k in m.cds do if k.key == c.key do fmt.sbprintfln(&sb, "    cooldown %s · %s", k.name, k.ready <= m.now ? "ready" : wow_span(k.ready - m.now))
				fmt.sbprintfln(&sb, "    bags %d free of %d · %s", c.bags, c.slots, c.profs)
			}
		}
	case .Addons:
		if len(m.q) > 0 do fmt.sbprintfln(&sb, "%sfind %s", m.field ? "* " : "", string(m.q[:]))
		if c := wow_keycard(m); c != "" do fmt.sbprintfln(&sb, "keycard %s%s", c, len(m.key) > 0 ? " (pasted)" : "")
		if m.undo[0] != "" && !wow_searching(m) do fmt.sbprintfln(&sb, "undo %s %s → %s", m.undo[0], m.undo[1], m.undo[2])
		k := 0
		for rw in wow_addon_rows(m) {
			if rw.head != "" { fmt.sbprintfln(&sb, "  %s", rw.head); continue }
			mark := k == m.cur && !m.field ? "*" : " "
			if rw.hit {
				x := m.hits[rw.i]
				fmt.sbprintfln(&sb, "%s %s · %s · install", mark, x.name, x.source)
			} else {
				x := m.addons[rw.i]
				fmt.sbprintfln(&sb, "%s %s %s · %s%s", mark, x.title, x.version, x.source != "" ? x.source : "untracked", x.update != "" ? fmt.tprintf(" → %s", x.update) : "")
			}
			k += 1
		}
	case .Raids:
		for x, i in m.raids do fmt.sbprintfln(&sb, "%s %s %s %s · in %s", i == m.cur ? "*" : " ", x.day, x.time, x.name, wow_span(x.next - m.now))
		if len(m.q) > 0 do fmt.sbprintfln(&sb, "new %s", string(m.q[:]))
	}
	panel_dump_toast(&m.pn, &sb)
	return strings.to_string(sb)
}
