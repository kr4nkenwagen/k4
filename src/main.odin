package k4

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
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
  --open ID               menu mode: start inside the section with this id; Esc there closes k4
  --popup X,W,OUT_W,SIDE[,bottom]   open under a bar module: its left x and width, the output's
                          width, its group (left center right); bottom when the bar is there
  --compact               menu mode: the opened page alone in the popup frame (420 px, no
                          sections or search; ⌃↵ prints launcher:ID for the full launcher)
  --bar                   the status bar (modules on stdin; format in bar.odin)
  --osd SPEC              the on-screen display for 1.2 s; a second call updates it (osd.odin)
  --output NAME           the bar's output (default: the compositor's choice)
  --config FILE           accepted and ignored (fuzzel compatibility)
  --dry-run FILE.png      render one frame to a PNG without Wayland, then print the selection
  --dump                  like --dry-run without the PNG: print the menu state as text (tests)
  --keys KEYS, --select N keys pressed before the first frame: text plus <down> <up> <left>
                          <right> <enter> <esc> <tab> <bs> <pgup> <pgdn> <alt-x> <ctrl-x>, and the pointer:
                          <move:x,y> <click:x,y> <rclick:x,y> <mclick:x,y> <wheel:n>; then move the selection
  --scale N               dry runs: buffer scale

