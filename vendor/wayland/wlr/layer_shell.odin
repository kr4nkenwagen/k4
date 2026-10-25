#+build linux
package wlr
@(private)
wlr_layer_shell_unstable_v1_types := []^interface {
	nil,
	nil,
	nil,
	nil,
	&layer_surface_v1_interface,
	&wl.surface_interface,
	&wl.output_interface,
	nil,
	nil,
	&xdg.popup_interface,
}
/* Clients can use this interface to assign the surface_layer role to
      wl_surfaces. Such surfaces are assigned to a "layer" of the output and
      rendered with a defined z-depth respective to each other. They may also be
      anchored to the edges and corners of a screen and specify input handling
      semantics. This interface should be suitable for the implementation of
      many desktop shell components, and a broad number of other applications
      that interact with the desktop. */
layer_shell_v1 :: struct {}
layer_shell_v1_set_user_data :: proc "contextless" (layer_shell_v1_: ^layer_shell_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)layer_shell_v1_, user_data)
}

layer_shell_v1_get_user_data :: proc "contextless" (layer_shell_v1_: ^layer_shell_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)layer_shell_v1_)
}

/* Create a layer surface for an existing surface. This assigns the role of
        layer_surface, or raises a protocol error if another role is already
        assigned.

        Creating a layer surface from a wl_surface which has a buffer attached
        or committed is a client error, and any attempts by a client to attach
        or manipulate a buffer prior to the first layer_surface.configure call
        must also be treated as errors.

        After creating a layer_surface object and setting it up, the client
        must perform an initial commit without any buffer attached.
        The compositor will reply with a layer_surface.configure event.
        The client must acknowledge it and is then allowed to attach a buffer
        to map the surface.

        You may pass NULL for output to allow the compositor to decide which
        output to use. Generally this will be the one that the user most
        recently interacted with.

        Clients can specify a namespace that defines the purpose of the layer
        surface. */
LAYER_SHELL_V1_GET_LAYER_SURFACE :: 0
layer_shell_v1_get_layer_surface :: proc "contextless" (layer_shell_v1_: ^layer_shell_v1, surface_: ^wl.surface, output_: ^wl.output, layer_: layer_shell_v1_layer, namespace_: cstring) -> ^layer_surface_v1 {
	ret := proxy_marshal_flags(cast(^proxy)layer_shell_v1_, LAYER_SHELL_V1_GET_LAYER_SURFACE, &layer_surface_v1_interface, proxy_get_version(cast(^proxy)layer_shell_v1_), 0, nil, surface_, output_, layer_, namespace_)
	return cast(^layer_surface_v1)ret
}

/* This request indicates that the client will not use the layer_shell
        object any more. Objects that have been created through this instance
        are not affected. */
LAYER_SHELL_V1_DESTROY :: 1
layer_shell_v1_destroy :: proc "contextless" (layer_shell_v1_: ^layer_shell_v1) {
	proxy_marshal_flags(cast(^proxy)layer_shell_v1_, LAYER_SHELL_V1_DESTROY, nil, proxy_get_version(cast(^proxy)layer_shell_v1_), 1)
}

/*  */
layer_shell_v1_error :: enum i32 {
	role = 0,
	invalid_layer = 1,
	already_constructed = 2,
}
/* These values indicate which layers a surface can be rendered in. They
        are ordered by z depth, bottom-most first. Traditional shell surfaces
        will typically be rendered between the bottom and top layers.
        Fullscreen shell surfaces are typically rendered at the top layer.
        Multiple surfaces can share a single layer, and ordering within a
        single layer is undefined. */
layer_shell_v1_layer :: enum i32 {
	background = 0,
	bottom = 1,
	top = 2,
	overlay = 3,
}
@(private)
layer_shell_v1_requests := []message {
	{"get_layer_surface", "no?ous", raw_data(wlr_layer_shell_unstable_v1_types)[4:]},
	{"destroy", "3", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
}

layer_shell_v1_interface : interface

/* An interface that may be implemented by a wl_surface, for surfaces that
      are designed to be rendered as a layer of a stacked desktop-like
      environment.

      Layer surface state (layer, size, anchor, exclusive zone,
      margin, interactivity) is double-buffered, and will be applied at the
      time wl_surface.commit of the corresponding wl_surface is called.

      Attaching a null buffer to a layer surface unmaps it.

      Unmapping a layer_surface means that the surface cannot be shown by the
      compositor until it is explicitly mapped again. The layer_surface
      returns to the state it had right after layer_shell.get_layer_surface.
      The client can re-map the surface by performing a commit without any
      buffer attached, waiting for a configure event and handling it as usual. */
layer_surface_v1 :: struct {}
layer_surface_v1_set_user_data :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)layer_surface_v1_, user_data)
}

layer_surface_v1_get_user_data :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)layer_surface_v1_)
}

