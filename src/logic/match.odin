package logic

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// A row that matches the query, with the matched codepoint indices for highlighting.
Match :: struct {
	row:       int,
	score:     int,
	positions: []int,
}

// Space-separated terms, each a case-insensitive fuzzy subsequence; every term must match.
// Scoring rewards consecutive runs, word starts and early matches (fzf v1 style).
match_rows :: proc(rows: []Row, query: string, out: ^[dynamic]Match, allocator := context.allocator) {
	clear(out)
	terms := strings.fields(query, context.temp_allocator)
	if len(terms) == 0 {
		for r, i in rows do append(out, Match{row = i})
		return
	}
	term_runes := make([][]rune, len(terms), context.temp_allocator)
	for t, i in terms do term_runes[i] = lower_runes(t, context.temp_allocator)

	pos_buf := make([dynamic]int, 0, 32, context.temp_allocator)
	for r, i in rows {
		label := utf8.string_to_runes(r.label, context.temp_allocator)
		lower := make([]rune, len(label), context.temp_allocator)
		for c, j in label do lower[j] = unicode.to_lower(c)
		total := 0
		clear(&pos_buf)
		ok := true
		for t in term_runes {
			s, matched := score_term(label, lower, t, &pos_buf)
			if !matched { ok = false; break }
			total += s
		}
		if !ok do continue
		positions := slice.clone(pos_buf[:], allocator)
		slice.sort(positions)
		append(out, Match{row = i, score = total, positions = positions})
	}
	slice.stable_sort_by(out[:], proc(a, b: Match) -> bool { return a.score > b.score })
}

lower_runes :: proc(s: string, allocator := context.allocator) -> []rune {
	rs := utf8.string_to_runes(s, allocator)
	for &c in rs do c = unicode.to_lower(c)
	return rs
}

@(private)
is_boundary :: proc(label: []rune, i: int) -> bool {
	if i == 0 do return true
	prev, cur := label[i - 1], label[i]
	if !(unicode.is_letter(prev) || unicode.is_digit(prev)) do return true
	return unicode.is_lower(prev) && unicode.is_upper(cur) // camelCase
}

// Best greedy alignment over every possible start of the first rune.
score_term :: proc(label, lower, term: []rune, positions: ^[dynamic]int) -> (best: int, ok: bool) {
	if len(term) == 0 do return 0, true
	best = -1
	best_pos := make([]int, len(term), context.temp_allocator)
	cur_pos := make([]int, len(term), context.temp_allocator)
	for start in 0 ..< len(lower) {
		if lower[start] != term[0] do continue
		score, k, last := 0, 0, -1
		for i := start; i < len(lower) && k < len(term); i += 1 {
			if lower[i] != term[k] do continue
			s := 16
			if last >= 0 && i == last + 1 do s += 12          // consecutive
			if is_boundary(label, i) do s += 10               // word start
			if last >= 0 do s -= min(i - last - 1, 8)         // gap penalty
			if k == 0 && i == 0 do s += 6                     // prefix
			score += s
			cur_pos[k] = i
			last = i
			k += 1
		}
		if k < len(term) do break // later starts cannot match either
		score -= min(start, 10) / 2
		if score > best {
			best = score
			copy(best_pos, cur_pos)
		}
	}
	if best < 0 do return 0, false
	for p in best_pos do if !slice.contains(positions[:], p) do append(positions, p)
	return best, true
}
