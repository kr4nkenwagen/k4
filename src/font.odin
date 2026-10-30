package k4

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import kbts "vendor_k4:kb_text_shape"

// A font face: kb_text_shape shapes (ligatures, kerning), stb_truetype rasterises.
// Glyphs the main font lacks (id 0) come from fallback faces, unshaped: for each missing
// character fontconfig is asked which installed font has it (cached per character).
Font :: struct {
	data:      []u8,
	info:      rawptr,
	shaper:    ^kbts.shape_context,
	px:        f32, // em size in pixels (base_px * buffer scale)
	base_px:   f32, // logical em size
	index:     int,
	scale:     f32, // font units -> pixels
	ascent:    f32,
	descent:   f32,
	line_h:    f32,
	fallback:  ^Fallbacks, // shared by every size of every font
	glyphs:    map[Glyph_Key]Glyph,
	shaped:    map[string]Shaped,
	alloc:     runtime.Allocator, // kept alive for kb_text_shape
}

Glyph_Key :: struct { face: u8, id: u16, sub: u8 }

Face :: struct { data: []u8, info: rawptr, path: string, color: bool, shaper: ^kbts.shape_context, alloc: ^runtime.Allocator } // color: CBDT bitmaps, no outlines; shaper: its ligatures (flags, skin tones, families)
Fallbacks :: struct {
	faces:  [dynamic]Face,
	misses: map[rune]bool, // characters no installed font has
	no_emoji_font: bool,   // fontconfig has no colour emoji font: stop asking
}
Glyph :: struct { w, h, xoff, yoff: i32, alpha: []u8, color: []u32 } // color: an emoji (premultiplied ARGB)

Shaped_Glyph :: struct {
	face:     u8, // 0 the font itself, n = fallback face n-1
	id:       u16,
	x:        f32, // pen position in px
	cp_index: i32,
}
Shaped :: struct {
	glyphs: []Shaped_Glyph,
	width:  f32,
	cp_x:   []f32, // x where each codepoint starts, len = codepoints + 1
}

// The installed family of exactly that name first (fc-match applies the desktop's
// substitution rules, and Omarchy's swap any named monospace for its own), then fc-match.
// "Family:weight=bold" asks for the bold face.
font_file :: proc(family: string) -> (path: string, index: int, ok: bool) {
	// what fontconfig answered last time (~/.cache/k4/fonts.tsv), while that file is unchanged:
	// fc-list costs ~10 ms a call, and every window asks for two or three faces
	if path, index, ok = font_cache_get(family); ok do return
	defer if ok do font_cache_put(family, path, index)
	if path, index, ok = font_file_exact(family); ok do return
	state, out, _, err := os.process_exec({command = {"fc-match", "-f", "%{file}\n%{index}", family}}, context.allocator)
	if err != nil || !state.success do return
	lines := strings.split_lines(string(out), context.temp_allocator)
	if len(lines) == 0 || len(lines[0]) == 0 do return
	path = lines[0]
	if len(lines) > 1 do index, _ = strconv.parse_int(lines[1])
	return path, index, true
}

@(private)
font_cache_path :: proc() -> string {
	if v := os.get_env("K4_FONT_CACHE", context.temp_allocator); v != "" do return v
	return strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache/k4/fonts.tsv"}, context.temp_allocator)
}

// A cached answer: family, file, index, the file's mtime (it must still match).
@(private)
font_cache_get :: proc(family: string) -> (path: string, index: int, ok: bool) {
	data, err := os.read_entire_file(font_cache_path(), context.temp_allocator)
	if err != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 4 || f[0] != family do continue
		fi, serr := os.stat(f[1], context.temp_allocator)
		if serr != nil || fmt.tprint(time_unix(fi.modification_time)) != f[3] do return
		index, _ = strconv.parse_int(f[2])
		return strings.clone(f[1]), index, true
	}
	return
}

@(private)
time_unix :: proc(t: time.Time) -> i64 { return time.to_unix_seconds(t) }

