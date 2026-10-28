package logic

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// The design's calculator: + - * / % ^ ( ), unary minus, 0x hex, 1e3, pi, e,
// sqrt sin cos tan log ln abs round floor ceil. Same grammar as the mockup, plus:
//   percent: "15% of 2400" = 360, "2400 + 15%" = 2760 ("10 % 4" between numbers stays modulo)
//   units:   "5 km in mi", "30 c to f", "2 GiB in MB", "90 min in h" (length, mass, time, data,
//            temperature; the answer carries the unit)
Calc :: struct { s: string, i: int, err: bool, unary_pct, term_pct: bool }

calc_eval :: proc(src: string) -> (out: string, ok: bool) {
	if v, unit, conv := calc_convert(src); conv do return strings.concatenate({calc_format(v), " ", unit}, context.temp_allocator), true
	v, good := calc_value(src)
	if !good do return "", false
	return calc_format(v), true
}

// The number as the calculator shows it: whole numbers plain, else 10 significant digits.
calc_format :: proc(v: f64) -> string {
	if v == math.trunc(v) && abs(v) < 1e15 do return fmt.tprintf("%d", i64(v))
	s := fmt.tprintf("%.10g", v) // like toPrecision(10) with trailing zeros dropped
	if strings.contains(s, ".") && !strings.contains(s, "e") do s = strings.trim_right(strings.trim_right(s, "0"), ".")
	return s
}

// The expression's value (no units).
calc_value :: proc(src: string) -> (f64, bool) {
	b := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(src, context.temp_allocator) {
		switch r {
		case ' ', '\t':
		case '×': strings.write_byte(&b, '*')
		case '÷': strings.write_byte(&b, '/')
		case '−': strings.write_byte(&b, '-')
		case: strings.write_rune(&b, r)
		}
	}
	c := Calc{s = strings.to_string(b)}
	if len(c.s) == 0 do return 0, false
	v := calc_expr(&c)
	if c.err || c.i < len(c.s) || math.is_nan(v) || math.is_inf(v) do return 0, false
	return v, true
}

// ---------- units ----------

@(private)
Unit :: struct { dim: u8, f: f64 } // dim: l length (m), m mass (kg), t time (s), d data (B), c temperature

@(private)
unit_of :: proc(name: string) -> (Unit, bool) {
	switch name {
	case "m", "meter", "meters", "metre", "metres": return {'l', 1}, true
	case "km": return {'l', 1000}, true
	case "cm": return {'l', 0.01}, true
	case "mm": return {'l', 0.001}, true
	case "um", "µm": return {'l', 1e-6}, true
	case "mi", "mile", "miles": return {'l', 1609.344}, true
	case "yd", "yard", "yards": return {'l', 0.9144}, true
	case "ft", "foot", "feet": return {'l', 0.3048}, true
	case "inch", "inches", "\"": return {'l', 0.0254}, true
	case "nmi": return {'l', 1852}, true
	case "kg": return {'m', 1}, true
	case "g", "gram", "grams": return {'m', 0.001}, true
	case "mg": return {'m', 1e-6}, true
	case "t", "tonne", "tonnes": return {'m', 1000}, true
	case "lb", "lbs", "pound", "pounds": return {'m', 0.45359237}, true
	case "oz", "ounce", "ounces": return {'m', 0.028349523125}, true
	case "st", "stone": return {'m', 6.35029318}, true
	case "ms": return {'t', 0.001}, true
	case "s", "sec", "secs", "second", "seconds": return {'t', 1}, true
	case "min", "mins", "minute", "minutes": return {'t', 60}, true
	case "h", "hr", "hrs", "hour", "hours": return {'t', 3600}, true
	case "d", "day", "days": return {'t', 86400}, true
	case "wk", "week", "weeks": return {'t', 604800}, true
	case "b", "byte", "bytes": return {'d', 1}, true
	case "kb": return {'d', 1e3}, true
	case "mb": return {'d', 1e6}, true
	case "gb": return {'d', 1e9}, true
	case "tb": return {'d', 1e12}, true
	case "kib": return {'d', 1024}, true
	case "mib": return {'d', 1048576}, true
	case "gib": return {'d', 1073741824}, true
	case "tib": return {'d', 1099511627776}, true
	case "c", "°c", "celsius": return {'c', 0}, true
	case "f", "°f", "fahrenheit": return {'c', 1}, true
	case "k", "kelvin": return {'c', 2}, true
	}
	return {}, false
}

