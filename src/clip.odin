package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// --clip: the clipboard history (the Kestrel design's Clipboard, Super+Ctrl+V). 980×600: a
// search field and All / Text / Blocks / Images, the history (pinned, today, earlier) beside a
// preview of the picked entry and its actions. ↑↓ (^J ^K, PgUp PgDn) move, Tab the filter,
// typing searches, ↵ pastes it into the window k4 came from, ⇧↵ copies, ^↵ pastes plain text /
// opens a block in the editor / saves an image, ^S sends it to a nearby device (LocalSend), ^P
// pins, Del (^D) deletes, Alt+1–9 pastes the
// nth unpinned one, Esc clears the search, then closes. The entries come on stdin:
//   S <recording 1|0>        R <command>: runs "VERB ID" in place (pin, delete; its output
//   L <command>: the list again        is the footer's message)
//   E <id> <unix time> <pinned 1|0> <text|block|image> <label> <lines> <chars> <image file> <body>
//     [<app> <secret 1|0>]
// (the body's lines joined by \x1f). Each row names the app it was copied from. A secret (from a
// password manager) shows masked, "expires in 12 s", and is gone from the list after that (k4-clip
// watch takes it out of the history). Colours (#rgb, #rrggbb, rgb(), hsl()) get a swatch.
// Paste, copy and extra close k4 and print "VERB\tID".

CLIP_W, CLIP_H :: 980, 600

Clip_Entry :: struct {
	id, label, image, body, app: string,
	at: i64,
	pinned, secret: bool,
	kind: int, // 0 text, 1 block, 2 image
	lines, chars: int,
}

Clip :: struct {
	all: [dynamic]Clip_Entry,
	vis: [dynamic]int, // shown, pinned first
	recording: bool,
	runner, loader: string,
	tab, cur, scroll: int,
	toast: string,
	f9b, f10, f10b, f11, f11b, f12, f12b, f13b, f15, f16, f16b: ^Font,
}

clip_setup :: proc(a: ^App, data: string) {
	c := new(Clip)
	a.clip = c
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	c.f10, c.f11, c.f12, c.f15, c.f16 = reg(a, 10), reg(a, 11), reg(a, 12), reg(a, 15), reg(a, 16)
	c.f9b, c.f10b, c.f11b, c.f12b, c.f13b, c.f16b = bld(a, 9), bld(a, 10), bld(a, 11), bld(a, 12), bld(a, 13), bld(a, 16)
	clip_parse(c, data)
	clip_filter(a)
}

@(private = "file")
clip_parse :: proc(c: ^Clip, data: string) {
	clear(&c.all)
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		get :: proc(f: []string, i: int) -> string {
			if i >= len(f) do return ""
			s, _ := strings.replace_all(f[i], "\\\\", "\\", context.temp_allocator) // jq's @tsv
			return s
		}
		switch f[0] {
		case "S": c.recording = get(f, 1) == "1"
		case "R": c.runner = strings.clone(get(f, 1))
		case "L": c.loader = strings.clone(get(f, 1))
		case "E":
			e := Clip_Entry{id = strings.clone(get(f, 1)), pinned = get(f, 3) == "1", label = strings.clone(get(f, 5)), image = strings.clone(get(f, 8))}
			e.at, _ = strconv.parse_i64(get(f, 2))
			switch get(f, 4) { case "block": e.kind = 1; case "image": e.kind = 2 }
			e.lines, _ = strconv.parse_int(get(f, 6))
			e.chars, _ = strconv.parse_int(get(f, 7))
			b, _ := strings.replace_all(get(f, 9), "\x1f", "\n", context.temp_allocator)
			e.body = strings.clone(b)
			e.app, e.secret = strings.clone(get(f, 10)), get(f, 11) == "1"
			if e.secret { // never drawn: paste and copy go by its id
				delete(e.label); delete(e.body)
				e.label, e.body, e.kind, e.lines = strings.clone("••••••••••"), strings.clone("••••••••••"), 0, 1
			}
			append(&c.all, e)
		}
	}
}

CLIP_SECRET_S :: 12 // a secret leaves the history this long after its copy

@(private = "file")
clip_now :: proc() -> i64 {
	if v := os.get_env("K4_CLIP_NOW", context.temp_allocator); v != "" do if now, ok := strconv.parse_i64(v); ok do return now
	return time.to_unix_seconds(time.now())
}

// A secret's seconds left in the history; 0 once it is gone.
@(private = "file")
clip_left :: proc(e: Clip_Entry) -> i64 { return e.secret ? max(e.at + CLIP_SECRET_S - clip_now(), 0) : -1 }

