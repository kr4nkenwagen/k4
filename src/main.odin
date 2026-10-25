package k4

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "logic"

VERSION :: "0.1.0"

USAGE :: `k4: a dmenu-style launcher for wlroots compositors (layer-shell), fuzzel-compatible.
Rows come from stdin, one per line; "label\0icon\x1f/path/to.png" adds a picture.

  --dmenu                 accepted for fuzzel compatibility (k4 is always dmenu)
  --index                 print the chosen row's index instead of its text
  -p, --prompt TEXT       prompt shown before the query
  --prompt-only TEXT      prompt with no rows (free text input, stdin not read)
  --password[=CHAR]       hide typed text
  -l, --lines N           visible rows (default 15)
  -w, --width N           width in characters (default: fit the rows)
  --anchor WHERE          center top top-left top-right bottom bottom-left bottom-right left right
  --margin PX             distance from the anchored edges
  --font FAMILY           default: ~/.local/state/omarchy/current/font.name, else monospace
  --font-size PT          default 12
  --row-height PX, --icon-size PX, --radius PX, --border PX
  --theme FILE            colors.toml (default: the current Omarchy-format theme)
  --no-icons              ignore icon fields
  --menu                  two-pane launcher (sections, actions, views); input format in menu.odin
  --open ID               menu mode: start inside the section with this id
  --config FILE           accepted and ignored (fuzzel compatibility)
  --dry-run FILE.png      render one frame to a PNG without Wayland, then print the selection
  --keys KEYS, --select N keys pressed before the first frame: text plus <down> <up> <left>
                          <right> <enter> <esc> <tab> <bs> <alt-x> <ctrl-x>; then move the selection
  --scale N               dry runs: buffer scale

Exit status: 0 with the choice on stdout, 1 when cancelled.
`

parse_args :: proc(args: []string) -> (o: Options, prompt_only: bool, ok: bool) {
	o.prompt = "❯ "
	o.password_char = "*"
	o.lines = 15
	o.font_pt = 12
	o.border = 2
	o.scale = 1
	o.anchor = .Center
	i := 0
	value :: proc(args: []string, i: ^int, inline: string, has_inline: bool) -> string {
		if has_inline do return inline
		i^ += 1
		return i^ < len(args) ? args[i^] : ""
	}
	for ; i < len(args); i += 1 {
		a := args[i]
		name, inline := a, ""
		has_inline := false
		if strings.has_prefix(a, "--") {
			if eq := strings.index_byte(a, '='); eq >= 0 { name, inline, has_inline = a[:eq], a[eq + 1:], true }
		}
		switch name {
		case "--dmenu":
		case "--index": o.index_mode = true
		case "-p", "--prompt": o.prompt = value(args, &i, inline, has_inline)
		case "--prompt-only": o.prompt = value(args, &i, inline, has_inline); o.lines = 0; prompt_only = true
		case "--password":
			o.password = true
			if has_inline && len(inline) > 0 do o.password_char = inline
		case "-l", "--lines": o.lines, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "-w", "--width": o.width_chars, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--anchor":
			switch value(args, &i, inline, has_inline) {
			case "top": o.anchor = .Top
			case "top-left": o.anchor = .Top_Left
			case "top-right": o.anchor = .Top_Right
			case "bottom": o.anchor = .Bottom
			case "bottom-left": o.anchor = .Bottom_Left
			case "bottom-right": o.anchor = .Bottom_Right
			case "left": o.anchor = .Left
			case "right": o.anchor = .Right
			case: o.anchor = .Center
			}
		case "--margin": o.margin, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--font": o.font = value(args, &i, inline, has_inline)
		case "--font-size": o.font_pt, _ = strconv.parse_f32(value(args, &i, inline, has_inline))
		case "--row-height": o.row_height, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--icon-size": o.icon_size, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--radius": o.radius, _ = strconv.parse_f32(value(args, &i, inline, has_inline))
		case "--border": o.border, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--theme": o.theme_file = value(args, &i, inline, has_inline)
		case "--no-icons": o.no_icons = true
		case "--menu": o.menu = true
		case "--open": o.open = value(args, &i, inline, has_inline)
		case "--config": _ = value(args, &i, inline, has_inline)
		case "--dry-run": o.dry_run = value(args, &i, inline, has_inline)
		case "--keys": o.keys = value(args, &i, inline, has_inline)
		case "--select": o.select, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "--scale": o.scale, _ = strconv.parse_int(value(args, &i, inline, has_inline))
		case "-h", "--help": fmt.print(USAGE); os.exit(0)
		case "-v", "--version": fmt.println("k4", VERSION); os.exit(0)
		case:
			fmt.eprintfln("k4: unknown option %q (k4 --help)", a)
			return o, prompt_only, false
		}
	}
	o.lines = max(o.lines, 0)
	o.scale = max(o.scale, 1)
	return o, prompt_only, true
}

