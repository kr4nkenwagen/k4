package k4

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "logic"

Anchor :: enum { Center, Top, Top_Left, Top_Right, Bottom, Bottom_Left, Bottom_Right, Left, Right }

Options :: struct {
	index_mode:    bool,
	prompt:        string,
	password:      bool,
	password_char: string,
	lines:         int,
	width_chars:   int, // 0 = fit the rows
	anchor:        Anchor,
	margin:        int,
	font:          string,
	font_pt:       f32,
	row_height:    int, // 0 = from the font
	icon_size:     int, // 0 = row height - 6
	radius:        f32,
	border:        int,
	dry_run:       string, // PNG path: render once without Wayland
	keys:          string, // typed into the query before the first frame (tests, dry runs)
	select:        int,    // move the selection down this many rows before the first frame
	scale:         int,    // dry runs only
	theme_file:    string,
	no_icons:      bool,
	menu:          bool,
	open:          string,
	dump:          bool, // --dump: print the state as text instead of a PNG
}

Icon :: struct { px: []u32, w, h: int, ok: bool }

App :: struct {
	opts:     Options,
	theme:    logic.Theme,
	font:     Font,
	rows:     []logic.Row,
	matches:  [dynamic]logic.Match,
	query:    [dynamic]u8,
	cursor:   int, // byte offset in query
	selected: int,
	scroll:   int,
	icons:    map[string]Icon,
	font_px:  f32, // logical em size; the font is resized to font_px * scale for drawing
	fonts:    [dynamic]^Font, // extra sizes (menu mode), resized with the buffer scale
	family:   string,
	scale:    int, // buffer scale of the output (fonts are sized for it)
	menu:     ^Menu,
	has_icons: bool,
	// layout in logical pixels
	pad, row_h, prompt_h, icon_px, gap, width, height, shown: int,
	// outcome
	done:     bool,
	exit:     int,
	result:   string,
}

app_rematch :: proc(a: ^App) {
	if a.menu != nil { menu_on_query(a); return }
	logic.match_rows(a.rows, string(a.query[:]), &a.matches)
	a.selected = 0
	a.scroll = 0
}

app_layout :: proc(a: ^App) {
	f := &a.font
	text_h := int(f.line_h)
	a.pad = 10
	a.gap = 6
	a.prompt_h = text_h + 10
	for r in a.rows do if r.icon != "" && !a.opts.no_icons { a.has_icons = true; break }
	a.row_h = a.opts.row_height > 0 ? a.opts.row_height : text_h + 8
	if a.has_icons && a.opts.row_height == 0 do a.row_h = max(a.row_h, text_h * 2 + 8)
	a.icon_px = a.opts.icon_size > 0 ? a.opts.icon_size : a.row_h - 6
	a.shown = min(a.opts.lines, len(a.rows))
	a.height = 2 * a.opts.border + 2 * a.pad + a.prompt_h + (a.shown > 0 ? a.gap + a.shown * a.row_h : 0)

	text_left := a.has_icons ? a.icon_px + 10 : 0
	widest: f32 = shape(f, a.opts.prompt).width + 24 * shape(f, "M").width // room to type
	if a.opts.width_chars > 0 {
		widest = f32(a.opts.width_chars) * shape(f, "M").width
	} else {
		for r in a.rows do widest = max(widest, shape(f, r.label).width + f32(text_left) + 16)
	}
	a.width = 2 * a.opts.border + 2 * a.pad + int(math.ceil(widest)) + 8
	a.width = clamp(a.width, 280, 1600)
}

@(private)
icon_get :: proc(a: ^App, path: string, size: int) -> ^Icon { return image_scaled(a, path, size, size, false) }

// The picture scaled to cover a w x h tile (centre crop), like CSS object-fit: cover.
image_cover :: proc(a: ^App, path: string, w, h: int) -> ^Icon { return image_scaled(a, path, w, h, true) }

