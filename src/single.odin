package k4

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// One menu at a time: the launcher, a bar popup, the overview and dmenu pickers each run as
// their own k4, and opening one closes the one already open (its pid is kept in
// $XDG_RUNTIME_DIR/k4-menu.pid). The bar and the OSD are not menus.
@(private = "file")
single_path :: proc() -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" do dir = "/tmp"
	return strings.concatenate({dir, "/k4-menu.pid"}, context.temp_allocator)
}

single_take :: proc() {
	p := single_path()
	me := int(linux.getpid())
	if data, err := os.read_entire_file(p, context.temp_allocator); err == nil {
		if pid, ok := strconv.parse_int(strings.trim_space(string(data))); ok && pid > 1 && pid != me {
			// only a k4 (the pid may have been reused since)
			if comm, e := os.read_entire_file(strings.concatenate({"/proc/", fmt.tprint(pid), "/comm"}, context.temp_allocator), context.temp_allocator); e == nil && strings.trim_space(string(comm)) == "k4" {
				linux.kill(linux.Pid(pid), .SIGTERM)
			}
		}
	}
	_ = os.write_entire_file(p, transmute([]u8)fmt.tprint(me))
}

single_drop :: proc() {
	p := single_path()
	if data, err := os.read_entire_file(p, context.temp_allocator); err == nil {
		if pid, ok := strconv.parse_int(strings.trim_space(string(data))); ok && pid == int(linux.getpid()) do _ = os.remove(p)
	}
}