// While a secret counts down, the window ticks every second; at 0 it leaves the list.
clip_tick_ms :: proc(a: ^App) -> int {
	for e in a.clip.all do if clip_left(e) > 0 do return 1000
	return -1
}

clip_tick :: proc(a: ^App) { clip_filter(a) }

@(private = "file")
clip_query :: proc(a: ^App) -> string { return strings.to_lower(strings.trim_space(string(a.query[:])), context.temp_allocator) }

@(private = "file")
clip_kind_ok :: proc(tab, kind: int) -> bool { return tab == 0 || tab - 1 == kind }

// What shows: the tab's kind, the search in the label and the text; pinned first.
clip_filter :: proc(a: ^App) {
	c := a.clip
	keep := c.cur < len(c.vis) ? c.all[c.vis[c.cur]].id : ""
	clear(&c.vis)
	q := clip_query(a)
	for pass in 0 ..< 2 do for e, i in c.all {
		if e.pinned != (pass == 0) || !clip_kind_ok(c.tab, e.kind) || clip_left(e) == 0 do continue
		if e.secret && q != "" do continue // a secret is never found by what it says
		if q != "" && !strings.contains(strings.to_lower(e.label, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.body, context.temp_allocator), q) do continue
		append(&c.vis, i)
	}
	c.cur = 0
	for v, k in c.vis do if c.all[v].id == keep { c.cur = k; break }
}

@(private = "file")
clip_sel :: proc(c: ^Clip) -> (^Clip_Entry, bool) {
	if c.cur < 0 || c.cur >= len(c.vis) do return nil, false
	return &c.all[c.vis[c.cur]], true
}

// Closes k4: the script pastes, copies or opens it.
@(private = "file")
clip_done :: proc(a: ^App, verb: string) {
	e, ok := clip_sel(a.clip)
	if !ok do return
	a.result = strings.concatenate({verb, "\t", e.id})
	a.exit = 0
	a.done = true
}

// In place (pin, delete): the runner, then the list again.
@(private = "file")
clip_stay :: proc(a: ^App, verb: string) {
	c := a.clip
	e, ok := clip_sel(c)
	if !ok do return
	if c.runner == "" { c.toast = fmt.aprintf("(%s %s)", verb, e.id); return } // tests
	_, out, _, _ := os.process_exec({command = {"sh", "-c", fmt.tprintf("%s %s %s", c.runner, verb, sh_quote(e.id))}}, context.temp_allocator)
	c.toast = strings.clone(strings.trim_space(string(out)))
	if c.loader != "" {
		_, list, _, err := os.process_exec({command = {"sh", "-c", c.loader}}, context.temp_allocator)
		if err == nil {
			keep := c.cur
			clip_parse(c, string(list))
			clip_filter(a)
			c.cur = clamp(keep, 0, max(len(c.vis) - 1, 0))
		}
	}
}

clip_key :: proc(a: ^App, k: Key, ctrl, alt: bool, ch: rune, text: string) -> bool {
	c := a.clip
	n := len(c.vis)
	move :: proc(c: ^Clip, d, n: int) { c.cur, c.toast = clamp(c.cur + d, 0, max(n - 1, 0)), "" }
	switch {
	case k == .Escape:
		if len(a.query) > 0 { clear(&a.query); a.cursor = 0; clip_filter(a) } else { a.exit = 1; a.done = true }
	case k == .Down || ctrl && ch == 'j': move(c, 1, n)
	case k == .Up || ctrl && ch == 'k': move(c, -1, n)
	case k == .Page_Down: move(c, 6, n)
	case k == .Page_Up: move(c, -6, n)
	case k == .Tab: c.tab, c.toast = (c.tab + 1) % 4, ""; clip_filter(a)
	case k == .Back_Tab: c.tab, c.toast = (c.tab + 3) % 4, ""; clip_filter(a)
	case k == .Enter && ctrl: if e, ok := clip_sel(c); ok { if e.kind == 0 do clip_done(a, "plain"); else do clip_done(a, "extra") }
	case k == .Enter && a.shift: clip_done(a, "copy")
	case k == .Enter: clip_done(a, "paste")
	case ctrl && ch == 'p': clip_stay(a, "pin")
	case ctrl && ch == 's': clip_done(a, "send") // over LocalSend: the Send page with this entry
	case ctrl && ch == 'd', k == .Delete: clip_stay(a, "delete")
	case alt && ch >= '1' && ch <= '9':
		want, seen := int(ch - '0'), 0
		for v, i in c.vis do if !c.all[v].pinned {
			seen += 1
			if seen == want { c.cur = i; clip_done(a, "paste"); break }
		}
	case ctrl && (ch == 'c' || ch == 'g'): a.exit = 1; a.done = true
	case:
		before := string(a.query[:])
		before = strings.clone(before, context.temp_allocator)
		r := app_edit_key(a, k, ctrl, ch, text)
		if string(a.query[:]) != before do clip_filter(a)
		return r
	}
	return true
}