@(private)
image_scaled :: proc(a: ^App, path: string, tw, th: int, cover: bool) -> ^Icon {
	key := fmt.tprintf("%d:%d:%v:%s", tw, th, cover, path)
	if ic, ok := &a.icons[key]; ok do return ic
	a.icons[strings.clone(key)] = Icon{}
	ic := &a.icons[key]
	if !strings.has_prefix(path, "/") do return ic // icon theme names are not supported
	w, h: c.int
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	data := k4_image_load(cpath, &w, &h)
	if data == nil do return ic
	defer k4_free(data)
	// fit inside (or cover) tw x th, box-filter downscale, premultiply
	s := cover ? max(f32(tw) / f32(w), f32(th) / f32(h)) : min(f32(tw) / f32(w), f32(th) / f32(h))
	ow, oh := max(int(f32(w) * s), 1), max(int(f32(h) * s), 1)
	ox0, oy0 := 0, 0
	if cover { ox0, oy0 = (ow - tw) / 2, (oh - th) / 2; ow, oh = tw, th }
	px := make([]u32, ow * oh)
	for oy in 0 ..< oh {
		syf := f32(oy + oy0)
		sy0, sy1 := int(syf / s), max(int((syf + 1) / s), int(syf / s) + 1)
		for ox in 0 ..< ow {
			sxf := f32(ox + ox0)
			sx0, sx1 := int(sxf / s), max(int((sxf + 1) / s), int(sxf / s) + 1)
			r, g, b, al, n: u32
			for sy in sy0 ..< min(sy1, int(h)) do for sx in sx0 ..< min(sx1, int(w)) {
				i := (sy * int(w) + sx) * 4
				pa := u32(data[i + 3])
				r += u32(data[i]) * pa / 255; g += u32(data[i + 1]) * pa / 255; b += u32(data[i + 2]) * pa / 255
				al += pa; n += 1
			}
			if n == 0 do n = 1
			px[oy * ow + ox] = (al / n) << 24 | (r / n) << 16 | (g / n) << 8 | (b / n)
		}
	}
	ic^ = Icon{px, ow, oh, true}
	return ic
}

@(private)
draw_text :: proc(cv: ^Canvas, a: ^App, text: string, x, y_top, scale: int, color: u32, hl: []int = nil, hl_color: u32 = 0, clip_x1 := max(int)) {
	draw_text_f(cv, &a.font, text, x, y_top, color, hl, hl_color, clip_x1)
}

draw_text_f :: proc(cv: ^Canvas, f: ^Font, text: string, x, y_top: int, color: u32, hl: []int = nil, hl_color: u32 = 0, clip_x1 := max(int)) {
	s := shape(f, text)
	baseline := y_top + int(f.ascent)
	for g, gi in s.glyphs {
		col := color
		if len(hl) > 0 {
			end := gi + 1 < len(s.glyphs) ? s.glyphs[gi + 1].cp_index : max(i32)
			for p in hl do if i32(p) >= g.cp_index && i32(p) < end { col = hl_color; break }
		}
		gb, gx := glyph_bitmap(f, g.face, g.id, f32(x) + g.x)
		if len(gb.alpha) == 0 do continue
		blit_mask(cv, gb.alpha, int(gb.w), int(gb.h), int(gx) + int(gb.xoff), baseline + int(gb.yoff), col, 0, clip_x1)
	}
}

app_draw :: proc(a: ^App, cv: ^Canvas, scale: int) {
	if a.menu != nil { menu_draw(a, cv, scale); return }
	t := a.theme
	S :: proc(v, scale: int) -> int { return v * scale }
	canvas_clear(cv)
	rounded_rect(cv, 0, 0, cv.w, cv.h, a.opts.radius * f32(scale), argb(t.bg, 0xee), f32(a.opts.border * scale), argb(t.accent, 0xff))
	inner := S(a.opts.border + a.pad, scale)
	right := cv.w - inner

	// prompt line
	py := inner + S(5, scale)
	draw_text(cv, a, a.opts.prompt, inner, py, scale, argb(t.accent, 0xff))
	qx := inner + int(math.ceil(shape(&a.font, a.opts.prompt).width))
	q := string(a.query[:])
	if a.opts.password do q = strings.repeat(a.opts.password_char, utf8.rune_count_in_string(q), context.temp_allocator)
	draw_text(cv, a, q, qx, py, scale, argb(t.fg_bright, 0xff), clip_x1 = right)
	cur_cp := utf8.rune_count_in_string(string(a.query[:a.cursor]))
	qs := shape(&a.font, q)
	cx := qx + int(qs.cp_x[min(cur_cp, len(qs.cp_x) - 1)])
	fill_rect(cv, cx, py, max(scale, 2), int(a.font.line_h), argb(t.fg_bright, 0xff))
	if len(a.rows) > 0 {
		count := fmt.tprintf("%d/%d", len(a.matches), len(a.rows))
		cw := int(shape(&a.font, count).width)
		draw_text(cv, a, count, right - cw, py, scale, argb(t.fg_dim, 0xff))
	}

	// rows
	y := inner + S(a.prompt_h + a.gap, scale)
	rh := S(a.row_h, scale)
	for i in a.scroll ..< min(a.scroll + a.shown, len(a.matches)) {
		m := a.matches[i]
		row := a.rows[m.row]
		sel := i == a.selected
		if sel do rounded_rect(cv, inner - S(4, scale), y, right - inner + S(8, scale), rh, f32(S(4, scale)), argb(t.selection, 0xff))
		tx := inner
		if a.has_icons {
			isz := S(a.icon_px, scale)
			if row.icon != "" {
				ic := icon_get(a, row.icon, isz)
				if ic.ok do blit_image(cv, ic.px, ic.w, ic.h, tx + (isz - ic.w) / 2, y + (rh - ic.h) / 2)
			}
			tx += isz + S(10, scale)
		}
		ty := y + (rh - int(a.font.line_h)) / 2
		draw_text(cv, a, row.label, tx, ty, scale, argb(sel ? t.fg_bright : t.fg, 0xff), m.positions, argb(t.accent, 0xff), right)
		y += rh
	}
}

