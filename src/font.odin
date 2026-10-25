package k4

import "base:runtime"
import "core:c"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import kbts "vendor_k4:kb_text_shape"

// A font face: kb_text_shape shapes (ligatures, kerning), stb_truetype rasterises.
// Glyphs the main font lacks (id 0) come from a fallback face, unshaped.
Font :: struct {
	data:      []u8,
	info:      rawptr,
	shaper:    ^kbts.shape_context,
	px:        f32, // em size in pixels
	scale:     f32, // font units -> pixels
	ascent:    f32,
	descent:   f32,
	line_h:    f32,
	fallback:  ^Font,
	glyphs:    map[Glyph_Key]Glyph,
	shaped:    map[string]Shaped,
	alloc:     runtime.Allocator, // kept alive for kb_text_shape
}

Glyph_Key :: struct { face: u8, id: u16, sub: u8 }
Glyph :: struct { w, h, xoff, yoff: i32, alpha: []u8 }

Shaped_Glyph :: struct {
	face:     u8, // 0 main, 1 fallback
	id:       u16,
	x:        f32, // pen position in px
	cp_index: i32,
}
Shaped :: struct {
	glyphs: []Shaped_Glyph,
	width:  f32,
	cp_x:   []f32, // x where each codepoint starts, len = codepoints + 1
}

// fc-match picks the file the same way every other app on the desktop does.
font_file :: proc(family: string) -> (path: string, index: int, ok: bool) {
	state, out, _, err := os.process_exec({command = {"fc-match", "-f", "%{file}\n%{index}", family}}, context.allocator)
	if err != nil || !state.success do return
	lines := strings.split_lines(string(out), context.temp_allocator)
	if len(lines) == 0 || len(lines[0]) == 0 do return
	path = lines[0]
	if len(lines) > 1 do index, _ = strconv.parse_int(lines[1])
	return path, index, true
}

font_load :: proc(f: ^Font, family: string, px: f32, shape: bool) -> bool {
	path, index, ok := font_file(family)
	if !ok do return false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	f.data = data
	f.info = k4_font_new(raw_data(data), c.int(index))
	if f.info == nil do return false
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
fallback_glyph :: proc(f: ^Font, cp: rune) -> (id: u16, adv: f32, ok: bool) {
	fb := f.fallback
	if fb == nil || fb.info == nil do return
	g := k4_font_glyph_index(fb.info, c.int(cp))
	if g == 0 do return
	a, l: c.int
	k4_font_glyph_hmetrics(fb.info, g, &a, &l)
	return u16(g), f32(a) * fb.scale, true
}

// Shaped text is cached per string: rows rarely change between frames.
shape :: proc(f: ^Font, text: string) -> Shaped {
	if s, ok := f.shaped[text]; ok do return s
	ncp := utf8.rune_count_in_string(text)
	out := make([dynamic]Shaped_Glyph, 0, ncp)
	x: f32
	if f.shaper != nil && len(text) > 0 {
		kbts.ShapeBegin(f.shaper, .DONT_KNOW, .DONT_KNOW)
		kbts.ShapeUtf8(f.shaper, text, .CODEPOINT_INDEX)
		kbts.ShapeEnd(f.shaper)
		for run in kbts.ShapeRun(f.shaper) {
			run := run
			for g in kbts.GlyphIteratorNext(&run.Glyphs) {
				if g.Id == 0 {
					if id, adv, ok := fallback_glyph(f, g.Codepoint); ok {
						append(&out, Shaped_Glyph{1, id, x, i32(g.UserIdOrCodepointIndex)})
						x += adv
						continue
					}
				}
				append(&out, Shaped_Glyph{0, g.Id, x + f32(g.OffsetX) * f.scale, i32(g.UserIdOrCodepointIndex)})
				x += f32(g.AdvanceX) * f.scale
			}
		}
	} else {
		i: i32
		for r in text {
			g := k4_font_glyph_index(f.info, c.int(r))
			a, l: c.int
			if g == 0 {
				if id, adv, ok := fallback_glyph(f, r); ok {
					append(&out, Shaped_Glyph{1, id, x, i}); x += adv; i += 1; continue
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

glyph_bitmap :: proc(f: ^Font, face: u8, id: u16, x: f32) -> (Glyph, f32) {
	frac := x - math.floor(x)
	sub := u8(frac * 4) & 3
	key := Glyph_Key{face, id, sub}
	src := face == 1 && f.fallback != nil ? f.fallback : f
	if g, ok := f.glyphs[key]; ok do return g, math.floor(x)
	w, h, xo, yo: c.int
	bm := k4_font_glyph_bitmap(src.info, src.scale, f32(sub) / 4, c.int(id), &w, &h, &xo, &yo)
	g := Glyph{w = i32(w), h = i32(h), xoff = i32(xo), yoff = i32(yo)}
	if bm != nil {
		g.alpha = make([]u8, int(w * h))
		copy(g.alpha, bm[:w * h])
		k4_free(bm)
	}
	f.glyphs[key] = g
	return g, math.floor(x)
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
	for _, g in f.glyphs do delete(g.alpha)
	clear(&f.glyphs)
	for k, sh in f.shaped { delete(k); delete(sh.glyphs); delete(sh.cp_x) }
	clear(&f.shaped)
	if f.fallback != nil do font_resize(f.fallback, px)
}
