package k4

import "core:c"

foreign import k4c "../lib/k4c.a"

@(default_calling_convention = "c")
foreign k4c {
	k4_font_new            :: proc(data: [^]u8, index: c.int) -> rawptr ---
	k4_font_scale_em       :: proc(f: rawptr, px: f32) -> f32 ---
	k4_font_vmetrics       :: proc(f: rawptr, asc, desc, gap: ^c.int) ---
	k4_font_glyph_index    :: proc(f: rawptr, cp: c.int) -> c.int ---
	k4_font_glyph_hmetrics :: proc(f: rawptr, g: c.int, adv, lsb: ^c.int) ---
	k4_font_glyph_bitmap   :: proc(f: rawptr, scale, shift_x: f32, g: c.int, w, h, xoff, yoff: ^c.int) -> [^]u8 ---
	k4_free                :: proc(p: rawptr) ---
	k4_image_load          :: proc(path: cstring, w, h: ^c.int) -> [^]u8 ---
	k4_png_write           :: proc(path: cstring, w, h: c.int, rgba: rawptr) -> c.int ---
}