// ---------- input ----------

Key :: enum { None, Escape, Enter, Up, Down, Page_Up, Page_Down, Left, Right, Home, End, Backspace, Delete, Tab, Back_Tab }

app_ensure_visible :: proc(a: ^App) {
	if a.selected < a.scroll do a.scroll = a.selected
	if a.selected >= a.scroll + a.shown do a.scroll = a.selected - a.shown + 1
}

app_move :: proc(a: ^App, d: int) {
	if len(a.matches) == 0 do return
	a.selected = clamp(a.selected + d, 0, len(a.matches) - 1)
	app_ensure_visible(a)
}

app_accept :: proc(a: ^App) {
	if len(a.matches) > 0 {
		r := a.rows[a.matches[a.selected].row]
		a.result = a.opts.index_mode ? fmt.aprintf("%d", r.index) : r.label
		a.exit = 0
	} else if !a.opts.index_mode && (len(a.rows) == 0 || len(a.query) > 0) {
		a.result = strings.clone(string(a.query[:])) // free text, e.g. a password prompt
		a.exit = 0
	} else {
		a.exit = 1
	}
	a.done = true
}

app_insert :: proc(a: ^App, text: string) {
	inject_at(&a.query, a.cursor, ..transmute([]u8)text)
	a.cursor += len(text)
	app_rematch(a)
}

@(private)
prev_cp :: proc(s: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && s[j] & 0xc0 == 0x80 do j -= 1
	return max(j, 0)
}
@(private)
next_cp :: proc(s: []u8, i: int) -> int {
	j := i + 1
	for j < len(s) && s[j] & 0xc0 == 0x80 do j += 1
	return min(j, len(s))
}

// Returns true when the frame needs redrawing.
app_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string, alt := false) -> bool {
	if a.menu != nil do return menu_key(a, k, ctrl, alt, ch, text)
	return app_edit_key(a, k, ctrl, ch, text)
}

// dmenu keys, and the query editing keys menu mode shares.
app_edit_key :: proc(a: ^App, k: Key, ctrl: bool, ch: rune, text: string) -> bool {
	q := &a.query
	if ctrl {
		switch ch {
		case 'c', 'g', '[': a.exit = 1; a.done = true
		case 'n', 'j': app_move(a, 1)
		case 'p': app_move(a, -1)
		case 'a': a.cursor = 0
		case 'e': a.cursor = len(q)
		case 'h': if a.cursor > 0 { p := prev_cp(q[:], a.cursor); remove_range(q, p, a.cursor); a.cursor = p; app_rematch(a) }
		case 'd': if a.cursor < len(q) { n := next_cp(q[:], a.cursor); remove_range(q, a.cursor, n); app_rematch(a) }
		case 'u': remove_range(q, 0, a.cursor); a.cursor = 0; app_rematch(a)
		case 'k': resize(q, a.cursor); app_rematch(a)
		case 'w':
			p := a.cursor
			for p > 0 && q[p - 1] == ' ' do p -= 1
			for p > 0 && q[p - 1] != ' ' do p -= 1
			remove_range(q, p, a.cursor); a.cursor = p; app_rematch(a)
		case: return false
		}
		return true
	}
	switch k {
	case .Escape: a.exit = 1; a.done = true
	case .Enter: app_accept(a)
	case .Up, .Back_Tab: app_move(a, -1)
	case .Down, .Tab: app_move(a, 1)
	case .Page_Up: app_move(a, -max(a.shown, 1))
	case .Page_Down: app_move(a, max(a.shown, 1))
	case .Left: a.cursor = prev_cp(q[:], a.cursor)
	case .Right: a.cursor = next_cp(q[:], a.cursor)
	case .Home: a.cursor = 0
	case .End: a.cursor = len(q)
	case .Backspace: if a.cursor > 0 { p := prev_cp(q[:], a.cursor); remove_range(q, p, a.cursor); a.cursor = p; app_rematch(a) }
	case .Delete: if a.cursor < len(q) { n := next_cp(q[:], a.cursor); remove_range(q, a.cursor, n); app_rematch(a) }
	case .None:
		if len(text) == 0 do return false
		for r in text do if r < 0x20 || r == 0x7f do return false
		app_insert(a, text)
	}
	return true
}
