package logic

import "core:strings"

// One entry from stdin, in fuzzel/rofi dmenu format:
//   label[\0icon\x1fPATH[\x1fkey\x1fvalue...]]
Row :: struct {
	label: string,
	icon:  string,
	index: int, // position in the input, what --index prints
}

parse_dmenu :: proc(data: string, allocator := context.allocator) -> []Row {
	rows := make([dynamic]Row, 0, 64, allocator)
	text := data
	if strings.has_suffix(text, "\n") do text = text[:len(text) - 1]
	if len(text) == 0 do return rows[:]
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_suffix(line, "\r")
		row := Row{index = len(rows)}
		if nul := strings.index_byte(l, 0); nul >= 0 {
			row.label = l[:nul]
			fields := strings.split(l[nul + 1:], "\x1f", context.temp_allocator)
			for i := 0; i + 1 < len(fields); i += 2 {
				if fields[i] == "icon" do row.icon = fields[i + 1]
			}
		} else {
			row.label = l
		}
		append(&rows, row)
	}
	return rows[:]
}
