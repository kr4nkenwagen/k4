package logic

import "core:strconv"
import "core:strings"

// Colours as 0xRRGGBB, resolved from an Omarchy colors.toml with the same fallbacks
// Omarchy's templates use.
Theme :: struct {
	bg, fg, fg_bright, fg_dim, accent, selection, muted, red, blue, yellow, green, cyan, magenta, orange: u32,
}

DEFAULT_THEME :: Theme{ // Tokyo Night
	bg = 0x1a1b26, fg = 0xa9b1d6, fg_bright = 0xc0caf5, fg_dim = 0x565f89,
	accent = 0x7aa2f7, selection = 0x292e42, muted = 0x414868, red = 0xf7768e, blue = 0x7aa2f7, yellow = 0xe0af68, green = 0x9ece6a, cyan = 0x7dcfff, magenta = 0xbb9af7, orange = 0xff9e64,
}

parse_colors_toml :: proc(data: string, allocator := context.temp_allocator) -> map[string]u32 {
	m := make(map[string]u32, 32, allocator)
	text := data
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 do continue
		key := strings.trim_space(l[:eq])
		val := strings.trim(strings.trim_space(l[eq + 1:]), "\"'")
		if len(val) == 7 && val[0] == '#' {
			if v, ok := strconv.parse_u64_of_base(val[1:], 16); ok do m[key] = u32(v)
		}
	}
	return m
}

theme_from_colors :: proc(data: string) -> Theme {
	m := parse_colors_toml(data)
	t := DEFAULT_THEME
	pick :: proc(m: map[string]u32, keys: ..string) -> (u32, bool) {
		for k in keys do if v, ok := m[k]; ok do return v, true
		return 0, false
	}
	if v, ok := pick(m, "background", "color0"); ok do t.bg = v
	if v, ok := pick(m, "foreground", "color7"); ok do t.fg = v
	if v, ok := pick(m, "bright_foreground", "color15", "foreground"); ok do t.fg_bright = v
	if v, ok := pick(m, "dark_foreground", "muted", "color8"); ok do t.fg_dim = v
	if v, ok := pick(m, "accent", "blue", "color4"); ok do t.accent = v
	if v, ok := pick(m, "selection", "selection_background", "lighter_background", "muted"); ok do t.selection = v
	if v, ok := pick(m, "muted", "color8", "dark_foreground"); ok do t.muted = v
	if v, ok := pick(m, "red", "color1"); ok do t.red = v
	if v, ok := pick(m, "blue", "color4"); ok do t.blue = v
	if v, ok := pick(m, "yellow", "color3"); ok do t.yellow = v
	if v, ok := pick(m, "green", "color2"); ok do t.green = v
	if v, ok := pick(m, "cyan", "color6"); ok do t.cyan = v
	if v, ok := pick(m, "magenta", "color5"); ok do t.magenta = v
	if v, ok := pick(m, "orange", "yellow", "color3"); ok do t.orange = v
	return t
}