clip_click :: proc(a: ^App, x, y, button: int) -> bool {
	c := a.clip
	h, ok := hit_at(a, x, y)
	if !ok { a.exit = 1; a.done = true; return true }
	#partial switch h.kind {
	case .Row:
		if c.cur == h.a do clip_done(a, "paste")
		else do c.cur, c.toast = h.a, ""
	case .Tab: c.tab = h.a; clip_filter(a)
	case .Chip:
		switch h.a {
		case 0: clip_done(a, "paste")
		case 1: clip_done(a, "copy")
		case 2: if e, ok2 := clip_sel(c); ok2 { if e.kind == 0 do clip_done(a, "plain"); else do clip_done(a, "extra") }
		case 3: clip_stay(a, "pin")
		case 4: clip_stay(a, "delete")
		case 5: clip_done(a, "send")
		}
	}
	return true
}

clip_scroll :: proc(a: ^App, n: int) -> bool {
	c := a.clip
	c.cur = clamp(c.cur + n, 0, max(len(c.vis) - 1, 0))
	return true
}

// ---------- the look ----------

@(private = "file")
clip_ago :: proc(at: i64) -> string {
	d := clip_now() - at
	switch {
	case d < 60: return fmt.tprintf("%d s", max(d, 0))
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 86400: return fmt.tprintf("%d h", d / 3600)
	case d < 2 * 86400: return "yesterday"
	case d < 7 * 86400: return fmt.tprintf("%d d", d / 86400)
	}
	return fmt.tprintf("%d w", d / (7 * 86400))
}

// A block's language, guessed from how it starts.
@(private = "file")
clip_lang :: proc(body: string) -> string {
	s := strings.trim_left_space(body)
	first := s
	if i := strings.index_byte(s, '\n'); i >= 0 do first = s[:i]
	switch {
	case strings.has_prefix(s, "{") || strings.has_prefix(s, "["): return "JSON"
	case strings.has_prefix(s, "#!") && strings.contains(first, "python"): return "Python"
	case strings.has_prefix(s, "#!"): return "shell"
	case strings.has_prefix(s, "def ") || strings.has_prefix(s, "import ") || strings.has_prefix(s, "from "): return "Python"
	case strings.has_prefix(s, "Host "): return "ssh config"
	case strings.contains(s, "bindsym ") || strings.has_prefix(s, "set $"): return "sway config"
	case strings.contains(first, " :: proc") || strings.has_prefix(s, "package "): return "Odin"
	case strings.has_prefix(s, "fn ") || strings.has_prefix(s, "use "): return "Rust"
	case strings.has_prefix(s, "<"): return "markup"
	case strings.has_prefix(s, "$ ") || strings.has_prefix(s, "sudo ") || strings.has_prefix(s, "git "): return "shell"
	}
	return "text"
}

// A colour the text is: #rgb, #rrggbb, #rrggbbaa, rgb()/rgba() or hsl()/hsla() (the alpha dropped).
@(private = "file")
clip_hex :: proc(s: string) -> (u32, bool) {
	t := strings.to_lower(strings.trim_space(s), context.temp_allocator)
	if len(t) > 1 && t[0] == '#' {
		h := t[1:]
		for ch in h do if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') do return 0, false
		switch len(h) {
		case 3:
			v, _ := strconv.parse_u64_of_base(h, 16)
			r, g, b := u32(v >> 8 & 0xf), u32(v >> 4 & 0xf), u32(v & 0xf)
			return (r * 17) << 16 | (g * 17) << 8 | b * 17, true
		case 6, 8:
			v, _ := strconv.parse_u64_of_base(h[:6], 16)
			return u32(v), true
		}
		return 0, false
	}
	fn := ""
	for p in ([]string{"rgba(", "rgb(", "hsla(", "hsl("}) do if strings.has_prefix(t, p) { fn = p; break }
	if fn == "" || !strings.has_suffix(t, ")") do return 0, false
	inner, _ := strings.replace_all(t[len(fn):len(t) - 1], ",", " ", context.temp_allocator)
	inner, _ = strings.replace_all(inner, "/", " ", context.temp_allocator)
	parts := strings.fields(inner, context.temp_allocator)
	if len(parts) < 3 || len(parts) > 4 do return 0, false
	n: [3]f64
	for i in 0 ..< 3 {
		x := strings.trim_suffix(strings.trim_suffix(parts[i], "%"), "deg")
		v, ok := strconv.parse_f64(x)
		if !ok do return 0, false
		n[i] = v
		if fn[0] == 'r' && strings.has_suffix(parts[i], "%") do n[i] = v * 2.55
	}
	c8 :: proc(v: f64) -> u32 { return u32(clamp(v + 0.5, 0, 255)) }
	if fn[0] == 'r' do return c8(n[0]) << 16 | c8(n[1]) << 8 | c8(n[2]), true
	// hsl: hue in degrees, saturation and lightness in percent
	h := n[0] - 360 * f64(int(n[0] / 360)); if h < 0 do h += 360
	sat, l := clamp(n[1], 0, 100) / 100, clamp(n[2], 0, 100) / 100
	ch := (1 - abs(2 * l - 1)) * sat
	x := ch * (1 - abs(h / 60 - 2 * f64(int(h / 120)) - 1))
	m := l - ch / 2
	r, g, b: f64
	switch {
	case h < 60: r, g = ch, x
	case h < 120: r, g = x, ch
	case h < 180: g, b = ch, x
	case h < 240: g, b = x, ch
	case h < 300: r, b = x, ch
	case: r, b = ch, x
	}
	return c8((r + m) * 255) << 16 | c8((g + m) * 255) << 8 | c8((b + m) * 255), true
}

