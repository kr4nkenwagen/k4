package k4

import "core:c"
import "core:strings"

// The few libdbus-1 calls the notification service needs (notifyd.odin): own a name on the
// session bus, read method calls, reply, send signals. Messages are read from the
// connection's fd in k4's own poll loop.

foreign import dbus_lib "system:dbus-1"

DBus_Conn :: struct {}
DBus_Msg :: struct {}
DBus_Error :: struct {
	name, message: cstring,
	bits: c.uint,
	pad: rawptr,
}
DBus_Iter :: struct #align (8) { _: [128]u8 }

DBUS_BUS_SESSION :: 0
DBUS_NAME_FLAG_REPLACE_EXISTING :: 2
DBUS_NAME_FLAG_DO_NOT_QUEUE :: 4
DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER :: 1
DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER :: 4
DBUS_MESSAGE_TYPE_METHOD_CALL :: 1

DT_INVALID :: c.int(0)
DT_BYTE :: c.int('y')
DT_BOOLEAN :: c.int('b')
DT_INT32 :: c.int('i')
DT_UINT32 :: c.int('u')
DT_INT64 :: c.int('x')
DT_STRING :: c.int('s')
DT_ARRAY :: c.int('a')
DT_VARIANT :: c.int('v')
DT_STRUCT :: c.int('r')
DT_DICT_ENTRY :: c.int('e')

@(default_calling_convention = "c")
foreign dbus_lib {
	dbus_error_init :: proc(e: ^DBus_Error) ---
	dbus_error_free :: proc(e: ^DBus_Error) ---
	dbus_error_is_set :: proc(e: ^DBus_Error) -> b32 ---
	dbus_bus_get :: proc(kind: c.int, e: ^DBus_Error) -> ^DBus_Conn ---
	dbus_bus_request_name :: proc(conn: ^DBus_Conn, name: cstring, flags: c.uint, e: ^DBus_Error) -> c.int ---
	dbus_connection_get_unix_fd :: proc(conn: ^DBus_Conn, fd: ^c.int) -> b32 ---
	dbus_connection_read_write :: proc(conn: ^DBus_Conn, timeout_ms: c.int) -> b32 ---
	dbus_connection_pop_message :: proc(conn: ^DBus_Conn) -> ^DBus_Msg ---
	dbus_connection_send :: proc(conn: ^DBus_Conn, msg: ^DBus_Msg, serial: ^c.uint) -> b32 ---
	dbus_connection_flush :: proc(conn: ^DBus_Conn) ---
	dbus_connection_set_exit_on_disconnect :: proc(conn: ^DBus_Conn, exit: b32) ---
	dbus_message_get_type :: proc(msg: ^DBus_Msg) -> c.int ---
	dbus_message_get_interface :: proc(msg: ^DBus_Msg) -> cstring ---
	dbus_message_get_member :: proc(msg: ^DBus_Msg) -> cstring ---
	dbus_message_get_sender :: proc(msg: ^DBus_Msg) -> cstring ---
	dbus_message_new_method_return :: proc(msg: ^DBus_Msg) -> ^DBus_Msg ---
	dbus_message_new_error :: proc(msg: ^DBus_Msg, name, text: cstring) -> ^DBus_Msg ---
	dbus_message_new_signal :: proc(path, iface, name: cstring) -> ^DBus_Msg ---
	dbus_message_unref :: proc(msg: ^DBus_Msg) ---
	dbus_message_iter_init :: proc(msg: ^DBus_Msg, it: ^DBus_Iter) -> b32 ---
	dbus_message_iter_init_append :: proc(msg: ^DBus_Msg, it: ^DBus_Iter) ---
	dbus_message_iter_get_arg_type :: proc(it: ^DBus_Iter) -> c.int ---
	dbus_message_iter_get_basic :: proc(it: ^DBus_Iter, value: rawptr) ---
	dbus_message_iter_next :: proc(it: ^DBus_Iter) -> b32 ---
	dbus_message_iter_recurse :: proc(it: ^DBus_Iter, sub: ^DBus_Iter) ---
	dbus_message_iter_append_basic :: proc(it: ^DBus_Iter, kind: c.int, value: rawptr) -> b32 ---
	dbus_message_iter_open_container :: proc(it: ^DBus_Iter, kind: c.int, sig: cstring, sub: ^DBus_Iter) -> b32 ---
	dbus_message_iter_close_container :: proc(it: ^DBus_Iter, sub: ^DBus_Iter) -> b32 ---
}

// ---------- reading ----------

dbus_str :: proc(it: ^DBus_Iter) -> string {
	if dbus_message_iter_get_arg_type(it) != DT_STRING do return ""
	s: cstring
	dbus_message_iter_get_basic(it, &s)
	return strings.clone(string(s))
}

dbus_u32 :: proc(it: ^DBus_Iter) -> u32 {
	switch dbus_message_iter_get_arg_type(it) {
	case DT_UINT32, DT_INT32, DT_BOOLEAN: v: u32; dbus_message_iter_get_basic(it, &v); return v
	case DT_BYTE: v: u8; dbus_message_iter_get_basic(it, &v); return u32(v)
	case DT_INT64: v: i64; dbus_message_iter_get_basic(it, &v); return u32(v)
	}
	return 0
}

dbus_i32 :: proc(it: ^DBus_Iter) -> i32 {
	switch dbus_message_iter_get_arg_type(it) {
	case DT_INT32, DT_UINT32, DT_BOOLEAN: v: i32; dbus_message_iter_get_basic(it, &v); return v
	case DT_BYTE: v: u8; dbus_message_iter_get_basic(it, &v); return i32(v)
	case DT_INT64: v: i64; dbus_message_iter_get_basic(it, &v); return i32(v)
	}
	return 0
}

// ---------- writing ----------

dbus_put_str :: proc(it: ^DBus_Iter, s: string) {
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	dbus_message_iter_append_basic(it, DT_STRING, &cs)
}

dbus_put_u32 :: proc(it: ^DBus_Iter, v: u32) {
	x := v
	dbus_message_iter_append_basic(it, DT_UINT32, &x)
}