Ghostty's custom shaders (the custom-shader lines of ~/.config/ghostty/config and the files
it includes) run over k4's frame on the GPU; K4_SHADERS=off draws without them, K4_SHADERS=
a.glsl:b.glsl picks others. Dry runs apply them with K4_DRY_SHADERS=1 (K4_DRY_TIME=seconds).

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
		case "--bar": o.bar = true
		case "--output": o.output = value(args, &i, inline, has_inline)
		case "--popup":
			f := strings.split(value(args, &i, inline, has_inline), ",", context.temp_allocator)
			if len(f) >= 3 {
				o.popup.x, _ = strconv.parse_int(f[0])
				o.popup.w, _ = strconv.parse_int(f[1])
				o.popup.out_w, _ = strconv.parse_int(f[2])
				if len(f) > 3 do switch f[3] { case "center", "centre": o.popup.side = 1; case "right": o.popup.side = 2 }
				o.popup.bottom = len(f) > 4 && f[4] == "bottom"
				o.popup.set = o.popup.out_w > 0
			}
		case "--compact": o.compact = true
		case "--osd": o.osd = value(args, &i, inline, has_inline)
		case "--config": _ = value(args, &i, inline, has_inline)
		case "--dry-run": o.dry_run = value(args, &i, inline, has_inline)
		case "--dump": o.dump = true
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
	a.scale = 1
	px := opts.font_pt * 4 / 3
	a.font_px = px
	if !app_load_style(a, true) {
		fmt.eprintfln("k4: cannot load font %q", a.family)
		os.exit(2)
	}

	// rows, or the menu tree
	if opts.osd != "" {
		if opts.dry_run == "" && opts.dump == false && osd_send(opts.osd) do os.exit(0) // one already shows: it took the update
		a.osd = new(Osd)
		osd_set(a.osd, opts.osd)
		a.osd.sock = -1
		a.osd_font = font_sized(&a.font, 13)
		a.osd_bold = a.osd_font
		if bold, ok := bold_font(a, 13); ok do a.osd_bold = bold
		a.osd_icon = font_sized(&a.font, 18)
		append(&a.fonts, a.osd_font, a.osd_bold, a.osd_icon)
		a.width, a.height = 300, 48
	} else if opts.bar {
		data, _ := os.read_entire_file(os.stdin, context.allocator)
		bar_setup(a, string(data))
		a.bar.output = opts.output
	} else if opts.menu {
		data, _ := os.read_entire_file(os.stdin, context.allocator)
		menu_setup(a, string(data))
		if v, ok := strconv.parse_int(os.get_env("K4_SLOW_MS", context.temp_allocator)); ok do a.menu.slow_ms = max(v, 1)
		if opts.open != "" do for s, i in a.menu.sections do if s.id == opts.open { menu_enter(a, i); a.menu.entry = i; break }
		if opts.compact && a.menu.entry < 0 do a.opts.compact = false // nothing to show compact: the launcher
	} else if !prompt_only {
		data, _ := os.read_entire_file(os.stdin, context.allocator)
		a.rows = logic.parse_dmenu(string(data))
	}
	app_rematch(a)

	if opts.dry_run != "" || opts.dump {
		// same path as Wayland: layout at 1x, then the fonts at the buffer scale
		// K4_DRY_NOWAIT: render while loaders still run (skeletons, the slow state)
		// (K4_DRY_NOWAIT=keys: wait for the first load, not for what the keys start)
		nowait := os.get_env("K4_DRY_NOWAIT", context.temp_allocator)
		wait := nowait == ""
		if a.bar != nil {
			bar_load_all(a)
			a.width = a.opts.width_chars > 0 ? a.opts.width_chars : 1280 // dry runs: a 1280 px strip unless -w
			a.bar.width = a.width
		} else if a.menu != nil { if wait || nowait == "keys" do menu_load_all(a) }
		else do app_layout(a)
		press_keys(a, opts.keys)
		if a.menu != nil && wait do menu_load_all(a) // a stay action started by the keys, and the reload after it
		if a.menu != nil && !wait { time.sleep(time.Duration(clamp(a.menu.slow_ms, 0, 2000) + 50) * time.Millisecond); menu_on_tick(a) }
		if a.menu == nil && a.bar == nil && a.osd == nil do app_move(a, opts.select)
		if a.menu != nil do a.width, a.height = menu_size(a)
		s := opts.scale
		a.scale = s
		if s != 1 {
			font_resize(&a.font, px * f32(s))
			for f in a.fonts do font_resize(f, f.base_px * f32(s))
		}
		if opts.dry_run != "" {
			cv := Canvas{make([]u32, a.width * a.height * s * s), a.width * s, a.height * s}
			app_draw(a, &cv, s)
			if os.get_env("K4_DRY_SHADERS", context.temp_allocator) != "" {   // the shaders too, offscreen
				gpu_set_cursor(a.caret.x, a.caret.y, a.caret.z, a.caret.w, cv.h, 0)
				if !gpu_dry_run(&cv) do fmt.eprintln("k4: no OpenGL 4.3 through EGL: drawn without shaders")
			}
			rgba := canvas_rgba(&cv)
			path := strings.clone_to_cstring(opts.dry_run, context.temp_allocator)
			if k4_png_write(path, c.int(cv.w), c.int(cv.h), raw_data(rgba)) == 0 {
				fmt.eprintln("k4: could not write", opts.dry_run)
				os.exit(2)
			}
		}
		if opts.dump && a.bar != nil do fmt.print(bar_dump(a))
		if opts.dump && a.menu != nil && !a.done {
			fmt.print(menu_dump(a))
			if os.get_env("K4_DUMP_HITS", context.temp_allocator) != "" { // where the rows are, for pointer tests
				hits_refresh(a)
				for h in a.hits do fmt.printfln("hit %v %d:%d at %d,%d %dx%d", h.kind, h.a, h.b, h.x, h.y, h.w, h.h)
			}
		}
		if opts.dump && a.osd != nil do fmt.printfln("osd %s %d/%d %s %s", a.osd.icon, a.osd.pct, a.osd.vmax, a.osd.value, a.osd.label)
		if a.menu == nil && a.bar == nil && a.osd == nil && !a.done do app_accept(a)
		if (a.menu != nil || a.bar != nil) && !a.done do a.exit = 1
		if a.osd != nil do a.exit = 0
	} else {
		if a.menu == nil && a.bar == nil && a.osd == nil do app_layout(a)
		press_keys(a, opts.keys)
		if a.menu == nil && a.bar == nil && a.osd == nil do app_move(a, opts.select)
		if a.menu != nil do a.width, a.height = menu_size(a)
		if a.osd != nil do osd_listen(a.osd)
		if !run_wayland(a) do os.exit(2)
		if a.osd != nil { osd_close(a.osd); os.exit(0) }
	}
	if a.exit == 0 do fmt.println(a.result)
	os.exit(a.exit)
}