@(private = "file")
clip_kc :: proc(a: ^App, e: Clip_Entry, H: HUD) -> u32 {
	switch e.kind {
	case 1: return a.theme.blue
	case 2: return a.theme.magenta
	}
	return H.acc
}

@(private = "file")
clip_meta :: proc(e: Clip_Entry) -> string {
	from := e.app != "" ? fmt.tprintf(" · from %s", e.app) : ""
	if e.secret do return fmt.tprintf("secret%s · expires in %d s", from, clip_left(e))
	return strings.concatenate({clip_meta_kind(e), from}, context.temp_allocator)
}

@(private = "file")
clip_meta_kind :: proc(e: Clip_Entry) -> string {
	switch e.kind {
	case 1: return fmt.tprintf("%s · %d lines · %s", clip_lang(e.body), e.lines, clip_ago(e.at))
	case 2:
		size := ""
		if fi, err := os.stat(e.image, context.temp_allocator); err == nil do size = fi.size > 1 << 20 ? fmt.tprintf("%.1f MB · ", f64(fi.size) / f64(1 << 20)) : fmt.tprintf("%d KB · ", fi.size / 1024)
		return fmt.tprintf("%s%s", size, clip_ago(e.at))
	}
	return fmt.tprintf("%s · %s", plural_n(e.chars, "char"), clip_ago(e.at))
}

@(private = "file")
secs_today :: proc() -> i64 {
	hms := libc_now_hms()
	p := strings.split(hms, ":", context.temp_allocator)
	if len(p) < 3 do return 0
	h, _ := strconv.parse_i64(p[0]); m, _ := strconv.parse_i64(p[1]); s, _ := strconv.parse_i64(p[2])
	return h * 3600 + m * 60 + s
}

