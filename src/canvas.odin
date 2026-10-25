package k4

import "core:math"

// ARGB8888 premultiplied, as wl_shm's argb8888 expects.
Canvas :: struct {
	px:   []u32,
	w, h: int,
}

argb :: proc(rgb: u32, a: u8) -> u32 { return u32(a) << 24 | rgb & 0xffffff }

@(private)
blend :: #force_inline proc(dst: ^u32, color: u32, cov: f32) {
	a := f32(color >> 24) / 255 * cov
	if a <= 0 do return
	d := dst^
	ia := 1 - a
	r := f32(color >> 16 & 0xff) * a + f32(d >> 16 & 0xff) * ia
	g := f32(color >> 8 & 0xff) * a + f32(d >> 8 & 0xff) * ia
	b := f32(color & 0xff) * a + f32(d & 0xff) * ia
	o := a * 255 + f32(d >> 24) * ia
	dst^ = u32(o + 0.5) << 24 | u32(r + 0.5) << 16 | u32(g + 0.5) << 8 | u32(b + 0.5)
}

canvas_clear :: proc(cv: ^Canvas) { for &p in cv.px do p = 0 }

fill_rect :: proc(cv: ^Canvas, x, y, w, h: int, color: u32) {
	x0, y0 := max(x, 0), max(y, 0)
	x1, y1 := min(x + w, cv.w), min(y + h, cv.h)
	for yy in y0 ..< y1 do for xx in x0 ..< x1 do blend(&cv.px[yy * cv.w + xx], color, 1)
}

@(private)
rr_dist :: #force_inline proc(px, py, cx, cy, hw, hh, r: f32) -> f32 {
	qx := abs(px - cx) - (hw - r)
	qy := abs(py - cy) - (hh - r)
	return math.sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - r
}

// Rounded rectangle with an optional border, anti-aliased with a signed distance.
rounded_rect :: proc(cv: ^Canvas, x, y, w, h: int, radius: f32, fill: u32, border: f32 = 0, border_color: u32 = 0) {
	cx, cy := f32(x) + f32(w) / 2, f32(y) + f32(h) / 2
	hw, hh := f32(w) / 2, f32(h) / 2
	r := min(radius, min(hw, hh))
	for yy in max(y, 0) ..< min(y + h, cv.h) {
		for xx in max(x, 0) ..< min(x + w, cv.w) {
			d := rr_dist(f32(xx) + 0.5, f32(yy) + 0.5, cx, cy, hw, hh, r)
			outer := clamp(0.5 - d, 0, 1)
			if outer <= 0 do continue
			p := &cv.px[yy * cv.w + xx]
			if border > 0 {
				inner := clamp(0.5 - (d + border), 0, 1)
				if fill >> 24 != 0 do blend(p, fill, inner)
				blend(p, border_color, outer - inner)
			} else {
				blend(p, fill, outer)
			}
		}
	}
}

// 8-bit coverage mask (a glyph), clipped to [clip_x0, clip_x1).
blit_mask :: proc(cv: ^Canvas, alpha: []u8, w, h, x, y: int, color: u32, clip_x0 := 0, clip_x1 := max(int)) {
	for gy in 0 ..< h {
		yy := y + gy
		if yy < 0 || yy >= cv.h do continue
		for gx in 0 ..< w {
			xx := x + gx
			if xx < max(clip_x0, 0) || xx >= min(clip_x1, cv.w) do continue
			a := alpha[gy * w + gx]
			if a != 0 do blend(&cv.px[yy * cv.w + xx], color, f32(a) / 255)
		}
	}
}

// Premultiplied ARGB image.
blit_image :: proc(cv: ^Canvas, img: []u32, w, h, x, y: int) {
	for gy in 0 ..< h {
		yy := y + gy
		if yy < 0 || yy >= cv.h do continue
		for gx in 0 ..< w {
			xx := x + gx
			if xx < 0 || xx >= cv.w do continue
			s := img[gy * w + gx]
			sa := f32(s >> 24) / 255
			if sa <= 0 do continue
			d := &cv.px[yy * cv.w + xx]
			ia := 1 - sa
			dd := d^
			r := f32(s >> 16 & 0xff) + f32(dd >> 16 & 0xff) * ia
			g := f32(s >> 8 & 0xff) + f32(dd >> 8 & 0xff) * ia
			b := f32(s & 0xff) + f32(dd & 0xff) * ia
			o := f32(s >> 24) + f32(dd >> 24) * ia
			d^ = u32(min(o, 255)) << 24 | u32(min(r, 255)) << 16 | u32(min(g, 255)) << 8 | u32(min(b, 255))
		}
	}
}

// Straight RGBA bytes for PNG output (--dry-run).
canvas_rgba :: proc(cv: ^Canvas, allocator := context.allocator) -> []u8 {
	out := make([]u8, cv.w * cv.h * 4, allocator)
	for p, i in cv.px {
		a := p >> 24
		un :: proc(c, a: u32) -> u8 { return a == 0 ? 0 : u8(min(c * 255 / a, 255)) }
		out[i * 4 + 0] = un(p >> 16 & 0xff, a)
		out[i * 4 + 1] = un(p >> 8 & 0xff, a)
		out[i * 4 + 2] = un(p & 0xff, a)
		out[i * 4 + 3] = u8(a)
	}
	return out
}
