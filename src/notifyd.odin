package k4

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "logic"

// --notifyd: the notification service (the Kestrel design's notifications). It owns
// org.freedesktop.Notifications on the session bus and shows popups at the top right under
// the bar: critical first, then the newest, three at most (the rest "+N more"), one card per
// app (more from it stacked behind, "+N"). Popups leave after 6 s (low urgency 4 s, an app's
// own timeout when it gives one); critical ones and timeout 0 stay. The pointer on them holds
// the timers. A click runs the default action (else dismisses), × or a right click dismisses,
// the buttons run their actions, "+N more" opens the centre. Everything stays in the history
// for the centre (k4 --notify-center) until dismissed. Do not disturb holds popups back except
// critical ones. The centre, the bar and scripts reach it through $XDG_RUNTIME_DIR/k4-notify.sock
// (k4 --notify-ctl CMD): list, status, dismiss ID, dismiss-app APP, dismiss-popups, clear,
// act ID KEY, invoke-last, dnd on|off|toggle.

ND_W :: 380
ND_MAX :: 3
ND_HISTORY :: 100

Note :: struct {
	id: u32,
	app, title, body, image: string,
	actions: [dynamic][2]string, // key, label ("default": a click on the card)
	urgency: int, // 0 low, 1 normal, 2 critical
	progress: int, // 0–100 from the "value" hint, -1 none
	at: i64, // unix seconds
	timeout: int, // ms the popup shows, -1 until acted on (asked for: -1 the default, 0 stays)
	left: int, // ms it has left
	popup, transient: bool,
}

Nd :: struct {
	notes: [dynamic]Note, // oldest first
	next_id: u32,
	dnd: bool,
	conn: ^DBus_Conn,
	bus_fd: linux.Fd,
	sock: linux.Fd,
	hover: bool,
	last: time.Tick,
	cards: [dynamic]Nd_Card, // as drawn: the visible popups
	more: int,
	f9, f9b, f10, f10b, f11b, f12, f13, f13b: ^Font,
	want_w, want_h: int,
	watcher: bool, // also the tray's StatusNotifierWatcher (no one else was)
	sni: [dynamic]string, // its registered items: "<bus name>/<path>"
}

Nd_Card :: struct { id: u32, count: int }

nd_fonts :: proc(a: ^App) -> (f9, f9b, f10, f10b, f11b, f12, f13, f13b: ^Font) {
	reg :: proc(a: ^App, px: f32) -> ^Font { f := font_sized(&a.font, px); append(&a.fonts, f); return f }
	bld :: proc(a: ^App, px: f32) -> ^Font {
		f := font_sized(&a.font, px)
		if b, ok := bold_font(a, px); ok do f = b
		append(&a.fonts, f)
		return f
	}
	return reg(a, 9), bld(a, 9), reg(a, 10), bld(a, 10), bld(a, 11), reg(a, 12), reg(a, 13), bld(a, 13)
}

nd_setup :: proc(a: ^App) -> bool {
	n := new(Nd)
	a.nd = n
	n.next_id, n.sock, n.bus_fd = 1, -1, -1
	n.f9, n.f9b, n.f10, n.f10b, n.f11b, n.f12, n.f13, n.f13b = nd_fonts(a)
	n.last = time.tick_now()
	if os.get_env("K4_NOTIFY_FIXTURE", context.temp_allocator) != "" do return true // tests: notes from stdin
	err: DBus_Error
	dbus_error_init(&err)
	n.conn = dbus_bus_get(DBUS_BUS_SESSION, &err)
	if n.conn == nil { fmt.eprintln("k4: no session bus"); return false }
	dbus_connection_set_exit_on_disconnect(n.conn, false)
	r := dbus_bus_request_name(n.conn, "org.freedesktop.Notifications", DBUS_NAME_FLAG_REPLACE_EXISTING | DBUS_NAME_FLAG_DO_NOT_QUEUE, &err)
	if r != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER && r != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER {
		fmt.eprintln("k4: another notification service owns org.freedesktop.Notifications")
		return false
	}
	// the tray's registry, when no one else keeps one (Sway without Waybar; Omarchy's shell does)
	if dbus_bus_request_name(n.conn, "org.kde.StatusNotifierWatcher", DBUS_NAME_FLAG_DO_NOT_QUEUE, &err) == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER {
		n.watcher = true
		dbus_bus_add_match(n.conn, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'", &err)
	}
	if dbus_error_is_set(&err) do dbus_error_free(&err)
	fd: c.int
	if dbus_connection_get_unix_fd(n.conn, &fd) do n.bus_fd = linux.Fd(fd)
	nd_listen(n)
	return true
}

// ---------- the notes ----------

nd_find :: proc(n: ^Nd, id: u32) -> int {
	for x, i in n.notes do if x.id == id do return i
	return -1
}

// Markup out (some apps send it whatever the capabilities say), entities decoded.
nd_plain :: proc(s: string) -> string {
	sb := strings.builder_make()
	in_tag := false
	for r in s {
		switch {
		case r == '<': in_tag = true
		case r == '>' && in_tag: in_tag = false
		case in_tag:
		case r == '\n' || r == '\t': strings.write_byte(&sb, ' ')
		case: strings.write_rune(&sb, r)
		}
	}
	out := strings.to_string(sb)
	for e in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&#39;", "'"}, {"&amp;", "&"}}) {
		out, _ = strings.replace_all(out, e[0], e[1])
	}
	return strings.trim_space(out)
}

