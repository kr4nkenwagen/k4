package tests

import "core:testing"
import "../src/logic"

@(test)
parse_plain_and_icon_rows :: proc(t: ^testing.T) {
	rows := logic.parse_dmenu("one\ntwo\x00icon\x1f/tmp/a.png\n\nfour\r\n", context.temp_allocator)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0].label, "one")
	testing.expect_value(t, rows[1].label, "two")
	testing.expect_value(t, rows[1].icon, "/tmp/a.png")
	testing.expect_value(t, rows[2].label, "")   // empty lines keep their index, like fuzzel
	testing.expect_value(t, rows[3].label, "four")
	testing.expect_value(t, rows[3].index, 3)
}

@(test)
parse_empty_input :: proc(t: ^testing.T) {
	testing.expect_value(t, len(logic.parse_dmenu("", context.temp_allocator)), 0)
	testing.expect_value(t, len(logic.parse_dmenu("\n", context.temp_allocator)), 0) // a lone newline is no rows, not one empty row
}

@(test)
match_ranks_word_starts_and_runs :: proc(t: ^testing.T) {
	rows := logic.parse_dmenu("Style › Background picker\nBluetooth\nSystem › Lock\nbackground.conf", context.temp_allocator)
	out: [dynamic]logic.Match
	out.allocator = context.temp_allocator
	logic.match_rows(rows, "bg", &out, context.temp_allocator)
	testing.expect(t, len(out) >= 2)
	logic.match_rows(rows, "back", &out, context.temp_allocator)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].row, 3) // prefix run beats a mid-string word
	logic.match_rows(rows, "sys lock", &out, context.temp_allocator)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].row, 2)
	testing.expect_value(t, len(out[0].positions), 7)
}

@(test)
match_empty_query_keeps_order :: proc(t: ^testing.T) {
	rows := logic.parse_dmenu("c\nb\na", context.temp_allocator)
	out: [dynamic]logic.Match
	out.allocator = context.temp_allocator
	logic.match_rows(rows, "   ", &out, context.temp_allocator)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out[0].row, 0)
	testing.expect_value(t, out[2].row, 2)
}

@(test)
match_is_case_insensitive_and_unicode :: proc(t: ^testing.T) {
	rows := logic.parse_dmenu("Ångström\nANGLE", context.temp_allocator)
	out: [dynamic]logic.Match
	out.allocator = context.temp_allocator
	logic.match_rows(rows, "ång", &out, context.temp_allocator)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].row, 0)
}

@(test)
theme_reads_omarchy_colors :: proc(t: ^testing.T) {
	th := logic.theme_from_colors(`
mode = "dark"
accent = "#7aa2f7"
background = "#1a1b26"
foreground = "#a9b1d6"
# comment = "#ffffff"
selection = "#292e42"
`)
	testing.expect_value(t, th.accent, 0x7aa2f7)
	testing.expect_value(t, th.bg, 0x1a1b26)
	testing.expect_value(t, th.fg_bright, 0xa9b1d6) // falls back to foreground
	testing.expect_value(t, th.selection, 0x292e42)
}
