const std = @import("std");
const builtin = @import("builtin");

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

    surface: wl.Surface = undefined,
    xdgSurface: wl.XdgSurface = undefined,
    shm: wl.Shm = undefined,
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

    var display = try wl.Display.init(allocator);
    defer display.deinit();
    try display.setHandler(&state, handleDisplay);

    const registry = try display.getRegistry();
    try registry.setHandler(&state, handleRegistry);

    var cb = try display.sync();
    try cb.setHandler(&state, handleCallback);

    while (!state.callback_done) {
        try display.read();
    }

    const compositor = try getGlobal(&state, &display, registry, wl.Compositor, "wl_compositor");
    const shm = try getGlobal(&state, &display, registry, wl.Shm, "wl_shm");
    state.shm = shm;
    const xdg_wm_base = try getGlobal(&state, &display, registry, wl.XdgWmBase, "xdg_wm_base");
    try xdg_wm_base.setHandler(&xdg_wm_base, handleXdgWm);
    const xdg_decor_manager: ?wl.XdgDecorationManager = getGlobal(&state, &display, registry, wl.XdgDecorationManager, "zxdg_decoration_manager_v1") catch null;

    const pool = try shm.createPool(state.width * state.height * 4);
    state.pool = pool;
    const buffer = try pool.createBuffer(0, state.width, state.height, state.width * 4, .xrgb8888);
    state.buffer = buffer;

    const surface = try compositor.createSurface();
    const xdg_surface = try xdg_wm_base.getXdgSurface(surface);
    state.surface = surface;
    state.xdgSurface = xdg_surface;
    try xdg_surface.setHandler(&state, handleXdgSurface);
    const toplevel = try xdg_surface.getToplevel();
    try toplevel.setHandler(&state, handleToplevel);
    const decor = if (xdg_decor_manager) |dm| try dm.getToplevelDecoration(toplevel) else null;
    if (decor) |dec| {
        try dec.setMode(.server_side);
    }
    try toplevel.setTitle("Hello Zigity");
    try toplevel.setMinSize(400, 400);
    try surface.commit();
    try surface.attach(buffer, 0, 0);

    while (state.running) {
        try display.read();
    }
}

fn handleXdgSurface(state: *State, event: wl.XdgSurface.Event) !void {
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
                const buffer = try state.pool.createBuffer(0, suggestion.width, suggestion.height, stride, .xrgb8888);
                try state.xdgSurface.ackConfigure(event.configure);
                try state.surface.attach(buffer, 0, 0);
                try state.surface.commit();
                state.buffer = buffer;
                return;
            } else {
                const buffer = try state.pool.createBuffer(0, suggestion.width, suggestion.height, stride, .xrgb8888);
                try state.xdgSurface.ackConfigure(event.configure);
                try state.surface.attach(buffer, 0, 0);
                try state.surface.commit();
                state.buffer = buffer;
                return;
            }
        }
    }
    try state.xdgSurface.ackConfigure(event.configure);
    try state.surface.commit();
}

fn handleXdgWm(wm: *const wl.XdgWmBase, event: wl.XdgWmBase.Event) !void {
    std.log.debug("sending pong: {}", .{event.ping});
    try wm.pong(event.ping);
}

fn getGlobal(state: *State, display: *wl.Display, registry: wl.Registry, G: type, interface: []const u8) !G {
    var it = state.globals.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.interface, interface)) {
            const g = G.init(display);
            try registry.bind(entry.key_ptr.*, interface, entry.value_ptr.version, g);
            return g;
        }
    }
    return error.NoSuchGlobal;
}

fn handleDisplay(state: *State, event: wl.Display.Event) !void {
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

fn handleRegistry(state: *State, event: wl.Registry.Event) !void {
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

fn handleCallback(state: *State, _: void) !void {
    state.callback_done = true;
}

fn handleToplevel(state: *State, event: wl.XdgToplevel.Event) !void {
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