nd_add :: proc(a: ^App, x: Note) -> u32 {
	n := a.nd
	note := x
	switch {
	case note.urgency == 2 || note.timeout == 0: note.timeout = -1 // stays until acted on
	case note.timeout < 0: note.timeout = note.urgency == 0 ? 4000 : 6000
	}
	note.left = note.timeout
	note.popup = !n.dnd || note.urgency == 2
	note.at = time.to_unix_seconds(time.now())
	if i := note.id > 0 ? nd_find(n, note.id) : -1; i >= 0 {
		was := n.notes[i].popup
		nd_free(&n.notes[i])
		n.notes[i] = note
		if !was && note.progress >= 0 do n.notes[i].popup = false // a progress update does not pop up again
	} else {
		note.id = n.next_id
		n.next_id += 1
		append(&n.notes, note)
		if len(n.notes) > ND_HISTORY { nd_free(&n.notes[0]); ordered_remove(&n.notes, 0) }
	}
	return note.id
}

nd_free :: proc(x: ^Note) {
	delete(x.app); delete(x.title); delete(x.body); delete(x.image)
	for p in x.actions { delete(p[0]); delete(p[1]) }
	delete(x.actions)
}

// Gone from the history too; reason as the spec has it (1 expired, 2 dismissed, 3 closed by
// the app).
nd_remove :: proc(a: ^App, id: u32, reason: u32) {
	n := a.nd
	i := nd_find(n, id)
	if i < 0 do return
	nd_free(&n.notes[i])
	ordered_remove(&n.notes, i)
	nd_signal_closed(n, id, reason)
}

nd_act :: proc(a: ^App, id: u32, key: string) {
	n := a.nd
	if nd_find(n, id) < 0 do return
	if n.conn != nil {
		msg := dbus_message_new_signal("/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked")
		it: DBus_Iter
		dbus_message_iter_init_append(msg, &it)
		dbus_put_u32(&it, id)
		dbus_put_str(&it, key)
		dbus_connection_send(n.conn, msg, nil)
		dbus_message_unref(msg)
	}
	nd_remove(a, id, 2)
}

nd_signal_closed :: proc(n: ^Nd, id: u32, reason: u32) {
	if n.conn == nil do return
	msg := dbus_message_new_signal("/org/freedesktop/Notifications", "org.freedesktop.Notifications", "NotificationClosed")
	it: DBus_Iter
	dbus_message_iter_init_append(msg, &it)
	dbus_put_u32(&it, id)
	dbus_put_u32(&it, reason)
	dbus_connection_send(n.conn, msg, nil)
	dbus_message_unref(msg)
	dbus_connection_flush(n.conn)
}

// The timers: popups lose time unless the pointer is on them; gone ones stay in the history
// (transient ones leave it). Returns the ms to the next change (-1: none).
nd_tick :: proc(a: ^App) -> int {
	n := a.nd
	now := time.tick_now()
	dt := int(time.duration_milliseconds(time.tick_diff(n.last, now)))
	n.last = now
	next := -1
	for i := len(n.notes) - 1; i >= 0; i -= 1 {
		x := &n.notes[i]
		if !x.popup || x.timeout < 0 do continue
		if !n.hover do x.left -= dt
		if x.left <= 0 {
			x.popup = false
			// the rest of its app's stack goes with it
			for &y in n.notes do if y.popup && y.app == x.app && y.urgency < 2 do y.popup = false
			if x.transient { nd_remove(a, x.id, 1); continue }
			nd_signal_closed(n, x.id, 1)
			continue
		}
		next = next < 0 ? x.left : min(next, x.left)
	}
	if nd_popups_visible(n) do next = next < 0 ? 200 : min(next, 200) // the timer lines move
	return next
}

nd_popups_visible :: proc(n: ^Nd) -> bool {
	for x in n.notes do if x.popup do return true
	return false
}

nd_unread :: proc(n: ^Nd) -> int { return len(n.notes) }

// ---------- D-Bus ----------