// "<expression> <unit> in|to <unit>": the value in the second unit, and that unit as typed.
@(private)
calc_convert :: proc(src: string) -> (v: f64, unit: string, ok: bool) {
	low := strings.to_lower(strings.trim_space(src), context.temp_allocator)
	sep := strings.last_index(low, " in ")
	if t := strings.last_index(low, " to "); t > sep do sep = t
	if sep < 0 do return
	left, right := strings.trim_space(low[:sep]), strings.trim_space(low[sep + 4:])
	// the left side ends in its unit, the number before it (with or without a space)
	j := len(left)
	for j > 0 && (left[j - 1] >= 'a' && left[j - 1] <= 'z' || left[j - 1] == '"' || left[j - 1] == 0xb0 || left[j - 1] == 0xc2 || left[j - 1] == 0xb5) do j -= 1
	if j == len(left) || j == 0 do return
	from, ok1 := unit_of(left[j:])
	to, ok2 := unit_of(right)
	if !ok1 || !ok2 || from.dim != to.dim do return
	x, good := calc_value(left[:j])
	if !good do return
	if from.dim == 'c' {
		kel: f64
		switch from.f { case 0: kel = x + 273.15; case 1: kel = (x - 32) * 5 / 9 + 273.15; case: kel = x }
		switch to.f { case 0: v = kel - 273.15; case 1: v = (kel - 273.15) * 9 / 5 + 32; case: v = kel }
	} else do v = x * from.f / to.f
	unit = strings.trim_space(src)[sep + 4:]
	unit = strings.trim_space(unit)
	return v, unit, true
}

@(private) peek :: proc(c: ^Calc) -> u8 { return c.i < len(c.s) ? c.s[c.i] : 0 }

@(private)
calc_expr :: proc(c: ^Calc) -> f64 {
	v := calc_term(c)
	for peek(c) == '+' || peek(c) == '-' {
		op := peek(c); c.i += 1
		r := calc_term(c)
		if c.term_pct do r = v * r // "2400 + 15%": fifteen percent of what came before
		v = op == '+' ? v + r : v - r
	}
	return v
}
@(private)
calc_term :: proc(c: ^Calc) -> f64 {
	c.unary_pct = false
	v := calc_unary(c)
	single := c.unary_pct
	for peek(c) == '*' || peek(c) == '/' || peek(c) == '%' || strings.has_prefix(c.s[c.i:], "of") {
		if strings.has_prefix(c.s[c.i:], "of") { // "15% of 2400"
			c.i += 2
			v *= calc_unary(c)
			single = false
			continue
		}
		op := peek(c); c.i += 1
		r := calc_unary(c)
		single = false
		switch op {
		case '*': v *= r
		case '/': v /= r
		case '%': v = math.mod(v, r)
		}
	}
	c.term_pct = single
	return v
}
@(private)
calc_unary :: proc(c: ^Calc) -> f64 {
	if peek(c) == '-' { c.i += 1; return -calc_unary(c) }
	if peek(c) == '+' { c.i += 1; return calc_unary(c) }
	b := calc_atom(c)
	if peek(c) == '%' { // percent when nothing that could be a modulo's right side follows
		n := c.i + 1 < len(c.s) ? c.s[c.i + 1] : 0
		if n == 0 || n == '+' || n == '-' || n == '*' || n == '/' || n == ')' || strings.has_prefix(c.s[c.i + 1:], "of") {
			c.i += 1
			c.unary_pct = true
			return b / 100
		}
	}
	if peek(c) == '^' { c.i += 1; return math.pow(b, calc_unary(c)) }
	return b
}
@(private)
calc_atom :: proc(c: ^Calc) -> f64 {
	rest := c.s[c.i:]
	if strings.has_prefix(rest, "0x") {
		j := 2
		for j < len(rest) && strings.index_byte("0123456789abcdef", rest[j]) >= 0 do j += 1
		if j > 2 {
			v, _ := strconv.parse_u64_of_base(rest[2:j], 16)
			c.i += j
			return f64(v)
		}
	}
	if len(rest) > 0 && (rest[0] >= '0' && rest[0] <= '9' || rest[0] == '.') {
		j := 0
		for j < len(rest) && (rest[j] >= '0' && rest[j] <= '9' || rest[j] == '.') do j += 1
		if j < len(rest) && rest[j] == 'e' {
			k := j + 1
			if k < len(rest) && (rest[k] == '+' || rest[k] == '-') do k += 1
			if k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
				for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' do k += 1
				j = k
			}
		}
		v, ok := strconv.parse_f64(rest[:j])
		if !ok { c.err = true; return 0 }
		c.i += j
		return v
	}
	if peek(c) == '(' {
		c.i += 1
		v := calc_expr(c)
		if peek(c) != ')' { c.err = true; return 0 }
		c.i += 1
		return v
	}
	j := 0
	for j < len(rest) && rest[j] >= 'a' && rest[j] <= 'z' do j += 1
	if j > 0 {
		name := rest[:j]
		c.i += j
		switch name {
		case "pi": return math.PI
		case "e": return math.E
		case "sqrt": return math.sqrt(calc_atom(c))
		case "sin": return math.sin(calc_atom(c))
		case "cos": return math.cos(calc_atom(c))
		case "tan": return math.tan(calc_atom(c))
		case "log": return math.log10(calc_atom(c))
		case "ln": return math.ln(calc_atom(c))
		case "abs": return abs(calc_atom(c))
		case "round": return math.round(calc_atom(c))
		case "floor": return math.floor(calc_atom(c))
		case "ceil": return math.ceil(calc_atom(c))
		}
	}
	c.err = true
	return 0
}