@(private)
font_cache_put :: proc(family, path: string, index: int) {
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil do return
	p := font_cache_path()
	old, _ := os.read_entire_file(p, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	text := string(old)
	for line in strings.split_lines_iterator(&text) do if !strings.has_prefix(line, strings.concatenate({family, "\t"}, context.temp_allocator)) && line != "" do fmt.sbprintln(&sb, line)
	fmt.sbprintfln(&sb, "%s\t%s\t%d\t%d", family, path, index, time_unix(fi.modification_time))
	_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
	tmp := strings.concatenate({p, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(sb)) == nil do os.rename(tmp, p)
}

@(private)
font_file_exact :: proc(family: string) -> (path: string, index: int, ok: bool) {
	name, bold := family, false
	if c := strings.index_byte(family, ':'); c >= 0 do name, bold = family[:c], strings.contains(family[c:], "bold")
	if name == "" do return
	state, out, _, err := os.process_exec({command = {"fc-list", "-f", "%{file}\t%{index}\t%{style}\n", name}}, context.temp_allocator)
	if err != nil || !state.success do return
	best := min(int)
	text := string(out)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 3 || f[0] == "" do continue
		st := strings.to_lower(f[2], context.temp_allocator)
		score := 0
		if strings.contains(st, "italic") || strings.contains(st, "oblique") do score -= 10
		has_bold := strings.contains(st, "bold")
		if bold do score += has_bold && !strings.contains(st, "semi") && !strings.contains(st, "extra") ? 5 : (has_bold ? 2 : 0)
		else {
			if strings.contains(st, "regular") || strings.contains(st, "book") || st == "normal" do score += 5
			for w in ([]string{"bold", "light", "thin", "medium", "black", "heavy", "semi", "extra", "retina"}) do if strings.contains(st, w) do score -= 2
		}
		if score > best {
			best = score
			path = strings.clone(f[0])
			index, _ = strconv.parse_int(f[1])
			ok = true
		}
	}
	return
}

font_load :: proc(f: ^Font, family: string, px: f32, shape: bool) -> bool {
	path, index, ok := font_file(family)
	if !ok do return false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	f.data = data
	f.index = index
	f.info = k4_font_new(raw_data(data), c.int(index))
	if f.info == nil do return false
	f.base_px = px
	font_resize(f, px)
	if shape {
		f.alloc = context.allocator
		fn, data_ptr := kbts.AllocatorFromOdinAllocator(&f.alloc)
		f.shaper = kbts.CreateShapeContext(fn, data_ptr)
		if f.shaper != nil do kbts.ShapePushFontFromMemory(f.shaper, data, c.int(index))
	}
	return true
}

@(private)
fallback_glyph :: proc(f: ^Font, cp: rune) -> (face: u8, id: u16, adv: f32, ok: bool) {
	fb := f.fallback
	if fb == nil || cp < 0x20 do return
	find :: proc(f: ^Font, fb: ^Fallbacks, cp: rune) -> (u8, u16, f32, bool) {
		for fc, i in fb.faces {
			g := k4_font_glyph_index(fc.info, c.int(cp))
			if g == 0 do continue
			a, l: c.int
			k4_font_glyph_hmetrics(fc.info, g, &a, &l)
			return u8(i + 1), u16(g), f32(a) * k4_font_scale_em(fc.info, f.px), true
		}
		return 0, 0, 0, false
	}
	if face, id, adv, ok := find(f, fb, cp); ok do return face, id, adv, true
	if fb.misses[cp] || len(fb.faces) >= 250 do return
	// ask fontconfig for a font that covers this character
	pattern := fmt.tprintf("sans-serif:charset=%x", u32(cp))
	path, index, found := font_file(pattern)
	if found {
		known := false
		for fc in fb.faces do if fc.path == path { known = true; break }
		if !known {
			if data, err := os.read_entire_file(path, context.allocator); err == nil {
				if info := k4_font_new(raw_data(data), c.int(index)); info != nil {
					append(&fb.faces, Face{data = data, info = info, path = strings.clone(path)})
				} else if info := k4_font_new_color(raw_data(data), c.int(index)); info != nil {
					append(&fb.faces, Face{data = data, info = info, path = strings.clone(path), color = true}) // Noto Color Emoji
				}
			}
		}
		if face, id, adv, ok := find(f, fb, cp); ok do return face, id, adv, true
	}
	fb.misses[cp] = true
	return
}

// Shaped text is cached per string: rows rarely change between frames.
shape :: proc(f: ^Font, text: string) -> Shaped {
	if s, ok := f.shaped[text]; ok do return s
	ncp := utf8.rune_count_in_string(text)
	out := make([dynamic]Shaped_Glyph, 0, ncp)
	x: f32
	if f.shaper != nil && len(text) > 0 {
		// emoji sequences go to the colour emoji font's own shaper (its ligatures make flags,
		// skin tones and families); the rest to this font, missing characters to fallbacks
		cp_base: i32
		for seg in emoji_segments(text) {
			part := text[seg.start:seg.end]
			if seg.emoji {
				if face, fc, ok := color_face(f, part); ok {
					sc := k4_font_scale_em(fc.info, f.px)
					kbts.ShapeBegin(fc.shaper, .DONT_KNOW, .DONT_KNOW)
					kbts.ShapeUtf8(fc.shaper, part, .CODEPOINT_INDEX)
					kbts.ShapeEnd(fc.shaper)
					for run in kbts.ShapeRun(fc.shaper) {
						run := run
						for g in kbts.GlyphIteratorNext(&run.Glyphs) {
							if g.AdvanceX == 0 && g.Id == 0 do continue
							append(&out, Shaped_Glyph{face, g.Id, x, cp_base + i32(g.UserIdOrCodepointIndex)})
							x += f32(g.AdvanceX) * sc
						}
					}
					cp_base += i32(utf8.rune_count_in_string(part))
					continue
				}
			}
			kbts.ShapeBegin(f.shaper, .DONT_KNOW, .DONT_KNOW)
			kbts.ShapeUtf8(f.shaper, part, .CODEPOINT_INDEX)
			kbts.ShapeEnd(f.shaper)
			for run in kbts.ShapeRun(f.shaper) {
				run := run
				for g in kbts.GlyphIteratorNext(&run.Glyphs) {
					if g.Id == 0 {
						if face, id, adv, ok := fallback_glyph(f, g.Codepoint); ok {
							append(&out, Shaped_Glyph{face, id, x, cp_base + i32(g.UserIdOrCodepointIndex)})
							x += adv
							continue
						}
					}
					append(&out, Shaped_Glyph{0, g.Id, x + f32(g.OffsetX) * f.scale, cp_base + i32(g.UserIdOrCodepointIndex)})
					x += f32(g.AdvanceX) * f.scale
				}
			}
			cp_base += i32(utf8.rune_count_in_string(part))
		}
	} else {
		i: i32
		for r in text {
			g := k4_font_glyph_index(f.info, c.int(r))
			a, l: c.int
			if g == 0 {
				if face, id, adv, ok := fallback_glyph(f, r); ok {
					append(&out, Shaped_Glyph{face, id, x, i}); x += adv; i += 1; continue
				}
			}
			k4_font_glyph_hmetrics(f.info, g, &a, &l)
			append(&out, Shaped_Glyph{0, u16(g), x, i})
			x += f32(a) * f.scale
			i += 1
		}
	}
	// codepoint -> x, interpolating inside ligatures (one glyph for several codepoints)
	cp_x := make([]f32, ncp + 1)
	for &v in cp_x do v = -1
	for g in out do if g.cp_index >= 0 && int(g.cp_index) < ncp && cp_x[g.cp_index] < 0 do cp_x[g.cp_index] = g.x
	cp_x[ncp] = x
	for i := 0; i < ncp; i += 1 {
		if cp_x[i] >= 0 do continue
		j := i
		for j < ncp && cp_x[j] < 0 do j += 1
		left := i > 0 ? cp_x[i - 1] : 0
		for k in i ..< j do cp_x[k] = left + (cp_x[j] - left) * f32(k - i + 1) / f32(j - i + 1)
		i = j
	}
	s := Shaped{glyphs = out[:], width = x, cp_x = cp_x}
	f.shaped[strings.clone(text)] = s
	return s
}

Emoji_Segment :: struct { start, end: int, emoji: bool }

// Splits text into emoji sequences and the rest. An emoji is a pictograph (U+1F000…),
// a flag (regional indicators), or a BMP symbol followed by U+FE0F; joiners, skin tones,
// tags and U+FE0F glue it to its neighbours. BMP symbols without U+FE0F (❯, ☰) stay text.
emoji_segments :: proc(text: string) -> []Emoji_Segment {
	glue :: proc(r: rune) -> bool {
		switch r {
		case 0x200D, 0xFE0F, 0x20E3, 0x1F3FB ..= 0x1F3FF, 0xE0020 ..= 0xE007F: return true
		}
		return false
	}
	pict :: proc(r: rune) -> bool { return r >= 0x1F000 && r <= 0x1FAFF || r >= 0x1F1E6 && r <= 0x1F1FF }
	out := make([dynamic]Emoji_Segment, 0, 4, context.temp_allocator)
	runes := make([dynamic]struct { r: rune, at: int }, 0, len(text), context.temp_allocator)
	for r, i in text do append(&runes, struct { r: rune, at: int }{r, i})
	is := make([]bool, len(runes), context.temp_allocator)
	for e, i in runes {
		next: rune = i + 1 < len(runes) ? runes[i + 1].r : 0
		is[i] = pict(e.r) || (e.r >= 0x2000 && e.r < 0x3300 && next == 0xFE0F) || e.r == 0xA9 && next == 0xFE0F || e.r == 0xAE && next == 0xFE0F
	}
	for i in 0 ..< len(runes) do if glue(runes[i].r) && i > 0 && is[i - 1] do is[i] = true
	for i := len(runes) - 2; i >= 0; i -= 1 do if runes[i].r == 0x200D && is[i + 1] do is[i] = true
	start := 0
	for i in 1 ..= len(runes) {
		if i == len(runes) || is[i] != is[start] {
			end := i < len(runes) ? runes[i].at : len(text)
			append(&out, Emoji_Segment{runes[start].at, end, len(runes) > 0 && is[start]})
			start = i
		}
	}
	return out[:]
}

// The colour emoji face for this run (found through the fallback search of its first
// character), with a shaper of its own.
@(private)
color_face :: proc(f: ^Font, part: string) -> (face: u8, fc: ^Face, ok: bool) {
	r, _ := utf8.decode_rune_in_string(part)
	fb := f.fallback
	if fb == nil do return
	// a colour face that has it; else ask fontconfig for an emoji font (a plain text font
	// may cover BMP symbols like ☺ too, and would win the ordinary fallback search)
	find :: proc(fb: ^Fallbacks, r: rune) -> int {
		for x, i in fb.faces do if x.color && k4_font_glyph_index(x.info, c.int(r)) != 0 do return i
		return -1
	}
	i := find(fb, r)
	if i < 0 && !fb.no_emoji_font {
		if path, index, ok := font_file(fmt.tprintf("emoji:charset=%x", u32(r))); ok {
			known := false
			for x in fb.faces do if x.path == path { known = true; break }
			if !known {
				if data, err := os.read_entire_file(path, context.allocator); err == nil {
					if info := k4_font_new_color(raw_data(data), c.int(index)); info != nil {
						append(&fb.faces, Face{data = data, info = info, path = strings.clone(path), color = true})
					}
				}
			}
		}
		i = find(fb, r)
		if i < 0 do fb.no_emoji_font = true
	}
	if i < 0 do return
	fface := u8(i + 1)
	fc = &fb.faces[i]
	if fc.shaper == nil {
		fc.alloc = new(runtime.Allocator)
		fc.alloc^ = context.allocator
		fn, data_ptr := kbts.AllocatorFromOdinAllocator(fc.alloc)
		fc.shaper = kbts.CreateShapeContext(fn, data_ptr)
		if fc.shaper == nil do return
		kbts.ShapePushFontFromMemory(fc.shaper, fc.data, 0)
	}
	return fface, fc, true
}

glyph_bitmap :: proc(f: ^Font, face: u8, id: u16, x: f32) -> (Glyph, f32) {
	frac := x - math.floor(x)
	sub := u8(frac * 4) & 3
	key := Glyph_Key{face, id, sub}
	if g, ok := f.glyphs[key]; ok do return g, math.floor(x)
	info, scale := f.info, f.scale
	if face > 0 && f.fallback != nil && int(face) <= len(f.fallback.faces) {
		fc := f.fallback.faces[face - 1]
		info, scale = fc.info, k4_font_scale_em(fc.info, f.px)
		if fc.color {
			g := color_glyph(f, info, id)
			f.glyphs[key] = g
			return g, math.floor(x)
		}
	}
	w, h, xo, yo: c.int
	bm := k4_font_glyph_bitmap(info, scale, f32(sub) / 4, c.int(id), &w, &h, &xo, &yo)
	g := Glyph{w = i32(w), h = i32(h), xoff = i32(xo), yoff = i32(yo)}
	if bm != nil {
		g.alpha = make([]u8, int(w * h))
		copy(g.alpha, bm[:w * h])
		k4_free(bm)
	}
	f.glyphs[key] = g
	return g, math.floor(x)
}

// A colour glyph (emoji): the strike's PNG scaled from its ppem to this size.
@(private)
color_glyph :: proc(f: ^Font, info: rawptr, id: u16) -> (g: Glyph) {
	w, h, bx, by, adv, ppem: c.int
	data := k4_font_color_glyph(info, c.int(id), &w, &h, &bx, &by, &adv, &ppem)
	if data == nil || ppem <= 0 do return
	defer k4_free(data)
	s := f.px / f32(ppem)
	ow, oh := max(int(f32(w) * s + 0.5), 1), max(int(f32(h) * s + 0.5), 1)
	px := make([]u32, ow * oh)
	for oy in 0 ..< oh {
		sy0, sy1 := oy * int(h) / oh, max((oy + 1) * int(h) / oh, oy * int(h) / oh + 1)
		for ox in 0 ..< ow {
			sx0, sx1 := ox * int(w) / ow, max((ox + 1) * int(w) / ow, ox * int(w) / ow + 1)
			r, gg, b, al, n: u32
			for sy in sy0 ..< min(sy1, int(h)) do for sx in sx0 ..< min(sx1, int(w)) {
				i := (sy * int(w) + sx) * 4
				pa := u32(data[i + 3])
				r += u32(data[i]) * pa / 255; gg += u32(data[i + 1]) * pa / 255; b += u32(data[i + 2]) * pa / 255
				al += pa; n += 1
			}
			if n == 0 do n = 1
			px[oy * ow + ox] = (al / n) << 24 | (r / n) << 16 | (gg / n) << 8 | (b / n)
		}
	}
	g = Glyph{w = i32(ow), h = i32(oh), xoff = i32(f32(bx) * s), yoff = i32(-f32(by) * s), color = px}
	return
}

// Layout is in logical pixels, drawing in buffer pixels: on a scale-2 output the font is
// re-rasterised at twice the size. Shaped runs and glyphs are cached per size, so drop them.
font_resize :: proc(f: ^Font, px: f32) {
	if f.info == nil do return
	f.px = px
	f.scale = k4_font_scale_em(f.info, px)
	asc, desc, gap: c.int
	k4_font_vmetrics(f.info, &asc, &desc, &gap)
	f.ascent = math.round(f32(asc) * f.scale)
	f.descent = math.round(f32(-desc) * f.scale)
	f.line_h = f.ascent + f.descent + math.round(f32(gap) * f.scale)
	for _, g in f.glyphs { delete(g.alpha); delete(g.color) }
	clear(&f.glyphs)
	for k, sh in f.shaped { delete(k); delete(sh.glyphs); delete(sh.cp_x) }
	clear(&f.shaped)
}

// Another size of the same face: shares the file and stb state, gets its own caches and shaper.
font_sized :: proc(src: ^Font, px: f32) -> ^Font {
	f := new(Font)
	f.data = src.data
	f.index = src.index
	f.info = src.info
	f.fallback = src.fallback
	f.base_px = px
	font_resize(f, px)
	if src.shaper != nil {
		f.alloc = context.allocator
		fn, data_ptr := kbts.AllocatorFromOdinAllocator(&f.alloc)
		f.shaper = kbts.CreateShapeContext(fn, data_ptr)
		if f.shaper != nil do kbts.ShapePushFontFromMemory(f.shaper, f.data, c.int(f.index))
	}
	return f
}