clip_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	c := a.clip
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	canvas_clear(cv)
	w, h := cv.w, cv.h
	fill_rect(cv, 0, 0, w, h, argb(H.bg, a.bg_alpha))
	q := clip_query(a)
	hh := 64 * S
	fh := 30 * S
	fy := h - fh
	labels := [4]string{"All", "Text", "Blocks", "Images"}
	// the list
	top := hh + S
	lw := 420 * S
	fill_rect(cv, lw, top, S, fy - top, argb(H.line, 0xff))
	lh := fy - top
	if len(c.vis) == 0 {
		t1 := len(c.all) == 0 ? "Nothing copied yet" : "No matches"
		t2 := len(c.all) == 0 ? "Copy text, code or an image and it shows up here." : fmt.tprintf("Nothing in %s matches “%s”. Tab switches the filter.", strings.to_lower(labels[c.tab], context.temp_allocator), string(a.query[:]))
		text_in(cv, c.f12b, t1, (lw - tw(c.f12b, t1)) / 2, top + 60 * S, 20 * S, argb(H.fg, 0xff))
		ly := top + 90 * S
		for l in wrap_text(c.f11, t2, lw - 60 * S) { text_in(cv, c.f11, l, (lw - tw(c.f11, l)) / 2, ly, 17 * S, argb(H.dim, 0xff)); ly += 17 * S }
	} else {
		// the rows' places: group heads where the group changes
		today := time.to_unix_seconds(time.now()) - secs_today()
		Place :: struct { y, i: int, head: string }
		places := make([dynamic]Place, 0, len(c.vis) * 2, context.temp_allocator)
		yy := 6 * S
		last := ""
		cur_y := 0
		for v, i in c.vis {
			e := c.all[v]
			g := e.pinned ? "PINNED" : (e.at >= today ? "TODAY" : "EARLIER")
			if g != last { append(&places, Place{yy, -1, g}); yy += 12 * S + int(c.f10b.line_h) + 5 * S; last = g }
			if i == c.cur do cur_y = yy
			append(&places, Place{yy, i, ""})
			yy += 52 * S
		}
		total := yy + 10 * S
		if cur_y - 30 * S < c.scroll do c.scroll = max(cur_y - 30 * S, 0)
		if cur_y + 52 * S > c.scroll + lh do c.scroll = cur_y + 52 * S - lh + 6 * S
		c.scroll = clamp(c.scroll, 0, max(total - lh, 0))
		list := Canvas{cv.px[top * cv.w:], cv.w, lh}
		nh := len(a.hits)
		n := 0
		keys := make(map[int]int, 16, context.temp_allocator)
		for v, i in c.vis do if !c.all[v].pinned { n += 1; if n <= 9 do keys[i] = n }
		for p in places {
			y := p.y - c.scroll
			if y + 52 * S < 0 || y > lh do continue
			if p.i < 0 { spaced(&list, c.f10b, p.head, 20 * S, y + 12 * S, int(c.f10b.line_h), H.dim, S); continue }
			clip_row(a, &list, S, p.i, y, lw, keys[p.i], H, soft, q)
		}
		for &hh2 in a.hits[nh:] {
			hh2.y += top
			y0, y1 := max(hh2.y, top), min(hh2.y + hh2.h, fy)
			hh2.y, hh2.h = y0, max(y1 - y0, 0)
		}
		if a.sel != {} do a.sel[1] += top
	}
	// the preview
	if e, ok := clip_sel(c); ok do clip_preview(a, cv, S, lw + S, top, w - lw - S, fy - top, e^, H, soft)
	// the head and the foot over rows cut at the list's edges
	for i in 0 ..< (hh + S) * w do cv.px[i] = 0
	for i in fy * w ..< h * w do cv.px[i] = 0
	fill_rect(cv, 0, 0, w, hh + S, argb(H.bg, a.bg_alpha))
	fill_rect(cv, 0, fy, w, h - fy, argb(H.bg, a.bg_alpha))
	// the head: CLIPBOARD / recording · the search · the filters
	px := 24 * S
	ty := (hh - int(c.f13b.line_h) - 3 * S - int(c.f10.line_h)) / 2
	spaced(cv, c.f13b, "CLIPBOARD", px, ty, int(c.f13b.line_h), H.acc, 2 * S, true)
	rec := c.recording ? "● recording · Super+Ctrl+V" : "● not recording · clipse -listen"
	text_in(cv, c.f10, rec, px, ty + int(c.f13b.line_h) + 3 * S, int(c.f10.line_h), argb(c.recording ? H.dim : t.yellow, 0xff))
	px += max(spaced_w(c.f13b, "CLIPBOARD", 2 * S), tw(c.f10, rec)) + 20 * S
	counts: [4]int
	for e in c.all { counts[0] += 1; counts[e.kind + 1] += 1 }
	tabs_w := 0
	for l, i in labels do tabs_w += tw(c.f11b, l) + 6 * S + tw(c.f11, fmt.tprint(counts[i])) + 18 * S + 4 * S
	tx := w - 24 * S - tabs_w + 4 * S
	for l, i in labels {
		on := i == c.tab
		n := fmt.tprint(counts[i])
		bw := tw(c.f11b, l) + 6 * S + tw(c.f11, n) + 18 * S
		by := (hh - 28 * S) / 2
		if on do fill_rect(cv, tx, by, bw, 28 * S, argb(H.acc, 0x1a))
		rounded_rect(cv, tx, by, bw, 28 * S, 0, 0, f32(S), argb(on ? H.acc : H.line, 0xff))
		text_in(cv, c.f11b, l, tx + 9 * S, by, 28 * S, argb(on ? H.fg : H.dim, 0xff))
		text_in(cv, c.f11, n, tx + 9 * S + tw(c.f11b, l) + 6 * S, by, 28 * S, argb(on ? H.acc : H.faint, 0xff))
		hit_add(a, tx, by, bw, 28 * S, .Tab, i, 0)
		tx += bw + 4 * S
	}
	bx, bw := px, w - 24 * S - tabs_w - 20 * S - px
	bh := 36 * S
	by := (hh - bh) / 2
	fill_rect(cv, bx, by, bw, bh, argb(t.fg, 0x0a))
	rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(S), argb(H.line, 0xff))
	fill_rect(cv, bx, by, 3 * S, bh, argb(H.acc, 0xff))
	text_in(cv, c.f16b, "›", bx + 12 * S, by, bh, argb(H.acc, 0xff))
	count := q != "" ? fmt.tprintf("%d of %d", len(c.vis), len(c.all)) : fmt.tprintf("%d entries", len(c.all))
	cw := tw(c.f11, count)
	text_in(cv, c.f11, count, bx + bw - 12 * S - cw, by, bh, argb(H.dim, 0xff))
	qx := bx + 12 * S + tw(c.f16b, "›") + 10 * S
	qt := string(a.query[:])
	if qt == "" do text_in(cv, c.f15, "Search history…", qx, by, bh, argb(H.hint, 0xff), bx + bw - 24 * S - cw)
	else do text_in(cv, c.f15, qt, qx, by, bh, argb(H.fg, 0xff), bx + bw - 24 * S - cw)
	qs := shape(c.f15, qt)
	cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	fill_rect(cv, qx + int(qs.cp_x[min(cp, len(qs.cp_x) - 1)]), by + (bh - int(c.f15.line_h)) / 2, max(S, 2), int(c.f15.line_h), argb(H.acc, 0xff))
	fill_rect(cv, 0, hh, w, S, argb(H.line, 0xff))
	// the foot: hints · what just happened
	fill_rect(cv, 0, fy, w, S, argb(H.line, 0xff))
	hx := 24 * S
	for k in ([][2]string{{"↑↓", "Move"}, {"↵", "Paste"}, {"⇧↵", "Copy"}, {"Tab", "Filter"}, {"Alt 1–9", "Quick paste"}, {"Esc", "Close"}}) {
		kw := tw(c.f10, k[0]) + 8 * S
		rounded_rect(cv, hx, fy + (fh - 15 * S) / 2, kw, 15 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, c.f10, k[0], hx + 4 * S, fy, fh, argb(H.fg, 0xff))
		hx += kw + 5 * S
		text_in(cv, c.f10, k[1], hx, fy, fh, argb(H.dim, 0xff))
		hx += tw(c.f10, k[1]) + 14 * S
	}
	toast := c.toast
	tc := H.acc
	if toast == "" && !c.recording { toast, tc = "Not recording: new copies are not saved until clipse -listen runs", t.yellow }
	if toast != "" {
		tt := ellipsize(c.f10, toast, w - 24 * S - hx)
		text_in(cv, c.f10, tt, w - 24 * S - tw(c.f10, tt), fy, fh, argb(tc, 0xff))
	}
	// the head and foot again over rows cut at the edges
	frame(cv, 0, 0, w, h, S, argb(H.line, 0xff), argb(H.acc, 0xff), 26)
}

