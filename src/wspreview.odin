package k4

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// The workspace preview (the Kestrel design's hover card): 300 ms on a workspace and a 340 px
// card drops 4 px under it, left edges aligned. A miniature of its windows in their real places
// (drawn from the compositor's tree, not a screenshot: title bar, app mark and name; floating
// ones with a shadow, fullscreen filling the frame, the focused one in the accent, urgent ones
// red), then a row per window. A click on a row or a box focuses that window. It is a tooltip:
// no keyboard, gone when the pointer leaves the workspace and the card.
// Tests: K4_BAR_CLIENTS and K4_BAR_MONITORS name Hyprland-style j/clients and j/monitors files.

PREV_W :: 340
PREV_MW, PREV_MH :: 320, 180 // the miniature

Prev_Win :: struct {
	addr, app, title, mono, tok: string,
	x, y, w, h: f32, // fractions of the output
	focused, floating, full, hidden, urgent: bool,
	group: [dynamic]string, // tabs (Hyprland groups): the apps in it
}

Prev :: struct {
	ws: int, // index in bar_workspaces, -1: none
	cand: int, // the workspace under the pointer, waiting for its 300 ms
	cand_at: time.Tick,
	name, output: string,
	wins: [dynamic]Prev_Win,
	row: int, // the window row under the pointer, -1
	x, y, w, h: int, // where it was drawn (logical, surface coordinates)
	f8, f9, f10, f10b, f12b, f13b: ^Font,
}

prev_h :: proc(p: ^Prev) -> int { return 30 + 8 + PREV_MH + 6 + len(p.wins) * 26 + 6 + 24 + 2 }

@(private)
prev_fonts :: proc(a: ^App) {
	p := &a.bar.prev
	if p.f8 != nil do return
	p.f8, p.f9, p.f10 = font_sized(&a.font, 8), font_sized(&a.font, 9), font_sized(&a.font, 10)
	p.f10b, p.f12b, p.f13b = p.f10, a.bar.f_bold, a.bar.f_bold
	if bold, ok := bold_font(a, 10); ok do p.f10b = bold
	if bold, ok := bold_font(a, 13); ok do p.f13b = bold
	append(&a.fonts, p.f8, p.f9, p.f10, p.f10b, p.f13b)
	if a.scale > 1 do for f in ([]^Font{p.f8, p.f9, p.f10, p.f10b, p.f13b}) do font_resize(f, f.base_px * f32(a.scale))
}

// "com.mitchellh.ghostty" -> "ghostty", and its two-letter mark (">_" for terminals).
@(private)
app_names :: proc(class: string) -> (app, mono, tok: string) {
	app = class
	web := false
	for pre in ([]string{"chrome-", "brave-", "msedge-", "chromium-"}) do if strings.has_prefix(app, pre) { app, web = app[len(pre):], true; break }
	if web { // a web app: "chrome-discord.com__channels_@me-Default" -> "discord"
		if i := strings.index(app, "__"); i > 0 do app = app[:i]
		if i := strings.index_byte(app, '.'); i > 0 do app = app[:i]
		if strings.has_prefix(app, "www") && len(app) > 4 do app = app[4:]
	} else if i := strings.last_index_byte(app, '.'); i >= 0 && i + 1 < len(app) do app = app[i + 1:]
	if app == "" do app = "window"
	low := strings.to_lower(app, context.temp_allocator)
	switch low {
	case "ghostty", "foot", "kitty", "alacritty", "wezterm", "xterm", "konsole":
		mono = ">_"
	case:
		r := utf8.string_to_runes(app, context.temp_allocator)
		mono = len(r) > 1 ? fmt.tprintf("%c%c", unicode.to_upper(r[0]), r[1]) : fmt.tprintf("%c", unicode.to_upper(r[0]))
	}
	toks := [6]string{"fg", "yellow", "blue", "accent", "green", "magenta"}
	h := 0
	for c in low do h = h * 31 + int(c)
	tok = toks[abs(h) % len(toks)]
	return strings.clone(app), strings.clone(mono), tok
}