/* Sets the size of the surface in surface-local coordinates. The
        compositor will display the surface centered with respect to its
        anchors.

        If you pass 0 for either value, the compositor will assign it and
        inform you of the assignment in the configure event. You must set your
        anchor to opposite edges in the dimensions you omit; not doing so is a
        protocol error. Both values are 0 by default.

        Size is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_SIZE :: 0
layer_surface_v1_set_size :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, width_: u32, height_: u32) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_SIZE, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, width_, height_)
}

/* Requests that the compositor anchor the surface to the specified edges
        and corners. If two orthogonal edges are specified (e.g. 'top' and
        'left'), then the anchor point will be the intersection of the edges
        (e.g. the top left corner of the output); otherwise the anchor point
        will be centered on that edge, or in the center if none is specified.

        Anchor is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_ANCHOR :: 1
layer_surface_v1_set_anchor :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, anchor_: layer_surface_v1_anchor) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_ANCHOR, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, anchor_)
}

/* Requests that the compositor avoids occluding an area with other
        surfaces. The compositor's use of this information is
        implementation-dependent - do not assume that this region will not
        actually be occluded.

        A positive value is only meaningful if the surface is anchored to one
        edge or an edge and both perpendicular edges. If the surface is not
        anchored, anchored to only two perpendicular edges (a corner), anchored
        to only two parallel edges or anchored to all edges, a positive value
        will be treated the same as zero.

        A positive zone is the distance from the edge in surface-local
        coordinates to consider exclusive.

        Surfaces that do not wish to have an exclusive zone may instead specify
        how they should interact with surfaces that do. If set to zero, the
        surface indicates that it would like to be moved to avoid occluding
        surfaces with a positive exclusive zone. If set to -1, the surface
        indicates that it would not like to be moved to accommodate for other
        surfaces, and the compositor should extend it all the way to the edges
        it is anchored to.

        For example, a panel might set its exclusive zone to 10, so that
        maximized shell surfaces are not shown on top of it. A notification
        might set its exclusive zone to 0, so that it is moved to avoid
        occluding the panel, but shell surfaces are shown underneath it. A
        wallpaper or lock screen might set their exclusive zone to -1, so that
        they stretch below or over the panel.

        The default value is 0.

        Exclusive zone is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_EXCLUSIVE_ZONE :: 2
layer_surface_v1_set_exclusive_zone :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, zone_: i32) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_EXCLUSIVE_ZONE, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, zone_)
}

/* Requests that the surface be placed some distance away from the anchor
        point on the output, in surface-local coordinates. Setting this value
        for edges you are not anchored to has no effect.

        The exclusive zone includes the margin.

        Margin is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_MARGIN :: 3
layer_surface_v1_set_margin :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, top_: i32, right_: i32, bottom_: i32, left_: i32) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_MARGIN, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, top_, right_, bottom_, left_)
}

/* Set how keyboard events are delivered to this surface. By default,
        layer shell surfaces do not receive keyboard events; this request can
        be used to change this.

        This setting is inherited by child surfaces set by the get_popup
        request.

        Layer surfaces receive pointer, touch, and tablet events normally. If
        you do not want to receive them, set the input region on your surface
        to an empty region.

        Keyboard interactivity is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_KEYBOARD_INTERACTIVITY :: 4
layer_surface_v1_set_keyboard_interactivity :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, keyboard_interactivity_: layer_surface_v1_keyboard_interactivity) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_KEYBOARD_INTERACTIVITY, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, keyboard_interactivity_)
}

/* This assigns an xdg_popup's parent to this layer_surface.  This popup
        should have been created via xdg_surface::get_popup with the parent set
        to NULL, and this request must be invoked before committing the popup's
        initial state.

        See the documentation of xdg_popup for more details about what an
        xdg_popup is and how it is used. */
LAYER_SURFACE_V1_GET_POPUP :: 5
layer_surface_v1_get_popup :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, popup_: ^xdg.popup) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_GET_POPUP, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, popup_)
}

/* When a configure event is received, if a client commits the
        surface in response to the configure event, then the client
        must make an ack_configure request sometime before the commit
        request, passing along the serial of the configure event.

        If the client receives multiple configure events before it
        can respond to one, it only has to ack the last configure event.

        A client is not required to commit immediately after sending
        an ack_configure request - it may even ack_configure several times
        before its next surface commit.

        A client may send multiple ack_configure requests before committing, but
        only the last request sent before a commit indicates which configure
        event the client really is responding to. */
LAYER_SURFACE_V1_ACK_CONFIGURE :: 6
layer_surface_v1_ack_configure :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, serial_: u32) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_ACK_CONFIGURE, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, serial_)
}

/* This request destroys the layer surface. */
LAYER_SURFACE_V1_DESTROY :: 7
layer_surface_v1_destroy :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_DESTROY, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 1)
}

/* Change the layer that the surface is rendered on.

        Layer is double-buffered, see wl_surface.commit. */