@(private = "file")
clip_row :: proc(a: ^App, cv: ^Canvas, S, i, y, lw, key: int, H: HUD, soft: u32, q: string) {
	c := a.clip
	e := c.all[c.vis[i]]
	on := i == c.cur
	x0, x1 := 10 * S, lw - 10 * S
	rh := 50 * S
	ry := y + S
	if on {
		fill_rect(cv, x0, ry, x1 - x0, rh, argb(H.acc, 0x14))
		rounded_rect(cv, x0, ry, x1 - x0, rh, 0, 0, f32(S), argb(H.acc, 0xff))
		fill_rect(cv, x0, ry, 3 * S, rh, argb(H.acc, 0xff))
		mark_sel(a, x0, ry, x1 - x0, rh)
	}
	kc := clip_kc(a, e, H)
	bx, by := x0 + 12 * S, ry + 8 * S
	bs := 34 * S
	fill_rect(cv, bx, by, bs, bs, argb(kc, 0x14))
	if e.kind == 2 {
		img := image_cover(a, e.image, bs, bs)
		if img.ok do blit_image(cv, img.px, img.w, img.h, bx, by)
	} else if col, isc := clip_hex(e.label); isc && e.kind == 0 {
		fill_rect(cv, bx + 6 * S, by + 6 * S, 22 * S, 22 * S, argb(col, 0xff))
	} else {
		g := e.kind == 1 ? "¶" : "T"
		text_in(cv, c.f13b, g, bx + (bs - tw(c.f13b, g)) / 2, by, bs, argb(kc, 0xff))
	}
	rounded_rect(cv, bx, by, bs, bs, 0, 0, f32(S), argb(kc, 0x44))
	tx := bx + bs + 11 * S
	right := x1 - 10 * S - 30 * S
	if e.pinned { text_in(cv, c.f10, "◆", right - 12 * S, ry, rh, argb(H.acc, 0xff)); right -= 18 * S }
	if key > 0 do text_in(cv, c.f10, fmt.tprintf("A-%d", key), x1 - 10 * S - tw(c.f10, fmt.tprintf("A-%d", key)), ry, rh, argb(on ? soft : H.faint, 0xff))
	f := on ? c.f12b : c.f12
	lab := ellipsize(f, e.label, right - tx)
	ly := ry + (rh - int(c.f12.line_h) - 3 * S - int(c.f10.line_h)) / 2
	col := on ? H.fg : soft
	at := q != "" ? strings.index(strings.to_lower(lab, context.temp_allocator), q) : -1
	if at >= 0 && at + len(q) <= len(lab) { // the match bold in the accent
		pre, hit, post := lab[:at], lab[at:at + len(q)], lab[at + len(q):]
		text_in(cv, f, pre, tx, ly, int(c.f12.line_h), argb(col, 0xff))
		hx := tx + tw(f, pre)
		text_in(cv, c.f12b, hit, hx, ly, int(c.f12.line_h), argb(H.acc, 0xff))
		text_in(cv, f, post, hx + tw(c.f12b, hit), ly, int(c.f12.line_h), argb(col, 0xff))
	} else do text_in(cv, f, lab, tx, ly, int(c.f12.line_h), argb(col, 0xff))
	text_in(cv, c.f10, ellipsize(c.f10, clip_meta(e), right - tx), tx, ly + int(c.f12.line_h) + 3 * S, int(c.f10.line_h), argb(H.dim, 0xff))
	hit_add(a, x0, ry, x1 - x0, rh, .Row, i, 0)
}

