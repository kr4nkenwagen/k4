package k4

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

// Hyprland's sockets: requests on .socket.sock (one per connection, the reply until EOF),
// events on .socket2.sock (lines "event>>data").

hypr_dir :: proc() -> string {
	sig := os.get_env("HYPRLAND_INSTANCE_SIGNATURE", context.temp_allocator)
	if sig == "" do return ""
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	return fmt.tprintf("%s/hypr/%s", run, sig)
}

@(private)
hypr_connect :: proc(name: string) -> (linux.Fd, bool) {
	dir := hypr_dir()
	if dir == "" do return -1, false
	path := fmt.tprintf("%s/%s", dir, name)
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE do return -1, false
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) { linux.close(fd); return -1, false }
	copy(addr.sun_path[:], path)
	if linux.connect(fd, &addr) != .NONE { linux.close(fd); return -1, false }
	return fd, true
}

hypr_request :: proc(req: string, allocator := context.temp_allocator) -> ([]u8, bool) {
	fd, ok := hypr_connect(".socket.sock")
	if !ok do return nil, false
	defer linux.close(fd)
	if !ipc_write_all(fd, transmute([]u8)req) do return nil, false
	out := make([dynamic]u8, 0, 4096, allocator)
	buf: [8192]u8
	for {
		n, err := linux.read(fd, buf[:])
		if err != .NONE || n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:], true
}

hypr_events :: proc() -> (linux.Fd, bool) { return hypr_connect(".socket2.sock") }

// Workspaces as the bar shows them: by id; visible = a monitor's active one, focused = the
// focused monitor's.
hypr_workspaces :: proc() -> (out: [dynamic]Ws, ok: bool) {
	wsb := hypr_request("j/workspaces") or_return
	mb := hypr_request("j/monitors") or_return
	W_ :: struct { id: int, name, monitor: string, windows: int }
	M_ :: struct { name: string, focused: bool, activeWorkspace: struct { id: int } }
	wss: []W_
	mons: []M_
	if json.unmarshal(wsb, &wss, allocator = context.temp_allocator) != nil do return
	if json.unmarshal(mb, &mons, allocator = context.temp_allocator) != nil do return
	slice.sort_by(wss, proc(a, b: W_) -> bool { return a.id < b.id })
	for w in wss {
		if w.id < 0 do continue // special workspaces
		vis, foc := false, false
		for m in mons do if m.activeWorkspace.id == w.id { vis = true; foc = m.focused }
		append(&out, Ws{strings.clone(w.name), w.id, foc, vis, false, strings.clone(w.monitor), w.windows == 0})
	}
	return out, true
}

hypr_title :: proc() -> string {
	b, ok := hypr_request("j/activewindow")
	if !ok do return ""
	J :: struct { title: string }
	j: J
	if json.unmarshal(b, &j, allocator = context.temp_allocator) != nil do return ""
	return strings.clone(j.title)
}

// Omarchy's Hyprland takes Lua dispatches; a classic config the old syntax.
hypr_focus_workspace :: proc(name: string) {
	lua := os.exists(strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config/hypr/hyprland.lua"}, context.temp_allocator))
	// (not fmt: it reads { } as its own syntax)
	if lua do hypr_request(strings.concatenate({"dispatch hl.dsp.focus({ workspace = \"", name, "\" })"}, context.temp_allocator))
	else do hypr_request(fmt.tprintf("dispatch workspace %s", name))
}

// Focus a window by address (Lua dispatch on Omarchy's Hyprland, the old syntax otherwise).
hypr_focus_window :: proc(addr: string) {
	lua := os.exists(strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config/hypr/hyprland.lua"}, context.temp_allocator))
	if lua do hypr_request(strings.concatenate({"dispatch hl.dsp.focus({ window = \"address:", addr, "\" })"}, context.temp_allocator))
	else do hypr_request(strings.concatenate({"dispatch focuswindow address:", addr}, context.temp_allocator))
}