ND_INTROSPECT :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
</interface></node>`

// The bus's fd was readable: every waiting call.
nd_on_bus :: proc(a: ^App) -> bool {
	n := a.nd
	dbus_connection_read_write(n.conn, 0)
	changed := false
	for {
		msg := dbus_connection_pop_message(n.conn)
		if msg == nil do break
		switch dbus_message_get_type(msg) {
		case DBUS_MESSAGE_TYPE_METHOD_CALL:
			if n.watcher && string(dbus_message_get_path(msg)) == "/StatusNotifierWatcher" do sni_call(n, msg)
			else if nd_call(a, msg) do changed = true
		case DBUS_MESSAGE_TYPE_SIGNAL:
			if n.watcher && string(dbus_message_get_member(msg)) == "NameOwnerChanged" do sni_gone(n, msg)
		}
		dbus_message_unref(msg)
	}
	dbus_connection_flush(n.conn)
	return changed
}

@(private = "file")
nd_call :: proc(a: ^App, msg: ^DBus_Msg) -> bool {
	n := a.nd
	iface := string(dbus_message_get_interface(msg))
	member := string(dbus_message_get_member(msg))
	reply := dbus_message_new_method_return(msg)
	defer if reply != nil { dbus_connection_send(n.conn, reply, nil); dbus_message_unref(reply) }
	out: DBus_Iter
	dbus_message_iter_init_append(reply, &out)
	if iface == "org.freedesktop.DBus.Introspectable" && member == "Introspect" { dbus_put_str(&out, ND_INTROSPECT); return false }
	if iface == "org.freedesktop.DBus.Peer" && member == "Ping" do return false
	switch member {
	case "GetCapabilities":
		arr: DBus_Iter
		dbus_message_iter_open_container(&out, DT_ARRAY, "s", &arr)
		for cap in ([]string{"actions", "body", "persistence", "icon-static"}) do dbus_put_str(&arr, cap)
		dbus_message_iter_close_container(&out, &arr)
		return false
	case "GetServerInformation":
		for s in ([]string{"k4", "kr4nk", "1.0", "1.2"}) do dbus_put_str(&out, s)
		return false
	case "CloseNotification":
		it: DBus_Iter
		if dbus_message_iter_init(msg, &it) do nd_remove(a, dbus_u32(&it), 3)
		return true
	case "Notify":
		x := Note{progress = -1, urgency = 1, timeout = -1}
		it: DBus_Iter
		if !dbus_message_iter_init(msg, &it) do return false
		x.app = dbus_str(&it); dbus_message_iter_next(&it)
		x.id = dbus_u32(&it); dbus_message_iter_next(&it)
		icon := dbus_str(&it); dbus_message_iter_next(&it)
		x.title = nd_plain(dbus_str(&it)); dbus_message_iter_next(&it)
		x.body = nd_plain(dbus_str(&it)); dbus_message_iter_next(&it)
		if dbus_message_iter_get_arg_type(&it) == DT_ARRAY {
			arr: DBus_Iter
			dbus_message_iter_recurse(&it, &arr)
			for dbus_message_iter_get_arg_type(&arr) == DT_STRING {
				key := dbus_str(&arr)
				dbus_message_iter_next(&arr)
				label := dbus_str(&arr)
				append(&x.actions, [2]string{key, label})
				if !dbus_message_iter_next(&arr) do break
			}
		}
		dbus_message_iter_next(&it)
		if dbus_message_iter_get_arg_type(&it) == DT_ARRAY { // hints
			arr: DBus_Iter
			dbus_message_iter_recurse(&it, &arr)
			for dbus_message_iter_get_arg_type(&arr) == DT_DICT_ENTRY {
				ent, v: DBus_Iter
				dbus_message_iter_recurse(&arr, &ent)
				key := dbus_str(&ent)
				dbus_message_iter_next(&ent)
				dbus_message_iter_recurse(&ent, &v)
				switch key {
				case "urgency": x.urgency = int(clamp(dbus_u32(&v), 0, 2))
				case "value": x.progress = int(clamp(dbus_i32(&v), 0, 100))
				case "transient": x.transient = dbus_u32(&v) != 0
				case "image-path", "image_path":
					p := dbus_str(&v)
					if strings.has_prefix(p, "file://") do p = p[7:]
					if strings.has_prefix(p, "/") { delete(x.image); x.image = p }
				}
				delete(key)
				if !dbus_message_iter_next(&arr) do break
			}
		}
		dbus_message_iter_next(&it)
		t := dbus_i32(&it)
		x.timeout = t < 0 ? -1 : int(t)
		if x.image == "" && strings.has_prefix(icon, "/") do x.image = icon
		else do delete(icon)
		dbus_put_u32(&out, nd_add(a, x))
		return true
	}
	dbus_message_unref(reply)
	reply = dbus_message_new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "k4: no such method")
	return false
}

// Tests: the service without a window (K4_NOTIFY_HEADLESS): the bus, the socket and the timers
// only, until SIGTERM.
nd_run_headless :: proc(a: ^App) {
	n := a.nd
	for !a.done {
		fds := make([dynamic]linux.Poll_Fd, 0, 2, context.temp_allocator)
		if n.bus_fd >= 0 do append(&fds, linux.Poll_Fd{fd = n.bus_fd, events = {.IN}})
		if n.sock >= 0 do append(&fds, linux.Poll_Fd{fd = n.sock, events = {.IN}})
		next := nd_tick(a)
		k, _ := linux.poll(fds[:], i32(next < 0 ? 1000 : max(next, 10)))
		if k > 0 do for pf in fds do if pf.revents != {} {
			if pf.fd == n.bus_fd do nd_on_bus(a)
			else do nd_on_sock(a)
		}
		free_all(context.temp_allocator)
	}
}

// ---------- the tray's registry (org.kde.StatusNotifierWatcher) ----------

SNI_INTROSPECT :: `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
<signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
<signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
<signal name="StatusNotifierHostRegistered"/>
</interface></node>`

@(private = "file")
sni_signal :: proc(n: ^Nd, name, item: string) {
	msg := dbus_message_new_signal("/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", strings.clone_to_cstring(name, context.temp_allocator))
	if item != "" { it: DBus_Iter; dbus_message_iter_init_append(msg, &it); dbus_put_str(&it, item) }
	dbus_connection_send(n.conn, msg, nil)
	dbus_message_unref(msg)
}

@(private = "file")
sni_prop :: proc(n: ^Nd, it: ^DBus_Iter, name: string) {
	v: DBus_Iter
	switch name {
	case "RegisteredStatusNotifierItems":
		dbus_message_iter_open_container(it, DT_VARIANT, "as", &v)
		arr: DBus_Iter
		dbus_message_iter_open_container(&v, DT_ARRAY, "s", &arr)
		for s in n.sni do dbus_put_str(&arr, s)
		dbus_message_iter_close_container(&v, &arr)
	case "IsStatusNotifierHostRegistered":
		dbus_message_iter_open_container(it, DT_VARIANT, "b", &v)
		dbus_put_bool(&v, true)
	case:
		dbus_message_iter_open_container(it, DT_VARIANT, "i", &v)
		dbus_put_i32(&v, 0)
	}
	dbus_message_iter_close_container(it, &v)
}

// A call on /StatusNotifierWatcher: an app registering, or a host asking what there is.
@(private = "file")
sni_call :: proc(n: ^Nd, msg: ^DBus_Msg) {
	member := string(dbus_message_get_member(msg))
	reply := dbus_message_new_method_return(msg)
	out: DBus_Iter
	dbus_message_iter_init_append(reply, &out)
	in_: DBus_Iter
	has_args := dbus_message_iter_init(msg, &in_)
	switch member {
	case "Introspect": dbus_put_str(&out, SNI_INTROSPECT)
	case "RegisterStatusNotifierItem":
		arg := has_args ? dbus_str(&in_) : ""
		sender := string(dbus_message_get_sender(msg))
		// an object path from the app's own connection, or a bus name (its default path)
		item := strings.has_prefix(arg, "/") ? strings.concatenate({sender, arg}) : strings.clone(arg != "" ? arg : sender)
		have := false
		for s in n.sni do if s == item do have = true
		if !have { append(&n.sni, item); sni_signal(n, "StatusNotifierItemRegistered", item) }
	case "RegisterStatusNotifierHost": sni_signal(n, "StatusNotifierHostRegistered", "")
	case "Get":
		if has_args { dbus_message_iter_next(&in_); sni_prop(n, &out, dbus_str(&in_)) }
	case "GetAll":
		arr: DBus_Iter
		dbus_message_iter_open_container(&out, DT_ARRAY, "{sv}", &arr)
		for p in ([]string{"RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", "ProtocolVersion"}) {
			ent: DBus_Iter
			dbus_message_iter_open_container(&arr, DT_DICT_ENTRY, nil, &ent)
			dbus_put_str(&ent, p)
			sni_prop(n, &ent, p)
			dbus_message_iter_close_container(&arr, &ent)
		}
		dbus_message_iter_close_container(&out, &arr)
	}
	dbus_connection_send(n.conn, reply, nil)
	dbus_message_unref(reply)
}

// A name left the bus: its items go.
@(private = "file")
sni_gone :: proc(n: ^Nd, msg: ^DBus_Msg) {
	it: DBus_Iter
	if !dbus_message_iter_init(msg, &it) do return
	name := dbus_str(&it)
	dbus_message_iter_next(&it); dbus_message_iter_next(&it)
	if dbus_str(&it) != "" do return // it changed owner, not left
	for i := len(n.sni) - 1; i >= 0; i -= 1 {
		s := n.sni[i]
		if s == name || strings.has_prefix(s, strings.concatenate({name, "/"}, context.temp_allocator)) {
			sni_signal(n, "StatusNotifierItemUnregistered", s)
			ordered_remove(&n.sni, i)
		}
	}
}

// ---------- the control socket ----------

nd_sock_path :: proc() -> string {
	run := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if run == "" do run = "/tmp"
	if v := os.get_env("K4_NOTIFY_SOCK", context.temp_allocator); v != "" do return v
	return fmt.tprintf("%s/k4-notify.sock", run)
}

@(private = "file")
nd_addr :: proc() -> (addr: linux.Sock_Addr_Un, ok: bool) {
	p := nd_sock_path()
	addr.sun_family = .UNIX
	if len(p) >= len(addr.sun_path) do return
	copy(addr.sun_path[:], p)
	return addr, true
}

@(private = "file")
nd_listen :: proc(n: ^Nd) {
	addr, ok := nd_addr()
	if !ok do return
	linux.unlink(strings.clone_to_cstring(nd_sock_path(), context.temp_allocator))
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if err != .NONE do return
	if linux.bind(fd, &addr) != .NONE || linux.listen(fd, 8) != .NONE { linux.close(fd); return }
	n.sock = fd
}

nd_close :: proc(n: ^Nd) {
	if n.sock >= 0 { linux.close(n.sock); linux.unlink(strings.clone_to_cstring(nd_sock_path(), context.temp_allocator)) }
}

// A client connected: one command, one reply.
nd_on_sock :: proc(a: ^App) -> bool {
	n := a.nd
	changed := false
	for {
		addr: linux.Sock_Addr_Un
		cfd, err := linux.accept(n.sock, &addr, {.CLOEXEC})
		if err != .NONE do break
		buf: [4096]u8
		got := 0
		for got < len(buf) {
			k, rerr := linux.read(cfd, buf[got:])
			if rerr != .NONE || k <= 0 do break
			got += k
			if buf[got - 1] == '\n' do break
		}
		reply, ch := nd_command(a, strings.trim_space(string(buf[:got])))
		if ch do changed = true
		b := transmute([]u8)reply
		for len(b) > 0 {
			k, werr := linux.write(cfd, b)
			if werr != .NONE || k <= 0 do break
			b = b[k:]
		}
		linux.close(cfd)
	}
	return changed
}

@(private = "file")
nd_field :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\t", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	return out
}

nd_command :: proc(a: ^App, line: string) -> (reply: string, changed: bool) {
	n := a.nd
	f := strings.fields(line, context.temp_allocator)
	if len(f) == 0 do return "", false
	rest := strings.trim_space(line[len(f[0]):])
	switch f[0] {
	case "status":
		return fmt.tprintf("%d\t%d\n", nd_unread(n), n.dnd ? 1 : 0), false
	case "list":
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "S\t%d\t%d\n", n.dnd ? 1 : 0, nd_unread(n))
		#reverse for x in n.notes {
			acts := strings.builder_make(context.temp_allocator)
			for p, i in x.actions {
				if i > 0 do strings.write_byte(&acts, 0x1e)
				fmt.sbprintf(&acts, "%s\x1f%s", nd_field(p[0]), nd_field(p[1]))
			}
			fmt.sbprintf(&sb, "N\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%s\t%s\n", x.id, nd_field(x.app), x.urgency, x.at, nd_field(x.title), nd_field(x.body), x.progress, strings.to_string(acts), nd_field(x.image))
		}
		return strings.to_string(sb), false
	case "dismiss":
		if len(f) > 1 do if id, ok := strconv.parse_uint(f[1]); ok do nd_remove(a, u32(id), 2)
		return "ok\n", true
	case "dismiss-app":
		for i := len(n.notes) - 1; i >= 0; i -= 1 do if n.notes[i].app == rest do nd_remove(a, n.notes[i].id, 2)
		return "ok\n", true
	case "dismiss-popups": // the newest popup (a key binding)
		#reverse for x in n.notes do if x.popup { nd_remove(a, x.id, 2); break }
		return "ok\n", true
	case "invoke-last": // the newest one's default action (a key binding)
		#reverse for x in n.notes do for p in x.actions do if p[0] == "default" { nd_act(a, x.id, "default"); return "ok\n", true }
		return "none\n", false
	case "clear":
		k := len(n.notes)
		for len(n.notes) > 0 do nd_remove(a, n.notes[len(n.notes) - 1].id, 2)
		return fmt.tprintf("%d\n", k), true
	case "act":
		if len(f) > 2 do if id, ok := strconv.parse_uint(f[1]); ok do nd_act(a, u32(id), strings.trim_space(rest[len(f[1]):]))
		return "ok\n", true
	case "dnd":
		v := len(f) > 1 ? f[1] : "toggle"
		n.dnd = v == "on" ? true : (v == "off" ? false : !n.dnd)
		if n.dnd do for &x in n.notes do if x.urgency < 2 do x.popup = false
		return n.dnd ? "on\n" : "off\n", true
	case "notify": // tests and scripts without notify-send: notify APP\tTITLE\tBODY[\tURGENCY]
		p := strings.split(rest, "\t", context.temp_allocator)
		x := Note{progress = -1, urgency = 1, timeout = -1}
		x.app = strings.clone(p[0])
		x.title = strings.clone(len(p) > 1 ? p[1] : "")
		x.body = strings.clone(len(p) > 2 ? p[2] : "")
		if len(p) > 3 do if u, ok := strconv.parse_int(p[3]); ok do x.urgency = clamp(u, 0, 2)
		return fmt.tprintf("%d\n", nd_add(a, x)), true
	}
	return "unknown command\n", false
}

// k4 --notify-ctl CMD…: one command to the service, its reply printed.
nd_ctl :: proc(cmd: string) -> (string, bool) {
	addr, ok := nd_addr()
	if !ok do return "", false
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE do return "", false
	defer linux.close(fd)
	if linux.connect(fd, &addr) != .NONE do return "", false
	line := strings.concatenate({cmd, "\n"}, context.temp_allocator)
	linux.write(fd, transmute([]u8)line)
	linux.shutdown(fd, .WR)
	sb := strings.builder_make(context.temp_allocator)
	buf: [8192]u8
	for {
		k, rerr := linux.read(fd, buf[:])
		if rerr != .NONE || k <= 0 do break
		strings.write_bytes(&sb, buf[:k])
	}
	return strings.to_string(sb), true
}

// ---------- the look, shared with the centre ----------

// An app's colour: one of the theme's, picked by its name; red for critical.
note_app_color :: proc(t: logic.Theme, app: string) -> u32 {
	cs := [6]u32{t.blue, t.magenta, t.yellow, t.green, t.cyan, t.orange}
	return cs[hash.fnv32a(transmute([]u8)app) % 6]
}

note_ago :: proc(at: i64) -> string {
	d := time.to_unix_seconds(time.now()) - at
	switch {
	case d < 60: return "now"
	case d < 3600: return fmt.tprintf("%d min", d / 60)
	case d < 86400: return fmt.tprintf("%d h", d / 3600)
	}
	return fmt.tprintf("%d d", d / 86400)
}

note_mono :: proc(app: string) -> string {
	for r in app do return strings.to_upper(fmt.tprint(r), context.temp_allocator)
	return "?"
}

// ---------- the popups ----------

// The cards on show: critical first, then the newest; one per app, its count.
nd_visible :: proc(n: ^Nd) -> (cards: []Nd_Card, more: int) {
	order := make([dynamic]int, 0, 8, context.temp_allocator)
	for x, i in n.notes do if x.popup do append(&order, i)
	// newest first, critical before the rest
	sorted := make([dynamic]int, 0, len(order), context.temp_allocator)
	for crit in ([]bool{true, false}) do #reverse for i in order do if (n.notes[i].urgency == 2) == crit do append(&sorted, i)
	out := make([dynamic]Nd_Card, 0, 8, context.temp_allocator)
	seen := make(map[string]int, 8, context.temp_allocator)
	for i in sorted {
		x := n.notes[i]
		if k, ok := seen[x.app]; ok && x.urgency < 2 { out[k].count += 1; continue }
		seen[x.app] = len(out)
		append(&out, Nd_Card{id = x.id, count = 1})
	}
	if len(out) > ND_MAX {
		for c in out[ND_MAX:] do more += c.count
		return out[:ND_MAX], more
	}
	return out[:], 0
}

// One popup card at y (x: its left), its height; cv nil measures.
nd_card :: proc(a: ^App, cv: ^Canvas, S, x, y: int, note: Note, count: int, hover: bool) -> int {
	n := a.nd
	t := a.theme
	H := hud(t)
	soft := mix(H.fg, H.bg, 0.2)
	w := ND_W * S
	lvl := note.urgency == 2 ? H.hot : (note.urgency == 0 ? H.faint : H.acc)
	pl, pr, pt, pb := 18 * S, 14 * S, 11 * S, 12 * S
	iw := w - pl - pr
	// the content's height first
	thumb := note.image != ""
	tw_ := thumb ? iw - 72 * S - 12 * S : iw
	title_l := wrap_text(n.f13b, note.title, tw_)
	if len(title_l) > 2 do title_l = title_l[:2]
	body_l := note.body != "" ? wrap_text(n.f12, note.body, tw_) : nil
	if len(body_l) > 2 { body_l = body_l[:2]; body_l[1] = strings.concatenate({ellipsize(n.f12, body_l[1], tw_ - tw(n.f12, "…")), "…"}, context.temp_allocator) }
	text_h := len(title_l) * 18 * S + (len(body_l) > 0 ? 4 * S + len(body_l) * 17 * S : 0)
	row2 := max(text_h, thumb ? 46 * S : 0)
	acts := make([dynamic][2]string, 0, 4, context.temp_allocator)
	for p in note.actions do if p[0] != "default" && p[1] != "" do append(&acts, p)
	h := pt + 18 * S + 9 * S + row2
	if note.progress >= 0 do h += 9 * S + 4 * S + 5 * S + int(n.f10.line_h)
	if len(acts) > 0 do h += 9 * S + 24 * S
	h += pb
	stack := count > 1 ? 10 * S : 0
	if cv == nil do return h + stack
	// the stack behind, the card, its stripe
	if stack > 0 {
		fill_rect(cv, x + 16 * S, y + h + stack - 12 * S, w - 32 * S, 12 * S, argb(H.bg, a.bg_alpha))
		rounded_rect(cv, x + 16 * S, y + h + stack - 12 * S, w - 32 * S, 12 * S, 0, 0, f32(S), argb(H.line, 0x99))
		fill_rect(cv, x + 8 * S, y + h + 5 * S - 7 * S, w - 16 * S, 12 * S, argb(H.bg, a.bg_alpha))
		rounded_rect(cv, x + 8 * S, y + h + 5 * S - 7 * S, w - 16 * S, 12 * S, 0, 0, f32(S), argb(H.line, 0xff))
	}
	cut := 10 * S
	edge_on := hover || note.urgency == 2
	if note.urgency == 2 do for k in 1 ..= 3 do cut_outline(cv, x - k * 2 * S, y - k * 2 * S, w + k * 4 * S, h + k * 4 * S, cut + k * S, 2 * S, argb(lvl, u8(0x0c / k + 1)))
	cut_rect(cv, x + S, y + S, w - 2 * S, h - 2 * S, cut - S, argb(note.urgency == 2 ? mix(H.bg, H.hot, 0.08) : H.bg, a.bg_alpha))
	cut_rect(cv, x + S, y + S, w - 2 * S, h - 2 * S, cut - S, argb(t.fg, 0x08))
	cut_outline(cv, x, y, w, h, cut, S, argb(edge_on ? lvl : H.line, 0xff))
	fill_rect(cv, x + S, y + S, 3 * S, h - 2 * S, argb(lvl, 0xff))
	hit_add(a, x, y, w, h, .Item, int(note.id), 0)
	// the head: app mark, APP · time, tag, ×
	yy := y + pt
	ac := note_app_color(t, note.app)
	if note.urgency == 2 do ac = H.hot
	fill_rect(cv, x + pl, yy, 18 * S, 18 * S, argb(ac, 0x1f))
	rounded_rect(cv, x + pl, yy, 18 * S, 18 * S, 0, 0, f32(S), argb(ac, 0x55))
	mono := note_mono(note.app)
	text_in(cv, n.f10b, mono, x + pl + (18 * S - tw(n.f10b, mono)) / 2, yy, 18 * S, argb(ac, 0xff))
	hx := x + pl + 18 * S + 8 * S
	app := strings.to_upper(note.app != "" ? note.app : "notification", context.temp_allocator)
	spaced(cv, n.f10b, app, hx, yy, 18 * S, H.dim, S)
	hx += spaced_w(n.f10b, app, S) + 8 * S
	text_in(cv, n.f10, "·", hx, yy, 18 * S, argb(H.faint, 0xff))
	hx += tw(n.f10, "·") + 8 * S
	text_in(cv, n.f10, note_ago(note.at), hx, yy, 18 * S, argb(H.dim, 0xff))
	right := x + w - pr
	xc := hover ? H.fg : H.faint
	text_in(cv, n.f13, "×", right - 18 * S + (18 * S - tw(n.f13, "×")) / 2, yy, 18 * S, argb(xc, 0xff))
	hit_add(a, right - 22 * S, yy - 4 * S, 26 * S, 26 * S, .Chip, int(note.id), -1)
	right -= 18 * S + 8 * S
	tag, tagc := "", H.dim
	switch {
	case count > 1: tag, tagc = fmt.tprintf("+%d", count - 1), H.acc
	case note.urgency == 2: tag, tagc = "CRITICAL", H.hot
	case hover && note.timeout >= 0: tag = "PAUSED"
	case note.timeout < 0: tag = "STAYS"
	}
	if tag != "" {
		gw := spaced_w(n.f9b, tag, S) + 10 * S
		rounded_rect(cv, right - gw, yy + 2 * S, gw, 14 * S, 0, 0, f32(S), argb(tagc, 0xff))
		spaced(cv, n.f9b, tag, right - gw + 5 * S, yy + 2 * S, 14 * S, tagc, S)
	}
	yy += 18 * S + 9 * S
	// the text, the image
	ty := yy
	for l in title_l { text_in(cv, n.f13b, l, x + pl, ty, 18 * S, argb(note.urgency == 0 ? soft : H.fg, 0xff)); ty += 18 * S }
	if len(body_l) > 0 do ty += 4 * S
	for l in body_l { text_in(cv, n.f12, l, x + pl, ty, 17 * S, argb(soft, 0xff)); ty += 17 * S }
	if thumb {
		ix, iy := x + w - pr - 72 * S, yy
		fill_rect(cv, ix, iy, 72 * S, 46 * S, argb(H.bg, 0xff))
		img := image_cover(a, note.image, 72 * S, 46 * S)
		if img.ok do blit_image(cv, img.px, img.w, img.h, ix, iy)
		rounded_rect(cv, ix, iy, 72 * S, 46 * S, 0, 0, f32(S), argb(H.line, 0xff))
	}
	yy += row2
	// progress: 20 segments, the percentage
	if note.progress >= 0 {
		yy += 9 * S
		segs := 20
		sw := (iw - (segs - 1) * 2 * S) / segs
		on := (note.progress * segs + 50) / 100
		for i in 0 ..< segs do fill_rect(cv, x + pl + i * (sw + 2 * S), yy, sw, 4 * S, argb(i < on ? H.acc : H.line, 0xff))
		yy += 4 * S + 5 * S
		pc := fmt.tprintf("%d%%", note.progress)
		text_in(cv, n.f10b, pc, x + w - pr - tw(n.f10b, pc), yy, int(n.f10.line_h), argb(H.fg, 0xff))
		yy += int(n.f10.line_h)
	}
	// the actions: the first one stands out
	if len(acts) > 0 {
		yy += 9 * S
		ax := x + pl
		for p, i in acts {
			bw := tw(n.f11b, p[1]) + 16 * S
			if ax + bw > x + w - pr do break
			prim := i == 0
			pc := lvl == H.faint ? H.fg : lvl
			if prim do fill_rect(cv, ax, yy, bw, 24 * S, argb(lvl, 0x14))
			rounded_rect(cv, ax, yy, bw, 24 * S, 0, 0, f32(S), argb(prim ? lvl : H.line, 0xff))
			text_in(cv, n.f11b, p[1], ax + 8 * S, yy, 24 * S, argb(prim ? pc : soft, 0xff))
			hit_add(a, ax, yy, bw, 24 * S, .Chip, int(note.id), i + 1)
			ax += bw + 6 * S
		}
	}
	// the timer: what is left of the popup's time
	if note.timeout > 0 {
		lw := w - pl - pr
		fill_rect(cv, x + pl, y + h - 4 * S, lw, S, argb(H.line, 0xff))
		fill_rect(cv, x + pl, y + h - 4 * S, lw * clamp(note.left, 0, note.timeout) / note.timeout, S, argb(hover ? H.faint : lvl, 0xff))
	}
	return h + stack
}

ND_PAD :: 8 // room for the critical card's glow

// The popups' size: what the surface should be (0×0: nothing to show).
nd_size :: proc(a: ^App) -> (int, int) {
	n := a.nd
	cards, more := nd_visible(n)
	if len(cards) == 0 do return 0, 0
	h := ND_PAD
	for c in cards {
		i := nd_find(n, c.id)
		h += nd_card(a, nil, 1, 0, 0, n.notes[i], c.count, false) + 10
	}
	if more > 0 do h += 26 + 10
	return ND_W + 2 * ND_PAD, h
}

nd_draw :: proc(a: ^App, cv: ^Canvas, S: int) {
	n := a.nd
	canvas_clear(cv)
	cards, more := nd_visible(n)
	H := hud(a.theme)
	y := ND_PAD * S
	x := ND_PAD * S
	for c in cards {
		i := nd_find(n, c.id)
		y += nd_card(a, cv, S, x, y, n.notes[i], c.count, n.hover) + 10 * S
	}
	if more > 0 {
		l := fmt.tprintf("+%d more", more)
		k := "Super+N"
		bw := tw(n.f11b, l) + 8 * S + tw(n.f10, k) + 20 * S
		bx := x + ND_W * S - bw
		fill_rect(cv, bx, y, bw, 26 * S, argb(H.bg, a.bg_alpha))
		rounded_rect(cv, bx, y, bw, 26 * S, 0, 0, f32(S), argb(H.line, 0xff))
		text_in(cv, n.f11b, l, bx + 10 * S, y, 26 * S, argb(mix(H.fg, H.bg, 0.2), 0xff))
		text_in(cv, n.f10, k, bx + 10 * S + tw(n.f11b, l) + 8 * S, y, 26 * S, argb(H.dim, 0xff))
		hit_add(a, bx, y, bw, 26 * S, .Web, 0, 0)
	}
}

nd_pointer_move :: proc(a: ^App, x, y: int) -> bool {
	n := a.nd
	over := x >= 0 && y >= 0
	if over == n.hover do return false
	n.hover = over
	return true
}

nd_click :: proc(a: ^App, x, y, button: int) -> bool {
	n := a.nd
	h, ok := hit_at(a, x, y)
	if !ok do return false
	id := u32(h.a)
	i := nd_find(n, id)
	app := i >= 0 ? n.notes[i].app : ""
	dismiss_stack :: proc(a: ^App, app: string) {
		n := a.nd
		for j := len(n.notes) - 1; j >= 0; j -= 1 do if n.notes[j].popup && n.notes[j].app == app do nd_remove(a, n.notes[j].id, 2)
	}
	#partial switch h.kind {
	case .Web: libc.system("setsid -f k4-notify center >/dev/null 2>&1 </dev/null")
	case .Chip:
		if i < 0 do return false
		if h.b < 0 do dismiss_stack(a, app)
		else {
			k := 0
			for p in n.notes[i].actions do if p[0] != "default" && p[1] != "" {
				k += 1
				if k == h.b { nd_act(a, id, p[0]); break }
			}
		}
	case .Item:
		if i < 0 do return false
		if button == 3 { dismiss_stack(a, app); break }
		has_default := false
		for p in n.notes[i].actions do if p[0] == "default" do has_default = true
		if has_default do nd_act(a, id, "default")
		else do dismiss_stack(a, app)
	}
	return true
}

// Tests: notes from stdin, one a line: APP\tTITLE\tBODY\tURGENCY\tPROGRESS\tACTIONS(key:label,…)
nd_fixture :: proc(a: ^App, data: string) {
	text := data
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 2 do continue
		get :: proc(f: []string, i: int) -> string { return i < len(f) ? f[i] : "" }
		x := Note{progress = -1, urgency = 1, timeout = -1}
		x.app, x.title, x.body = strings.clone(f[0]), strings.clone(f[1]), strings.clone(get(f, 2))
		if u, ok := strconv.parse_int(get(f, 3)); ok do x.urgency = u
		if p, ok := strconv.parse_int(get(f, 4)); ok do x.progress = p
		for kv in strings.split(get(f, 5), ",", context.temp_allocator) do if i := strings.index_byte(kv, ':'); i > 0 {
			append(&x.actions, [2]string{strings.clone(kv[:i]), strings.clone(kv[i + 1:])})
		}
		nd_add(a, x)
	}
}

nd_dump :: proc(a: ^App) -> string {
	n := a.nd
	sb := strings.builder_make(context.temp_allocator)
	cards, more := nd_visible(n)
	fmt.sbprintfln(&sb, "notify %d · dnd %s", nd_unread(n), n.dnd ? "on" : "off")
	for c in cards {
		x := n.notes[nd_find(n, c.id)]
		fmt.sbprintf(&sb, "popup %s · %s", x.app, x.title)
		if c.count > 1 do fmt.sbprintf(&sb, " +%d", c.count - 1)
		fmt.sbprintln(&sb)
	}
	if more > 0 do fmt.sbprintfln(&sb, "+%d more", more)
	return strings.to_string(sb)
}
