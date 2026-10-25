package logic

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// The design's calculator: + - * / % ^ ( ), unary minus, 0x hex, 1e3, pi, e,
// sqrt sin cos tan log ln abs round floor ceil. Same grammar as the mockup.
Calc :: struct { s: string, i: int, err: bool }

calc_eval :: proc(src: string) -> (out: string, ok: bool) {
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
	if len(c.s) == 0 do return "", false
	v := calc_expr(&c)
	if c.err || c.i < len(c.s) || math.is_nan(v) || math.is_inf(v) do return "", false
	if v == math.trunc(v) && abs(v) < 1e15 do return fmt.tprintf("%d", i64(v)), true
	s := fmt.tprintf("%.10g", v) // like toPrecision(10) with trailing zeros dropped
	if strings.contains(s, ".") && !strings.contains(s, "e") do s = strings.trim_right(strings.trim_right(s, "0"), ".")
	return s, true
}

@(private) peek :: proc(c: ^Calc) -> u8 { return c.i < len(c.s) ? c.s[c.i] : 0 }

@(private)
calc_expr :: proc(c: ^Calc) -> f64 {
	v := calc_term(c)
	for peek(c) == '+' || peek(c) == '-' {
		op := peek(c); c.i += 1
		r := calc_term(c)
		v = op == '+' ? v + r : v - r
	}
	return v
}
@(private)
calc_term :: proc(c: ^Calc) -> f64 {
	v := calc_unary(c)
	for peek(c) == '*' || peek(c) == '/' || peek(c) == '%' {
		op := peek(c); c.i += 1
		r := calc_unary(c)
		switch op {
		case '*': v *= r
		case '/': v /= r
		case '%': v = math.mod(v, r)
		}
	}
	return v
}
@(private)
calc_unary :: proc(c: ^Calc) -> f64 {
	if peek(c) == '-' { c.i += 1; return -calc_unary(c) }
	if peek(c) == '+' { c.i += 1; return calc_unary(c) }
	b := calc_atom(c)
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