// The windows on a workspace, from Hyprland (or the test files).
@(private)
prev_load_hypr :: proc(p: ^Prev, ws: Ws) {
	cb, mb: []u8
	ok1, ok2: bool
	if f := os.get_env("K4_BAR_CLIENTS", context.temp_allocator); f != "" {
		d1, e1 := os.read_entire_file(f, context.temp_allocator)
		d2, e2 := os.read_entire_file(os.get_env("K4_BAR_MONITORS", context.temp_allocator), context.temp_allocator)
		cb, mb, ok1, ok2 = d1, d2, e1 == nil, e2 == nil
	} else {
		cb, ok1 = hypr_request("j/clients")
		mb, ok2 = hypr_request("j/monitors")
	}
	if !ok1 || !ok2 do return
	C :: struct { address, class, title: string, workspace: struct { id: int, name: string }, at, size: [2]f32, floating, hidden: bool, fullscreen, focusHistoryID: int, grouped: []string }
	M :: struct { name: string, x, y, width, height: f32, scale: f32 }
	cs: []C
	ms: []M
	if json.unmarshal(cb, &cs, allocator = context.temp_allocator) != nil do return
	if json.unmarshal(mb, &ms, allocator = context.temp_allocator) != nil do return
	mon := M{width = 1920, height = 1080, scale = 1}
	for m in ms do if m.name == ws.output { mon = m; break }
	if mon.scale <= 0 do mon.scale = 1
	lw, lh := mon.width / mon.scale, mon.height / mon.scale
	best := max(int)
	for c in cs do if c.workspace.name == ws.name && !c.hidden && c.focusHistoryID < best do best = c.focusHistoryID
	for c in cs {
		if c.workspace.name != ws.name do continue
		app, mono, tok := app_names(c.class)
		w := Prev_Win{addr = strings.clone(c.address), app = app, mono = mono, tok = tok, title = strings.clone(c.title)}
		w.x, w.y = (c.at[0] - mon.x) / lw, (c.at[1] - mon.y) / lh
		w.w, w.h = c.size[0] / lw, c.size[1] / lh
		w.floating, w.full, w.hidden = c.floating, c.fullscreen > 0, c.hidden
		w.focused = !c.hidden && c.focusHistoryID == best
		if w.full do w.x, w.y, w.w, w.h = 0, 0, 1, 1
		if len(c.grouped) > 1 do for g in c.grouped do for o in cs do if o.address == g { ga, _, _ := app_names(o.class); append(&w.group, ga) }
		append(&p.wins, w)
	}
}

// The same from sway's tree: the workspace's windows, tiled and floating, relative to it.
@(private)
prev_load_sway :: proc(p: ^Prev, ws: Ws, fd: i32) {
	body, ok := ipc_query(cast(type_of(W.app.bar.ipc_q))fd, IPC_GET_TREE, "", context.temp_allocator)
	if !ok do return
	v, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil do return
	num :: proc(o: json.Object, k: string) -> f32 { x, _ := o[k].(json.Float); if i, ok := o[k].(json.Integer); ok do return f32(i); return f32(x) }
	rect :: proc(o: json.Object) -> [4]f32 { r, _ := o["rect"].(json.Object); return {num(r, "x"), num(r, "y"), num(r, "width"), num(r, "height")} }
	find :: proc(v: json.Value, name: string) -> (json.Object, bool) {
		o, is := v.(json.Object)
		if !is do return nil, false
		if t, _ := o["type"].(json.String); string(t) == "workspace" { if n, _ := o["name"].(json.String); string(n) == name do return o, true }
		for key in ([]string{"nodes", "floating_nodes"}) do if arr, ok := o[key].(json.Array); ok do for c in arr do if r, ok2 := find(c, name); ok2 do return r, true
		return nil, false
	}
	wso, found := find(v, ws.name)
	if !found do return
	wr := rect(wso)
	walk :: proc(p: ^Prev, v: json.Value, wr: [4]f32, floating, tabbed: bool) {
		o, is := v.(json.Object)
		if !is do return
		nodes, _ := o["nodes"].(json.Array)
		fl, _ := o["floating_nodes"].(json.Array)
		layout, _ := o["layout"].(json.String)
		if len(nodes) == 0 && len(fl) == 0 {
			if t, _ := o["type"].(json.String); string(t) != "con" && string(t) != "floating_con" do return
			cls := ""
			if a, ok := o["app_id"].(json.String); ok do cls = string(a)
			if wp, ok := o["window_properties"].(json.Object); ok && cls == "" { if c, ok2 := wp["class"].(json.String); ok2 do cls = string(c) }
			name, _ := o["name"].(json.String)
			app, mono, tok := app_names(cls)
			r := rect(o)
			w := Prev_Win{app = app, mono = mono, tok = tok, title = strings.clone(string(name))}
			if id, ok := o["id"].(json.Integer); ok do w.addr = fmt.aprintf("%d", id)
			w.x, w.y, w.w, w.h = (r[0] - wr[0]) / wr[2], (r[1] - wr[1]) / wr[3], r[2] / wr[2], r[3] / wr[3]
			w.floating = floating
			if f, ok := o["focused"].(json.Boolean); ok do w.focused = bool(f)
			if u, ok := o["urgent"].(json.Boolean); ok do w.urgent = bool(u)
			if fs, ok := o["fullscreen_mode"].(json.Integer); ok && fs > 0 do w.full, w.x, w.y, w.w, w.h = true, 0, 0, 1, 1
			if vis, ok := o["visible"].(json.Boolean); ok do w.hidden = !bool(vis)
			append(&p.wins, w)
			return
		}
		for c in nodes do walk(p, c, wr, floating, string(layout) == "tabbed" || string(layout) == "stacked")
		for c in fl do walk(p, c, wr, true, false)
	}
	walk(p, wso, wr, false, false)
}

