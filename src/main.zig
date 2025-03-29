const std = @import("std");

const wl = @import("wayland.zig");

const Stream = std.net.Stream;

const Global = struct {
    interface: []const u8,
    version: u32,
};

const State = struct {
    globals: std.AutoArrayHashMap(u32, Global),
    running: bool = true,
    callback_done: bool = false,
    allocator: std.mem.Allocator,

    display: wl.Display = undefined,
    registry: wl.Registry = undefined,
    compositor: wl.Compositor = undefined,
    shm: wl.Shm = undefined,
    xdg_wm_base: wl.XdgWmBase = undefined,
    xdg_decoration_manager: ?wl.XdgDecorationManager = null,

    surface: wl.Surface = undefined,
    xdg_surface: wl.XdgSurface = undefined,
    toplevel: wl.XdgToplevel = undefined,
    xdg_decoration: ?wl.XdgToplevelDecoration = null,
    pool: wl.ShmPool = undefined,
    buffer: wl.Buffer = undefined,

    width: u32 = 600,
    height: u32 = 600,
    last_suggestion: ?std.meta.TagPayload(wl.XdgToplevel.Event, .configure) = null,
    bound_width: u32 = 0,
    bound_height: u32 = 0,
};

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    defer std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
    const allocator = gpalloc.allocator();

    var state = State{
        .globals = std.AutoArrayHashMap(u32, Global).init(allocator),
        .allocator = allocator,
    };
    defer {
        for (state.globals.values()) |global| {
            allocator.free(global.interface);
        }
        state.globals.deinit();
    }

    try initWindow(&state);

    while (state.running) {
        try state.display.read();
    }
}

fn initWindow(state: *State) !void {
    state.display = try wl.Display.init(state.allocator);
    errdefer state.display.deinit();
    try state.display.setHandler(state, handleDisplay);

    state.registry = try state.display.getRegistry();
    try state.registry.setHandler(state, handleRegistry);

    var cb = try state.display.sync();
    try cb.setHandler(state, handleCallback);

    while (!state.callback_done) {
        try state.display.read();
    }

    const compositor = try getGlobal(state, wl.Compositor, "wl_compositor");
    state.shm = try getGlobal(state, wl.Shm, "wl_shm");
    try state.shm.setHandler(state, handleShm);
    const xdg_wm_base = try getGlobal(state, wl.XdgWmBase, "xdg_wm_base");
    try xdg_wm_base.setHandler(state, handleXdgWm);
    const xdg_decor_manager: ?wl.XdgDecorationManager = getGlobal(
        state,
        wl.XdgDecorationManager,
        "zxdg_decoration_manager_v1",
    ) catch null;

    state.pool = try state.shm.createPool(state.width * state.height * 4);
    state.buffer = try state.pool.createBuffer(0, state.width, state.height, state.width * 4, .xrgb8888);

    state.surface = try compositor.createSurface();
    state.xdg_surface = try xdg_wm_base.getXdgSurface(state.surface);
    try state.xdg_surface.setHandler(state, handleXdgSurface);
    const toplevel = try state.xdg_surface.getToplevel();
    try toplevel.setHandler(state, handleToplevel);
    const decor = if (xdg_decor_manager) |dm| try dm.getToplevelDecoration(toplevel) else null;
    if (decor) |dec| {
        try dec.setMode(.server_side);
    }
    try toplevel.setTitle("Hello Zigity");
    try toplevel.setMinSize(400, 400);
    try state.surface.commit();
    try state.surface.attach(state.buffer, 0, 0);
}

fn handleXdgSurface(_: *wl.XdgSurface, state: *State, event: wl.XdgSurface.Event) !void {
    if (state.last_suggestion) |suggestion| {
        // cannot access the states since we haven't copied them yet
        state.last_suggestion = null;
        if (suggestion.width != 0 and suggestion.height != 0 and
            (suggestion.width != state.width or suggestion.height != state.height))
        {
            state.width = suggestion.width;
            state.height = suggestion.height;
            const stride = suggestion.width * 4;
            const size = stride * suggestion.height;
            if (size > state.pool.data.len) {
                const newSize = @max(size, state.pool.data.len * 2);
                try state.pool.resize(@intCast(newSize));
            }
            const buffer = try state.pool.createBuffer(
                0,
                suggestion.width,
                suggestion.height,
                stride,
                .xrgb8888,
            );

            try state.surface.attach(buffer, 0, 0);
            state.buffer = buffer;
            for (@as([]u32, @ptrCast(state.pool.data[0..size]))) |*pix| {
                pix.* = 0xff0f0f0f;
            }
        }
    }
    try state.xdg_surface.ackConfigure(event.configure);
    try state.surface.commit();
}

fn handleXdgWm(wm: *const wl.XdgWmBase, _: *State, event: wl.XdgWmBase.Event) !void {
    std.log.debug("sending pong: {}", .{event.ping});
    try wm.pong(event.ping);
}

fn getGlobal(state: *State, G: type, interface: []const u8) !G {
    var it = state.globals.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.interface, interface)) {
            const g = G.init(&state.display);
            try state.registry.bind(entry.key_ptr.*, interface, entry.value_ptr.version, g);
            return g;
        }
    }
    return error.NoSuchGlobal;
}

fn handleShm(_: *wl.Shm, _: *State, event: wl.Shm.Format) !void {
    std.log.debug("Format supported: {x}", .{event});
}

fn handleDisplay(_: *wl.Display, state: *State, event: wl.Display.Event) !void {
    switch (event) {
        .err => |err| {
            state.running = false;
            std.log.err("FATAL ERROR: object_id: {}, code: {s}, message: {s}", .{ err.object_id, @tagName(err.code), err.message });
        },
        .delete_id => |id| {
            std.log.debug("delete_id: {}", .{id});
        },
    }
}

fn handleRegistry(_: *wl.Registry, state: *State, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |gd| {
            try state.globals.put(gd.name, .{
                .interface = try state.globals.allocator.dupe(u8, gd.interface),
                .version = gd.version,
            });
        },
        .global_remove => |name| {
            std.log.warn("global {} removed, hopefully I wasn't using it...", .{name});
        },
    }
}

fn handleCallback(_: *wl.Callback, state: *State, _: void) !void {
    state.callback_done = true;
}

fn handleToplevel(_: *wl.XdgToplevel, state: *State, event: wl.XdgToplevel.Event) !void {
    switch (event) {
        .close => state.running = false,
        .configure => |c| state.last_suggestion = c,
        .configure_bounds => |b| {
            state.bound_width = b.width;
            state.bound_height = b.height;
        },
        else => {},
    }
}