state_file :: proc(name: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.local/state/omarchy/current/", name}, context.temp_allocator)
}

main :: proc() {
	opts, prompt_only, ok := parse_args(os.args[1:])
	if !ok do os.exit(2)
	a := new(App)
	a.opts = opts

	// theme
	theme_path := opts.theme_file != "" ? opts.theme_file : state_file("theme/colors.toml")
	a.theme = logic.DEFAULT_THEME
	if data, err := os.read_entire_file(theme_path, context.temp_allocator); err == nil {
		a.theme = logic.theme_from_colors(string(data))
	}

	// font: the desktop font chosen with sway-font-set, else monospace
	family := opts.font
	if family == "" {
		if data, err := os.read_entire_file(state_file("font.name"), context.temp_allocator); err == nil {
			family = strings.trim_space(string(data))
		}
	}
	if family == "" do family = "monospace"
	a.family = family
	px := opts.font_pt * 4 / 3
	a.font_px = px
	if !font_load(&a.font, family, px, true) {
		fmt.eprintfln("k4: cannot load font %q", family)
		os.exit(2)
	}
	a.font.fallback = new(Fallbacks) // filled per missing character

	// rows, or the menu tree
	if opts.menu {
		data, _ := os.read_entire_file(os.stdin, context.allocator)
		menu_setup(a, string(data))
		if opts.open != "" do for s, i in a.menu.sections do if s.id == opts.open { menu_enter(a, i); break }
	} else if !prompt_only {
		data, _ := os.read_entire_file(os.stdin, context.allocator)
		a.rows = logic.parse_dmenu(string(data))
	}
	app_rematch(a)

	if opts.dry_run != "" {
		// same path as Wayland: layout at 1x, then the fonts at the buffer scale
		if a.menu != nil do menu_load_all(a)
		else do app_layout(a)
		press_keys(a, opts.keys)
		if a.menu != nil do menu_load_all(a) // a stay action started by the keys, and the reload after it
		if a.menu == nil do app_move(a, opts.select)
		s := opts.scale
		if s != 1 {
			font_resize(&a.font, px * f32(s))
			for f in a.fonts do font_resize(f, f.base_px * f32(s))
		}
		cv := Canvas{make([]u32, a.width * a.height * s * s), a.width * s, a.height * s}
		app_draw(a, &cv, s)
		rgba := canvas_rgba(&cv)
		path := strings.clone_to_cstring(opts.dry_run, context.temp_allocator)
		if k4_png_write(path, c.int(cv.w), c.int(cv.h), raw_data(rgba)) == 0 {
			fmt.eprintln("k4: could not write", opts.dry_run)
			os.exit(2)
		}
		if a.menu == nil && !a.done do app_accept(a)
		if a.menu != nil && !a.done do a.exit = 1
	} else {
		if a.menu == nil do app_layout(a)
		press_keys(a, opts.keys)
		if a.menu == nil do app_move(a, opts.select)
		if !run_wayland(a) do os.exit(2)
	}
	if a.exit == 0 do fmt.println(a.result)
	os.exit(a.exit)
}

// --keys: text is typed; <name> presses a key (see USAGE).
press_keys :: proc(a: ^App, keys: string) {
	s := keys
	for len(s) > 0 && !a.done {
		if s[0] == '<' {
			if end := strings.index_byte(s, '>'); end > 0 {
				tok := s[1:end]
				s = s[end + 1:]
				ctrl, alt := false, false
				if strings.has_prefix(tok, "ctrl-") { ctrl = true; tok = tok[5:] }
				if strings.has_prefix(tok, "alt-") { alt = true; tok = tok[4:] }
				k := Key.None
				switch tok {
				case "down": k = .Down
				case "up": k = .Up
				case "left": k = .Left
				case "right": k = .Right
				case "enter": k = .Enter
				case "esc": k = .Escape
				case "tab": k = .Tab
				case "bs": k = .Backspace
				}
				ch := rune(0)
				text := ""
				if k == .None && len(tok) == 1 {
					ch = rune(tok[0])
					if !ctrl && !alt do text = tok
				}
				app_key(a, k, ctrl, ch, text, alt)
				continue
			}
		}
		r, n := utf8.decode_rune_in_string(s)
		app_key(a, .None, false, r, s[:n])
		s = s[n:]
	}
}