@(private = "file")
clip_preview :: proc(a: ^App, cv: ^Canvas, S, x, y, w, h: int, e: Clip_Entry, H: HUD, soft: u32) {
	c := a.clip
	t := a.theme
	kc := clip_kc(a, e, H)
	// the head: kind · what it is · when
	hh := 44 * S
	kinds := [3]string{"TEXT", "BLOCK", "IMAGE"}
	kd := kinds[e.kind]
	kw := spaced_w(c.f9b, kd, S) + 12 * S
	rounded_rect(cv, x + 20 * S, y + (hh - 16 * S) / 2, kw, 16 * S, 0, 0, f32(S), argb(kc, 0xff))
	spaced(cv, c.f9b, kd, x + 26 * S, y + (hh - 16 * S) / 2, 16 * S, kc, S)
	when_ := fmt.tprintf("%scopied %s ago", e.pinned ? "pinned · " : "", clip_ago(e.at))
	if strings.has_prefix(clip_ago(e.at), "yesterday") do when_ = fmt.tprintf("%scopied yesterday", e.pinned ? "pinned · " : "")
	text_in(cv, c.f10, when_, x + w - 20 * S - tw(c.f10, when_), y, hh, argb(H.dim, 0xff))
	info: string
	switch e.kind {
	case 0: info = fmt.tprintf("%s · %s", plural_n(e.chars, "char"), plural_n(len(strings.fields(e.body, context.temp_allocator)), "word"))
	case 1: info = fmt.tprintf("%s · %d lines · %d chars", clip_lang(e.body), e.lines, e.chars)
	case 2: info = clip_meta(e)
	}
	if e.secret do info = fmt.tprintf("secret · expires in %d s", clip_left(e))
	ix := x + 20 * S + kw + 10 * S
	text_in(cv, c.f11, ellipsize(c.f11, info, x + w - 30 * S - tw(c.f10, when_) - ix), ix, y, hh, argb(H.dim, 0xff))
	fill_rect(cv, x, y + hh, w, S, argb(H.line, 0xff))
	// the actions at the bottom
	ah := 28 * S + 26 * S
	ay := y + h - ah
	fill_rect(cv, x, ay, w, S, argb(H.line, 0xff))
	acts := [6][3]string{{"Paste", "↵", "0"}, {"Copy", "⇧↵", "1"}, {e.kind == 2 ? "Save as…" : (e.kind == 1 ? "Open in editor" : "Paste plain"), "^↵", "2"}, {"Send to…", "^S", "5"}, {e.pinned ? "Unpin" : "Pin", "^P", "3"}, {"Delete", "Del", "4"}}
	bx := x + 20 * S
	keys := true // the key hints go when the buttons would not fit
	total := 0
	for p in acts do total += tw(c.f11b, p[0]) + 7 * S + tw(c.f11, p[1]) + 20 * S + 6 * S
	if total > w - 40 * S do keys = false
	for p, i in acts {
		bw := keys ? tw(c.f11b, p[0]) + 7 * S + tw(c.f11, p[1]) + 20 * S : tw(c.f11b, p[0]) + 20 * S
		prim := i == 0
		by := ay + 12 * S
		if prim do fill_rect(cv, bx, by, bw, 28 * S, argb(H.acc, 0xff))
		rounded_rect(cv, bx, by, bw, 28 * S, 0, 0, f32(S), argb(prim ? H.acc : H.line, 0xff))
		text_in(cv, c.f11b, p[0], bx + 10 * S, by, 28 * S, argb(prim ? H.bg : soft, 0xff))
		if keys do text_in(cv, c.f11, p[1], bx + 10 * S + tw(c.f11b, p[0]) + 7 * S, by, 28 * S, argb(prim ? H.bg : H.dim, 0xff))
		id, _ := strconv.parse_int(p[2])
		hit_add(a, bx, by, bw, 28 * S, .Chip, id, 0)
		bx += bw + 6 * S
	}
	// the body
	px, py := x + 20 * S, y + hh + S + 18 * S
	pw, ph := w - 40 * S, ay - 14 * S - py
	switch e.kind {
	case 0:
		col := H.fg
		if strings.has_prefix(e.body, "http://") || strings.has_prefix(e.body, "https://") do col = H.acc
		ly := py
		for l in wrap_text(c.f16, e.body, pw) {
			if ly + 26 * S > py + ph do break
			text_in(cv, c.f16, l, px, ly, 26 * S, argb(col, 0xff))
			ly += 26 * S
		}
		if sw, ok := clip_hex(e.body); ok && ly + 56 * S <= py + ph {
			ly += 14 * S
			fill_rect(cv, px, ly, 120 * S, 56 * S, argb(sw, 0xff))
			r, g, b := sw >> 16 & 0xff, sw >> 8 & 0xff, sw & 0xff
			text_in(cv, c.f11, fmt.tprintf("Colour · rgb(%d %d %d)", r, g, b), px + 132 * S, ly, 56 * S, argb(H.dim, 0xff))
		}
	case 1:
		fill_rect(cv, px, py, pw, ph, argb(mix(H.bg, 0, 0.3), 0xff))
		rounded_rect(cv, px, py, pw, ph, 0, 0, f32(S), argb(H.line, 0xff))
		ly := py + 10 * S
		for l, i in strings.split_lines(e.body, context.temp_allocator) {
			if ly + 20 * S > py + ph - 6 * S do break
			num := fmt.tprint(i + 1)
			text_in(cv, c.f12, num, px + 38 * S - 12 * S - tw(c.f12, num), ly, 20 * S, argb(H.faint, 0xff))
			s := strings.trim_left_space(l)
			lc := H.fg
			switch {
			case strings.has_prefix(s, "#") || strings.has_prefix(s, "//"): lc = H.dim
			case len(s) > 0 && (s[0] == '{' || s[0] == '}' || s[0] == '[' || s[0] == ']'): lc = soft
			}
			text_in(cv, c.f12, l, px + 38 * S, ly, 20 * S, argb(lc, 0xff), px + pw - 8 * S)
			ly += 20 * S
		}
	case 2:
		fill_rect(cv, px, py, pw, ph, argb(mix(H.bg, 0, 0.3), 0xff))
		cs := 8 * S
		for yy := py; yy < py + ph; yy += cs do for xx := px; xx < px + pw; xx += cs {
			if ((xx - px) / cs + (yy - py) / cs) % 2 == 0 do fill_rect(cv, xx, yy, min(cs, px + pw - xx), min(cs, py + ph - yy), argb(H.panel, 0xff))
		}
		img := image_scaled(a, e.image, min(480 * S, pw - 20 * S), min(330 * S, ph - 20 * S), false)
		if img.ok {
			ix2, iy2 := px + (pw - img.w) / 2, py + (ph - img.h) / 2
			blit_image(cv, img.px, img.w, img.h, ix2, iy2)
			rounded_rect(cv, ix2, iy2, img.w, img.h, 0, 0, f32(S), argb(H.line, 0xff))
		}
		rounded_rect(cv, px, py, pw, ph, 0, 0, f32(S), argb(H.line, 0xff))
	}
}

clip_dump :: proc(a: ^App) -> string {
	c := a.clip
	sb := strings.builder_make(context.temp_allocator)
	tabs := [4]string{"All", "Text", "Blocks", "Images"}
	fmt.sbprintfln(&sb, "clip %s · %d of %d", tabs[c.tab], len(c.vis), len(c.all))
	for v, i in c.vis {
		e := c.all[v]
		kinds := [3]string{"text", "block", "image"}
		fmt.sbprintfln(&sb, "%s %s%s · %s%s", i == c.cur ? "*" : " ", e.pinned ? "◆ " : "", e.label, kinds[e.kind], e.secret || e.app != "" ? fmt.tprintf(" · %s", clip_meta(e)) : "")
	}
	if c.toast != "" do fmt.sbprintfln(&sb, "toast %s", c.toast)
	return strings.to_string(sb)
}