// The theme (colors.toml) and font (font.name) of the desktop, unless given as options. Called
// at start and after every in-place menu action, which may have switched either.
app_load_style :: proc(a: ^App, first: bool) -> bool {
	theme_path := a.opts.theme_file != "" ? a.opts.theme_file : state_file("theme/colors.toml")
	if first do a.theme = logic.DEFAULT_THEME
	if data, err := os.read_entire_file(theme_path, context.temp_allocator); err == nil {
		a.theme = logic.theme_from_colors(string(data))
	}
	family := a.opts.font
	if family == "" {
		if data, err := os.read_entire_file(state_file("font.name"), context.temp_allocator); err == nil {
			family = strings.trim_space(string(data))
		}
	}
	if family == "" do family = "monospace"
	if !first do gpu_check_shaders() // the starfield toggle rewrites Ghostty's shader list
	if !first && family == a.family do return true
	// on the heap and kept: kb_text_shape holds a pointer to the font's allocator, so the
	// Font must not live in this frame (a stack copy left dmenu mode without text)
	f := new(Font)
	if !font_load(f, family, a.font_px, true) {
		if first do a.family = family
		return false
	}
	f.fallback = first ? new(Fallbacks) : a.font.fallback // filled per missing character
	a.font = f^
	a.family = strings.clone(family)
	if a.scale > 1 do font_resize(&a.font, a.font_px * f32(a.scale))
	if a.menu != nil do menu_fonts(a)
	return true
}

// Dry runs: draw once (scale 1) so the pointer tokens find what is where.
hits_refresh :: proc(a: ^App) {
	if a.width <= 0 || a.height <= 0 do return
	cv := Canvas{make([]u32, a.width * a.height, context.temp_allocator), a.width, a.height}
	app_draw(a, &cv, 1)
}

// --keys: text is typed; <name> presses a key (see USAGE).
press_keys :: proc(a: ^App, keys: string) {
	s := keys
	for len(s) > 0 && !a.done {
		if s[0] == '<' {
			if end := strings.index_byte(s, '>'); end > 0 {
				tok := s[1:end]
				s = s[end + 1:]
				// pointer tokens (tests): <move:x,y> <click:x,y> <rclick:x,y> <mclick:x,y> <wheel:n>, logical pixels
				if c := strings.index_byte(tok, ':'); c > 0 && (tok[:c] == "move" || tok[:c] == "click" || tok[:c] == "rclick" || tok[:c] == "mclick" || tok[:c] == "wheel") {
					hits_refresh(a)
					xy := strings.split(tok[c + 1:], ",", context.temp_allocator)
					x, _ := strconv.parse_int(xy[0])
					y := 0
					if len(xy) > 1 do y, _ = strconv.parse_int(xy[1])
					switch tok[:c] {
					case "move": app_pointer_move(a, x, y)
					case "click": app_pointer_click(a, x, y, 1)
					case "rclick": app_pointer_click(a, x, y, 3)
					case "mclick": app_pointer_click(a, x, y, 2)
					case "wheel": app_pointer_scroll(a, x)
					}
					if a.menu != nil && (a.opts.dry_run != "" || a.opts.dump) && os.get_env("K4_DRY_NOWAIT", context.temp_allocator) == "" do menu_load_all(a)
					continue
				}
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
				case "pgup": k = .Page_Up
				case "pgdn": k = .Page_Down
				}
				ch := rune(0)
				text := ""
				if k == .None && len(tok) == 1 {
					ch = rune(tok[0])
					if !ctrl && !alt do text = tok
				}
				app_key(a, k, ctrl, ch, text, alt)
				if a.menu != nil && (a.opts.dry_run != "" || a.opts.dump) && os.get_env("K4_DRY_NOWAIT", context.temp_allocator) == "" do menu_load_all(a) // pages and runs a key started
				continue
			}
		}
		r, n := utf8.decode_rune_in_string(s)
		app_key(a, .None, false, r, s[:n])
		if a.menu != nil && (a.opts.dry_run != "" || a.opts.dump) && os.get_env("K4_DRY_NOWAIT", context.temp_allocator) == "" do menu_load_all(a)
		s = s[n:]
	}
}