@(private)
prev_load :: proc(a: ^App, k: int) {
	b := a.bar
	p := &b.prev
	clear(&p.wins) // (their strings are small; a hover's worth)
	p.row = -1
	wss := bar_workspaces(b)
	if k < 0 || k >= len(wss) do return
	ws := wss[k]
	p.ws, p.output = k, strings.clone(ws.output)
	label, _ := ws_label(ws)
	p.name = strings.clone(label)
	if b.hypr || os.get_env("K4_BAR_CLIENTS", context.temp_allocator) != "" do prev_load_hypr(p, ws)
	else if b.ipc_q >= 0 do prev_load_sway(p, ws, i32(b.ipc_q))
	prev_fonts(a)
}

// The pointer is at a workspace cell (k), on the card, or elsewhere (-1, false): show, keep or
// drop the preview. Returns whether that changed what is drawn.
prev_pointer :: proc(a: ^App, k: int, on_card: bool) -> bool {
	p := &a.bar.prev
	if on_card do return false
	if k < 0 {
		changed := p.ws >= 0
		p.ws, p.cand = -1, -1
		return changed
	}
	if k == p.ws do return false
	if p.ws >= 0 || a.opts.dump || a.opts.dry_run != "" { prev_load(a, k); return true } // moving along the workspaces (and dry runs): at once
	if k != p.cand do p.cand, p.cand_at = k, time.tick_now()
	return false
}

// bar_tick: the 300 ms are up. Returns ms until they will be (or -1).
prev_tick :: proc(a: ^App) -> int {
	p := &a.bar.prev
	if p.cand < 0 || p.ws >= 0 do return -1
	left := 300 - int(time.duration_milliseconds(time.tick_since(p.cand_at)))
	if left > 0 do return left + 1
	prev_load(a, p.cand)
	return -1
}

