package k4

import "core:math"

// Line icons drawn from the design's SVG paths (24×24, 2 px round strokes), anti-aliased by the
// distance to each stroke. Only the shapes k4 has no glyph for: the Pi-hole shield (KPihole) and
// the key.

Shape :: enum { None, Shield_On, Shield_Off, Shield_Broken, Shield_Unsafe, Key }

// "shield-on" … as the bar's JSON and the window's data name them.
shape_of :: proc(s: string) -> Shape {
	switch s {
	case "shield-on": return .Shield_On
	case "shield-off": return .Shield_Off
	case "shield-broken": return .Shield_Broken
	case "shield-unsafe": return .Shield_Unsafe
	case "key": return .Key
	}
	return .None
}

@(private = "file")
Seg :: [4]f32 // x0 y0 x1 y1, in the 24-unit box

@(private = "file")
seg_dist :: proc(px, py: f32, s: Seg) -> f32 {
	dx, dy := s[2] - s[0], s[3] - s[1]
	l := dx * dx + dy * dy
	t := l > 0 ? clamp(((px - s[0]) * dx + (py - s[1]) * dy) / l, 0, 1) : 0
	qx, qy := s[0] + t * dx - px, s[1] + t * dy - py
	return math.sqrt(qx * qx + qy * qy)
}

@(private = "file")
cubic :: proc(out: ^[dynamic]Seg, x0, y0, x1, y1, x2, y2, x3, y3: f32) {
	px, py := x0, y0
	for i in 1 ..= 12 {
		t := f32(i) / 12
		u := 1 - t
		x := u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3
		y := u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3
		append(out, Seg{px, py, x, y})
		px, py = x, y
	}
}

// The strokes of a shape (24-unit box); dots: a zero-length segment (round cap).
@(private = "file")
shape_segs :: proc(s: Shape) -> []Seg {
	out := make([dynamic]Seg, 0, 48, context.temp_allocator)
	if s >= .Shield_On && s <= .Shield_Unsafe { // M12 3l8 3v6c0 5-3.5 8-8 9c-4.5-1-8-4-8-9V6z
		append(&out, Seg{12, 3, 20, 6}, Seg{20, 6, 20, 12})
		cubic(&out, 20, 12, 20, 17, 16.5, 20, 12, 21)
		cubic(&out, 12, 21, 7.5, 20, 4, 17, 4, 12)
		append(&out, Seg{4, 12, 4, 6}, Seg{4, 6, 12, 3})
	}
	#partial switch s {
	case .Shield_On: // the hole: a 1.5 circle at the middle
		for i in 0 ..< 12 {
			a0, a1 := f32(i) * math.TAU / 12, f32(i + 1) * math.TAU / 12
			append(&out, Seg{12 + 1.5 * math.cos(a0), 12 + 1.5 * math.sin(a0), 12 + 1.5 * math.cos(a1), 12 + 1.5 * math.sin(a1)})
		}
	case .Shield_Off: append(&out, Seg{10, 9.5, 10, 14.5}, Seg{14, 9.5, 14, 14.5}) // pause bars
	case .Shield_Broken: append(&out, Seg{12.6, 3.3, 10.6, 8.6}, Seg{10.6, 8.6, 13.6, 11.2}, Seg{13.6, 11.2, 11.2, 15.2}, Seg{11.2, 15.2, 12.1, 20.8}) // the crack
	case .Shield_Unsafe: append(&out, Seg{12, 8, 12, 12.5}, Seg{12, 16, 12.01, 16}) // !
	case .Key: // M8 15a4 4 0 1 1 3.5-6H21v3h-2v3h-3v-3h-4.5A4 4 0 0 1 8 15z (the bow as a circle)
		for i in 0 ..< 16 {
			a0, a1 := f32(i) * math.TAU / 16, f32(i + 1) * math.TAU / 16
			append(&out, Seg{8 + 4 * math.cos(a0), 11 + 4 * math.sin(a0), 8 + 4 * math.cos(a1), 11 + 4 * math.sin(a1)})
		}
		append(&out, Seg{11.5, 9, 21, 9}, Seg{21, 9, 21, 12}, Seg{21, 12, 19, 12}, Seg{19, 12, 19, 15}, Seg{19, 15, 16, 15}, Seg{16, 15, 16, 12}, Seg{16, 12, 11.5, 12})
	}
	return out[:]
}

// A shape in a size×size box at (x, y), its strokes 2 units wide (scaled), in color.
shape_draw :: proc(cv: ^Canvas, s: Shape, x, y, size: int, color: u32) {
	if s == .None || size <= 0 do return
	segs := shape_segs(s)
	k := f32(size) / 24
	hw := k // half of the 2-unit stroke
	for yy in max(y, 0) ..< min(y + size, cv.h) do for xx in max(x, 0) ..< min(x + size, cv.w) {
		px, py := (f32(xx - x) + 0.5) / k, (f32(yy - y) + 0.5) / k
		d := f32(1e9)
		for sg in segs do d = min(d, seg_dist(px, py, sg))
		cov := clamp(hw - d * k + 0.5, 0, 1)
		if cov > 0 do blend(&cv.px[yy * cv.w + xx], argb(color, 0xff), cov)
	}
}
