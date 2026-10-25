package k4

import "core:c"

foreign import xkbcommon "system:xkbcommon"

xkb_context        :: struct {}
xkb_keymap         :: struct {}
xkb_state          :: struct {}
xkb_compose_table  :: struct {}
xkb_compose_state  :: struct {}

XKB_KEYMAP_FORMAT_TEXT_V1 :: 1
XKB_STATE_MODS_EFFECTIVE  :: 1 << 3
XKB_COMPOSE_FEED_ACCEPTED :: 1
XKB_COMPOSE_NOTHING   :: 0
XKB_COMPOSE_COMPOSING :: 1
XKB_COMPOSE_COMPOSED  :: 2
XKB_COMPOSE_CANCELLED :: 3

@(default_calling_convention = "c", link_prefix = "xkb_")
foreign xkbcommon {
	context_new                   :: proc(flags: c.int) -> ^xkb_context ---
	keymap_new_from_string        :: proc(ctx: ^xkb_context, s: cstring, format: c.int, flags: c.int) -> ^xkb_keymap ---
	keymap_unref                  :: proc(km: ^xkb_keymap) ---
	keymap_key_repeats            :: proc(km: ^xkb_keymap, key: u32) -> c.int ---
	state_new                     :: proc(km: ^xkb_keymap) -> ^xkb_state ---
	state_unref                   :: proc(st: ^xkb_state) ---
	state_update_mask             :: proc(st: ^xkb_state, depressed, latched, locked, dep_layout, lat_layout, lock_layout: u32) -> c.int ---
	state_key_get_one_sym         :: proc(st: ^xkb_state, key: u32) -> u32 ---
	state_key_get_utf8            :: proc(st: ^xkb_state, key: u32, buf: [^]u8, size: c.size_t) -> c.int ---
	state_mod_name_is_active      :: proc(st: ^xkb_state, name: cstring, type: c.int) -> c.int ---
	keysym_to_utf32               :: proc(sym: u32) -> u32 ---
	compose_table_new_from_locale :: proc(ctx: ^xkb_context, locale: cstring, flags: c.int) -> ^xkb_compose_table ---
	compose_state_new             :: proc(t: ^xkb_compose_table, flags: c.int) -> ^xkb_compose_state ---
	compose_state_feed            :: proc(st: ^xkb_compose_state, sym: u32) -> c.int ---
	compose_state_get_status      :: proc(st: ^xkb_compose_state) -> c.int ---
	compose_state_get_utf8        :: proc(st: ^xkb_compose_state, buf: [^]u8, size: c.size_t) -> c.int ---
	compose_state_reset           :: proc(st: ^xkb_compose_state) ---
}

keysym_to_key :: proc(sym: u32) -> Key {
	switch sym {
	case 0xff1b: return .Escape
	case 0xff0d, 0xff8d: return .Enter
	case 0xff52, 0xff97: return .Up
	case 0xff54, 0xff99: return .Down
	case 0xff55, 0xff9a: return .Page_Up
	case 0xff56, 0xff9b: return .Page_Down
	case 0xff51, 0xff96: return .Left
	case 0xff53, 0xff98: return .Right
	case 0xff50, 0xff95: return .Home
	case 0xff57, 0xff9c: return .End
	case 0xff08: return .Backspace
	case 0xffff, 0xff9f: return .Delete
	case 0xff09: return .Tab
	case 0xfe20: return .Back_Tab
	}
	return .None
}
