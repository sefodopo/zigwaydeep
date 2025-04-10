const std = @import("std");

const wl = @import("wayland.zig");

const png = @import("png.zig");

const Stream = std.net.Stream;

const Global = struct {
    interface: []const u8,
    version: u32,
};

const PLAYER_SIZE = 32;
const PLAYER_VELOCITY = 300;

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
    subcompositor: wl.Subcompositor = undefined,
    fractional_scale_manager: ?wl.FractionalScaleManager = null,

    surface: wl.Surface = undefined,
    xdg_surface: wl.XdgSurface = undefined,
    toplevel: wl.XdgToplevel = undefined,
    xdg_decoration: ?wl.XdgToplevelDecoration = null,
    pool: wl.ShmPool = undefined,
    buffer: wl.Buffer = undefined,
    fractional_scale: ?wl.FractionalScale = null,

    width: u32 = 600,
    height: u32 = 600,
    last_suggestion: ?std.meta.TagPayload(wl.XdgToplevel.Event, .configure) = null,
    bound_width: u32 = 0,
    bound_height: u32 = 0,

    player_surface: wl.Surface = undefined,
    player_subsurface: wl.Subsurface = undefined,
    player_pool: wl.ShmPool = undefined,
    player_buffer: wl.Buffer = undefined,
    player_pos: struct { x: f32, y: f32 } = .{ .x = 50, .y = 50 },
    player_direction: enum { right, left, up, down } = .right,

    last_frame_time: u32 = 0,
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

    deinitWindow(&state);
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

    state.compositor = try getGlobal(state, wl.Compositor, "wl_compositor");
    state.shm = try getGlobal(state, wl.Shm, "wl_shm");
    try state.shm.setHandler(state, handleShm);
    state.xdg_wm_base = try getGlobal(state, wl.XdgWmBase, "xdg_wm_base");
    try state.xdg_wm_base.setHandler(state, handleXdgWm);
    state.xdg_decoration_manager = getGlobal(
        state,
        wl.XdgDecorationManager,
        "zxdg_decoration_manager_v1",
    ) catch null;
    state.subcompositor = try getGlobal(state, wl.Subcompositor, "wl_subcompositor");
    state.fractional_scale_manager = getGlobal(
        state,
        wl.FractionalScaleManager,
        "wp_fractional_scale_manager_v1",
    ) catch null;

    state.pool = try state.shm.createPool(state.width * state.height * 4);
    state.buffer = try state.pool.createBuffer(
        0,
        state.width,
        state.height,
        state.width * 4,
        .argb8888,
    );
    try state.buffer.setHandler(state, handleBufferRelease);

    state.surface = try state.compositor.createSurface();
    state.xdg_surface = try state.xdg_wm_base.getXdgSurface(state.surface);
    try state.xdg_surface.setHandler(state, handleXdgSurface);
    state.toplevel = try state.xdg_surface.getToplevel();
    try state.toplevel.setHandler(state, handleToplevel);
    state.xdg_decoration = if (state.xdg_decoration_manager) |dm|
        try dm.getToplevelDecoration(state.toplevel)
    else
        null;
    if (state.xdg_decoration) |dec| {
        try dec.setMode(.server_side);
    }
    try state.toplevel.setTitle("Hello Zigity");
    try state.toplevel.setMinSize(400, 400);
    try state.surface.commit();
    try state.surface.attach(state.buffer, 0, 0);
    state.fractional_scale = if (state.fractional_scale_manager) |fsm|
        try fsm.getFractionalScale(state.surface)
    else
        null;
    if (state.fractional_scale) |fs| {
        try fs.setHandler(state, handlePreferredScale);
    }

    state.player_pool = try state.shm.createPool(PLAYER_SIZE * PLAYER_SIZE * 4);
    state.player_buffer = try state.player_pool.createBuffer(0, PLAYER_SIZE, PLAYER_SIZE, PLAYER_SIZE * 4, .argb8888);
    try state.player_buffer.setHandler(state, handleBufferRelease);
    state.player_surface = try state.compositor.createSurface();
    state.player_subsurface = try state.subcompositor.getSubsurface(state.player_surface, state.surface);
    try state.player_subsurface.setPosition(@intFromFloat(@round(state.player_pos.x)), @intFromFloat(@round(state.player_pos.y)));
    try state.player_surface.commit();
    try png.pngToArgb8888(state.allocator, @embedFile("White_dot.png"), PLAYER_SIZE, PLAYER_SIZE, state.player_pool.data);
    try state.player_surface.attach(state.player_buffer, 0, 0);
    cb = try state.player_surface.frame();
    try cb.setHandler(state, handleFrameCallback);
    try state.player_surface.commit();
}