prev_draw :: proc(a: ^App, cv: ^Canvas, S, x0, y0: int) {
	b := a.bar
	t := a.theme
	p := &b.prev
	wss := bar_workspaces(b)
	if p.ws < 0 || p.ws >= len(wss) do return
	ws := wss[p.ws]
	w, h := PREV_W * S, prev_h(p) * S
	x := clamp(x0, 8 * S, max(cv.w - 8 * S - w, 8 * S))
	y := y0
	p.x, p.y, p.w, p.h = x / S, y / S, PREV_W, prev_h(p)
	fill_rect(cv, x, y, w, h, argb(t.bg, 0xff))
	rounded_rect(cv, x, y, w, h, 0, 0, f32(S), argb(t.fg_dim, 0xff))
	hit_add(a, x, y, w, h, .Web, -1, -1) // the card itself: the pointer may rest here
	sel := t.selection
	// header: the number chip, the name, output · windows
	hy := y + S
	hh := 30 * S
	chip := fmt.tprintf("%d", ws.num)
	cw := tw(p.f12b, chip) + 12 * S
	cy := hy + (hh - 18 * S) / 2
	switch {
	case ws.focused: fill_rect(cv, x + 10 * S, cy, cw, 18 * S, argb(t.accent, 0xff))
	case ws.urgent: fill_rect(cv, x + 10 * S, cy, cw, 18 * S, argb(t.red, 0xff))
	case ws.visible: rounded_rect(cv, x + 10 * S, cy, cw, 18 * S, 0, 0, f32(S), argb(t.accent, 0xff))
	case: rounded_rect(cv, x + 10 * S, cy, cw, 18 * S, 0, 0, f32(S), argb(sel, 0xff))
	}
	text_in(cv, p.f12b, chip, x + 10 * S + 6 * S, cy, 18 * S, argb(ws.focused || ws.urgent ? t.bg : (ws.visible ? t.accent : t.fg), 0xff))
	n := len(p.wins)
	meta := fmt.tprintf("%s · %s", p.output, n == 0 ? "empty" : (n == 1 ? "1 window" : fmt.tprintf("%d windows", n)))
	mw := tw(b.f_text, meta)
	f11 := p.f10
	text_in(cv, f11, meta, x + w - 10 * S - tw(f11, meta), hy, hh, argb(t.fg_dim, 0xff))
	nm := strings.contains(p.name, " ") ? p.name[strings.index_byte(p.name, ' ') + 1:] : fmt.tprintf("Workspace %d", ws.num)
	text_in(cv, p.f12b, ellipsize(p.f12b, nm, w - 40 * S - cw - mw), x + 10 * S + cw + 8 * S, hy, hh, argb(t.fg, 0xff))
	_ = mw
	fill_rect(cv, x, hy + hh, w, S, argb(sel, 0xff))
	// the miniature
	mx, my := x + 10 * S, hy + hh + S + 8 * S
	MW, MH := PREV_MW * S, PREV_MH * S
	fill_rect(cv, mx, my, MW, MH, argb(mix(t.bg, t.blue, 0.16), 0xff))
	if n == 0 do text_in(cv, f11, "empty", mx + (MW - tw(f11, "empty")) / 2, my, MH, argb(t.fg_dim, 0xff))
	draw_win :: proc(a: ^App, cv: ^Canvas, S, mx, my, MW, MH, i: int, wi: Prev_Win) {
		b := a.bar
		t := a.theme
		p := &b.prev
		g := wi.full ? 0 : 3 * S
		bx := mx + int(wi.x * f32(MW)) + g
		by := my + int(wi.y * f32(MH)) + g
		bw := max(int(wi.w * f32(MW)) - 2 * g, 8 * S)
		bh := max(int(wi.h * f32(MH)) - 2 * g, 8 * S)
		bx, by = clamp(bx, mx, mx + MW - bw), clamp(by, my, my + MH - bh)
		if wi.floating do fill_rect(cv, bx + 3 * S, by + 6 * S, bw, bh, argb(0, 0x70)) // the shadow
		fill_rect(cv, bx, by, bw, bh, argb(mix(t.bg, t.fg, 0.04), 0xff))
		on := p.row == i
		bc := wi.urgent ? t.red : (wi.focused ? t.accent : (on ? t.fg : t.selection))
		bt := wi.focused || wi.urgent || on ? 2 * S : S
		rounded_rect(cv, bx, by, bw, bh, 0, 0, f32(bt), argb(bc, 0xff))
		top := by + bt
		if len(wi.group) > 1 { // tabs
			tw_ := (bw - 2 * bt) / len(wi.group)
			for gname, gi in wi.group {
				tx := bx + bt + gi * tw_
				if gname == wi.app do fill_rect(cv, tx, top, tw_, 13 * S, argb(t.selection, 0xff))
				text_in(cv, p.f8, ellipsize(p.f8, gname, tw_ - 6 * S), tx + 3 * S, top, 13 * S, argb(gname == wi.app ? t.fg : t.fg_dim, 0xff))
			}
			top += 13 * S
		} else if !wi.full {
			if wi.focused do fill_rect(cv, bx + bt, top, bw - 2 * bt, 12 * S, argb(t.selection, 0xff))
			text_in(cv, p.f8, ellipsize(p.f8, wi.title, bw - 2 * bt - 8 * S), bx + bt + 4 * S, top, 12 * S, argb(wi.focused ? t.fg : t.fg_dim, 0xff))
			top += 12 * S
		}
		small := bw < 140 * S || bh < 70 * S
		mf := small ? p.f10b : p.f13b
		mww := tw(mf, wi.mono) + 8 * S
		mhh := int(mf.line_h) + 2 * S
		inner := by + bh - bt - top
		total := mhh + 3 * S + int(p.f9.line_h)
		cy := top + max((inner - total) / 2, 0)
		fill_rect(cv, bx + (bw - mww) / 2, cy, mww, mhh, argb(token(t, wi.tok, t.fg), 0xff))
		text_in(cv, mf, wi.mono, bx + (bw - mww) / 2 + 4 * S, cy, mhh, argb(t.bg, 0xff))
		if cy + mhh + 3 * S + int(p.f9.line_h) <= by + bh - bt {
			text_in(cv, p.f9, ellipsize(p.f9, wi.app, bw - 8 * S), bx + (bw - tw(p.f9, ellipsize(p.f9, wi.app, bw - 8 * S))) / 2, cy + mhh + 3 * S, int(p.f9.line_h), argb(t.fg_dim, 0xff))
		}
		hit_add(a, bx, by, bw, bh, .Item, i, -1)
	}
	for wi, i in p.wins do if !wi.floating && !wi.hidden do draw_win(a, cv, S, mx, my, MW, MH, i, wi)
	for wi, i in p.wins do if wi.floating && !wi.hidden do draw_win(a, cv, S, mx, my, MW, MH, i, wi)
	// a row per window (hidden tabs too)
	ry := my + MH + 6 * S
	for wi, i in p.wins {
		on := p.row == i
		if on do fill_rect(cv, x + S, ry, w - 2 * S, 26 * S, argb(t.accent, 0xff))
		fg := on ? t.bg : t.fg
		cx := x + 10 * S
		fill_rect(cv, cx, ry + 6 * S, 22 * S, 14 * S, argb(token(t, wi.tok, t.fg), 0xff))
		text_in(cv, p.f10b, wi.mono, cx + (22 * S - tw(p.f10b, wi.mono)) / 2, ry + 6 * S, 14 * S, argb(t.bg, 0xff))
		cx += 22 * S + 8 * S
		text_in(cv, p.f12b, wi.app, cx, ry, 26 * S, argb(fg, 0xff))
		cx += tw(p.f12b, wi.app) + 8 * S
		tag, tc := "", t.fg_dim
		switch {
		case wi.urgent: tag, tc = "URGENT", t.red
		case wi.full: tag = "FULL"
		case wi.floating: tag = "FLOAT"
		case len(wi.group) > 1: tag = wi.hidden ? "TAB" : "TAB · SHOWN"
		case wi.focused: tag, tc = "FOCUSED", t.accent
		}
		right := x + w - 10 * S
		if tag != "" {
			tw2 := tw(p.f10b, tag) + 8 * S
			rounded_rect(cv, right - tw2, ry + 6 * S, tw2, 14 * S, 0, 0, f32(S), argb(on ? t.bg : tc, 0xff))
			text_in(cv, p.f10b, tag, right - tw2 + 4 * S, ry + 6 * S, 14 * S, argb(on ? t.bg : tc, 0xff))
			right -= tw2 + 8 * S
		}
		text_in(cv, b.f_text, ellipsize(b.f_text, wi.title, right - cx), cx, ry, 26 * S, argb(on ? t.bg : t.fg_dim, 0xff))
		hit_add(a, x, ry, w, 26 * S, .Item, i, -1)
		ry += 26 * S
	}
	// the footer
	fy := y + h - S - 24 * S
	fill_rect(cv, x, fy, w, S, argb(sel, 0xff))
	foot := n > 0 ? "Click a window to jump to it · scroll on the bar to switch" : "Click the workspace to go there"
	text_in(cv, p.f10, ellipsize(p.f10, foot, w - 20 * S), x + 10 * S, fy + S, 24 * S, argb(t.fg_dim, 0xff))
}

// A click on a window in the card: focus it.
prev_click :: proc(a: ^App, i: int) {
	b := a.bar
	p := &b.prev
	if i < 0 || i >= len(p.wins) do return
	addr := p.wins[i].addr
	if b.hypr do hypr_focus_window(addr)
	else if b.ipc_q >= 0 do ipc_query(b.ipc_q, IPC_RUN_COMMAND, fmt.tprintf("[con_id=%s] focus", addr), context.temp_allocator)
	p.ws, p.cand = -1, -1
	bar_ipc_refresh(b)
}

prev_dump :: proc(a: ^App, sb: ^strings.Builder) {
	p := &a.bar.prev
	if p.ws < 0 do return
	fmt.sbprintf(sb, "preview %s · %s:", p.name, p.output)
	for wi in p.wins do fmt.sbprintf(sb, " [%s %s%s%s%s]", wi.mono, wi.app, wi.focused ? " focused" : "", wi.floating ? " float" : "", wi.full ? " full" : "")
	fmt.sbprintln(sb)
}
