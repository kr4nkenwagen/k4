package k4

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sys/linux"

// A minimal sway IPC client (i3-ipc framing): queries on one socket, events on another.

IPC_RUN_COMMAND :: 0
IPC_GET_WORKSPACES :: 1
IPC_SUBSCRIBE :: 2
IPC_GET_TREE :: 4

ipc_connect :: proc() -> (linux.Fd, bool) {
	path := os.get_env("SWAYSOCK", context.temp_allocator)
	if path == "" do return -1, false
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE do return -1, false
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) { linux.close(fd); return -1, false }
	copy(addr.sun_path[:], path)
	if linux.connect(fd, &addr) != .NONE { linux.close(fd); return -1, false }
	return fd, true
}

@(private)
ipc_write_all :: proc(fd: linux.Fd, b: []u8) -> bool {
	off := 0
	for off < len(b) {
		n, err := linux.write(fd, b[off:])
		if err != .NONE || n <= 0 do return false
		off += n
	}
	return true
}

@(private)
ipc_read_all :: proc(fd: linux.Fd, b: []u8) -> bool {
	off := 0
	for off < len(b) {
		n, err := linux.read(fd, b[off:])
		if err != .NONE || n <= 0 do return false
		off += n
	}
	return true
}

ipc_send :: proc(fd: linux.Fd, kind: u32, payload: string) -> bool {
	hdr: [14]u8
	copy(hdr[:6], "i3-ipc")
	n := u32(len(payload))
	hdr[6], hdr[7], hdr[8], hdr[9] = u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)
	hdr[10], hdr[11], hdr[12], hdr[13] = u8(kind), u8(kind >> 8), u8(kind >> 16), u8(kind >> 24)
	return ipc_write_all(fd, hdr[:]) && ipc_write_all(fd, transmute([]u8)payload)
}

// One message: its type (events have the high bit set) and body.
ipc_recv :: proc(fd: linux.Fd, allocator := context.allocator) -> (kind: u32, body: []u8, ok: bool) {
	hdr: [14]u8
	if !ipc_read_all(fd, hdr[:]) do return
	n := u32(hdr[6]) | u32(hdr[7]) << 8 | u32(hdr[8]) << 16 | u32(hdr[9]) << 24
	kind = u32(hdr[10]) | u32(hdr[11]) << 8 | u32(hdr[12]) << 16 | u32(hdr[13]) << 24
	body = make([]u8, int(n), allocator)
	if !ipc_read_all(fd, body) do return
	return kind, body, true
}

ipc_query :: proc(fd: linux.Fd, kind: u32, payload: string, allocator := context.allocator) -> ([]u8, bool) {
	if !ipc_send(fd, kind, payload) do return nil, false
	_, body, ok := ipc_recv(fd, allocator)
	return body, ok
}

Ws :: struct { name: string, num: int, focused, visible, urgent: bool, output: string }

ipc_workspaces :: proc(fd: linux.Fd) -> (out: [dynamic]Ws, ok: bool) {
	body := ipc_query(fd, IPC_GET_WORKSPACES, "", context.temp_allocator) or_return
	return ws_parse(body)
}

ws_parse :: proc(body: []u8) -> (out: [dynamic]Ws, ok: bool) {
	J :: struct { name: string, num: int, focused, visible, urgent: bool, output: string }
	list: []J
	if json.unmarshal(body, &list, allocator = context.temp_allocator) != nil do return
	for w in list do append(&out, Ws{strings.clone(w.name), w.num, w.focused, w.visible, w.urgent, strings.clone(w.output)})
	return out, true
}

// The focused window's title, from the tree.
ipc_focused_title :: proc(fd: linux.Fd) -> string {
	body, ok := ipc_query(fd, IPC_GET_TREE, "", context.temp_allocator)
	if !ok do return ""
	v, err := json.parse(body, allocator = context.temp_allocator)
	if err != nil do return ""
	find :: proc(v: json.Value) -> (string, bool) {
		o, is := v.(json.Object)
		if !is do return "", false
		if f, has := o["focused"]; has {
			if b, isb := f.(json.Boolean); isb && bool(b) {
				if t, ok := o["type"].(json.String); ok && (string(t) == "con" || string(t) == "floating_con") {
					if n, ok2 := o["name"].(json.String); ok2 do return string(n), true
					return "", true
				}
			}
		}
		for key in ([]string{"nodes", "floating_nodes"}) {
			if arr, ok := o[key].(json.Array); ok do for c in arr do if s, found := find(c); found do return s, true
		}
		return "", false
	}
	s, _ := find(v)
	return strings.clone(s)
}