fn deinitWindow(state: *State) void {
    state.player_subsurface.destroy();
    state.player_surface.destroy();
    state.player_buffer.destroy();
    state.player_pool.destroy();

    if (state.fractional_scale) |fs| fs.destroy();
    if (state.xdg_decoration) |d| d.destroy();
    if (state.xdg_decoration_manager) |d| d.destroy();
    state.toplevel.destroy();
    state.xdg_surface.destroy();
    state.xdg_wm_base.destroy();
    state.surface.destroy();
    state.pool.destroy();
    state.buffer.destroy();

    if (state.fractional_scale_manager) |fsm| fsm.destroy();
    state.subcompositor.destroy();
    state.shm.release();
    state.display.deinit();
}

/// Time is in milliseconds
fn handleFrameCallback(_: *wl.Callback, state: *State, time: u32) !void {
    //std.log.debug("frame callback: {}", .{time});
    const cb = try state.player_surface.frame();
    try cb.setHandler(state, handleFrameCallback);
    if (state.last_frame_time == 0) {
        state.last_frame_time = time;
        try state.player_surface.commit();
        return;
    }
    const dt: f32 = @floatFromInt(time - state.last_frame_time);
    state.last_frame_time = time;
    var next_pos = state.player_pos;
    const dx: f32 = PLAYER_VELOCITY * dt / 1000;
    switch (state.player_direction) {
        .right => next_pos.x += dx,
        .left => next_pos.x -= dx,
        .up => next_pos.y -= dx,
        .down => next_pos.y += dx,
    }
    const width: f32 = @floatFromInt(state.width);
    const height: f32 = @floatFromInt(state.height);
    if (next_pos.x < 0) {
        next_pos.x = width - PLAYER_SIZE;
    } else if (next_pos.x > width - PLAYER_SIZE) {
        next_pos.x = 0;
    }
    if (next_pos.y < 0) {
        next_pos.y = height - PLAYER_SIZE;
    } else if (next_pos.y > height - PLAYER_SIZE) {
        next_pos.y = 0;
    }
    state.player_pos = next_pos;
    try state.player_subsurface.setPosition(@intFromFloat(@round(next_pos.x)), @intFromFloat(@round(next_pos.y)));
    try state.player_surface.commit();
    try state.surface.commit();
}

fn handleBufferRelease(b: *wl.Buffer, _: *State, _: void) !void {
    b.destroy();
    std.log.debug("buffer {} destroyed", .{b.id});
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
                .argb8888,
            );

            try state.surface.attach(buffer, 0, 0);
            state.buffer = buffer;
            for (@as([]u32, @ptrCast(state.pool.data[0..size]))) |*pix| {
                pix.* = 0xe00f0f0f;
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
            std.log.err(
                "FATAL ERROR: object_id: {}, code: {s}, message: {s}",
                .{ err.object_id, @tagName(err.code), err.message },
            );
        },
        .delete_id => |_| {
            //std.log.debug("delete_id: {}", .{id});
        },
    }
}

fn handleRegistry(_: *wl.Registry, state: *State, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |gd| {
            std.log.debug(
                "discovered global: {:2} {s:<40} {:2}",
                .{ gd.name, gd.interface, gd.version },
            );
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

fn handleCallback(_: *wl.Callback, state: *State, _: u32) !void {
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

fn handlePreferredScale(_: *wl.FractionalScale, _: *State, scale: u32) !void {
    std.log.debug("fractional_scale preferred_scale: {}/120", .{scale});
}