LAYER_SURFACE_V1_SET_LAYER :: 8
layer_surface_v1_set_layer :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, layer_: layer_shell_v1_layer) {
	proxy_marshal_flags(cast(^proxy)layer_surface_v1_, LAYER_SURFACE_V1_SET_LAYER, nil, proxy_get_version(cast(^proxy)layer_surface_v1_), 0, layer_)
}

layer_surface_v1_listener :: struct {
/* The configure event asks the client to resize its surface.

        Clients should arrange their surface for the new states, and then send
        an ack_configure request with the serial sent in this configure event at
        some point before committing the new surface.

        The client is free to dismiss all but the last configure event it
        received.

        The width and height arguments specify the size of the window in
        surface-local coordinates.

        The size is a hint, in the sense that the client is free to ignore it if
        it doesn't resize, pick a smaller size (to satisfy aspect ratio or
        resize in steps of NxM pixels). If the client picks a smaller size and
        is anchored to two opposite anchors (e.g. 'top' and 'bottom'), the
        surface will be centered on this axis.

        If the width or height arguments are zero, it means the client should
        decide its own window dimension. */
	configure : proc "c" (data: rawptr, layer_surface_v1_: ^layer_surface_v1, serial_: u32, width_: u32, height_: u32),

/* The closed event is sent by the compositor when the surface will no
        longer be shown. The output may have been destroyed or the user may
        have asked for it to be removed. Further changes to the surface will be
        ignored. The client should destroy the resource after receiving this
        event, and create a new surface if they so choose. */
	closed : proc "c" (data: rawptr, layer_surface_v1_: ^layer_surface_v1),

}
layer_surface_v1_add_listener :: proc "contextless" (layer_surface_v1_: ^layer_surface_v1, listener: ^layer_surface_v1_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)layer_surface_v1_, cast(^generic_c_call)listener,data)
}
/* Types of keyboard interaction possible for layer shell surfaces. The
        rationale for this is twofold: (1) some applications are not interested
        in keyboard events and not allowing them to be focused can improve the
        desktop experience; (2) some applications will want to take exclusive
        keyboard focus. */
layer_surface_v1_keyboard_interactivity :: enum i32 {
	none = 0,
	exclusive = 1,
	on_demand = 2,
}
/*  */
layer_surface_v1_error :: enum i32 {
	invalid_surface_state = 0,
	invalid_size = 1,
	invalid_anchor = 2,
	invalid_keyboard_interactivity = 3,
}
/*  */
layer_surface_v1_anchor :: enum i32 {
	top = 1,
	bottom = 2,
	left = 4,
	right = 8,
}
@(private)
layer_surface_v1_requests := []message {
	{"set_size", "uu", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"set_anchor", "u", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"set_exclusive_zone", "i", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"set_margin", "iiii", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"set_keyboard_interactivity", "u", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"get_popup", "o", raw_data(wlr_layer_shell_unstable_v1_types)[9:]},
	{"ack_configure", "u", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"destroy", "", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"set_layer", "2u", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
}

@(private)
layer_surface_v1_events := []message {
	{"configure", "uuu", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
	{"closed", "", raw_data(wlr_layer_shell_unstable_v1_types)[0:]},
}

layer_surface_v1_interface : interface

@(private)
@(init)
init_interfaces_wlr_layer_shell_unstable_v1 :: proc "contextless" () {
	layer_shell_v1_interface.name = "zwlr_layer_shell_v1"
	layer_shell_v1_interface.version = 4
	layer_shell_v1_interface.method_count = 2
	layer_shell_v1_interface.event_count = 0
	layer_shell_v1_interface.methods = raw_data(layer_shell_v1_requests)
	layer_surface_v1_interface.name = "zwlr_layer_surface_v1"
	layer_surface_v1_interface.version = 4
	layer_surface_v1_interface.method_count = 9
	layer_surface_v1_interface.event_count = 2
	layer_surface_v1_interface.methods = raw_data(layer_surface_v1_requests)
	layer_surface_v1_interface.events = raw_data(layer_surface_v1_events)
}

// Functions from libwayland-client
import wl ".."
import xdg "../xdg"
fixed_t :: wl.fixed_t
proxy :: wl.proxy
message :: wl.message
interface :: wl.interface
array :: wl.array
generic_c_call :: wl.generic_c_call
proxy_add_listener :: wl.proxy_add_listener
proxy_get_listener :: wl.proxy_get_listener
proxy_get_user_data :: wl.proxy_get_user_data
proxy_set_user_data :: wl.proxy_set_user_data
proxy_get_version :: wl.proxy_get_version
proxy_marshal :: wl.proxy_marshal
proxy_marshal_flags :: wl.proxy_marshal_flags
proxy_marshal_constructor :: wl.proxy_marshal_constructor
proxy_destroy :: wl.proxy_destroy
