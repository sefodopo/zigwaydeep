const std = @import("std");
const builtin = @import("builtin");

const wl = @import("wayland.zig");

const Stream = std.net.Stream;

const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

const State = struct {
    globals: std.AutoArrayHashMap(u32, Global),
    running: bool = true,
};

const WIDTH = 300;
const HEIGHT = 300;

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    defer std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
    const allocator = gpalloc.allocator();

    var decoder = wl.Decoder.init(allocator);
    defer decoder.deinit();

    var state = State{
        .globals = std.AutoArrayHashMap(u32, Global).init(allocator),
    };

    const display = try wl.Display.connect(allocator);
    defer display.close();
    try display.setHandler(&decoder, &state, handleDisplay);

    const registry = try display.getRegistry();
    _ = registry;
    // registry.setHandler(State, &handleRegistry, &state);
}

fn handleDisplay(state: *State, event: wl.Display.Event) !void {
    switch (event) {
        .err => |err| {
            state.running = false;
            std.log.err("FATAL ERROR: {}", .{err});
        },
        .delete_id => |id| {
            std.log.debug("delete_id: {}", .{id});
        },
    }
}

fn sync(allocator: std.mem.Allocator, conn: Stream, state: *State, id: u32) !void {
    if (!state.sync_done) return error.SyncInProgress;
    std.log.debug("starting sync: {}", .{id});
    state.sync_done = false;
    try wl.sync(conn, id);
    state.handlers[id] = &.{&handleSyncDone};
    while (!state.sync_done) {
        try read(allocator, conn, state);
    }
    std.log.debug("sync {} complete", .{id});
}

fn handlePing(state: *State, data: []const u32) !void {
    const serial = data[0];
    try wl.sendMsg(state.conn, 5, 3, .{serial});
    std.log.debug("received ping: {}", .{serial});
}

fn handleClose(state: *State, _: []const u32) !void {
    state.running = false;
    std.log.debug("received close, closing", .{});
}

fn handleXdgConfigure(state: *State, data: []const u32) !void {
    const serial = data[0];
    try wl.sendMsg(state.conn, 9, 4, .{serial});
    try wl.sendMsg(state.conn, 8, 6, .{}); // commit surface
}

fn bind(conn: Stream, globals: std.AutoArrayHashMap(u32, Global), interface: []const u8, version: u32, new_id: u32) !void {
    for (globals.values()) |global| {
        if (std.mem.eql(u8, global.interface, interface)) {
            var v = version;
            if (v == 0) {
                v = global.version;
            }
            try wl.bind(conn, global.name, interface, v, new_id);
        }
    }
}

fn read(allocator: std.mem.Allocator, conn: Stream, state: *State) !void {
    const msg = try wl.readMsg(allocator, conn);
    defer msg.free();
    if (state.handlers[msg.object]) |handlers| {
        if (handlers[msg.event]) |handler| {
            return try handler(state, msg.data);
        }
    }
    std.log.warn("received unhandled event {any}", .{msg});
}

fn handleError(state: *State, data: []const u32) !void {
    _ = state;
    const object = data[0];
    const code = data[1];
    const msg: []const u8 = @ptrCast(data[3..]);
    std.log.err("unrecoverable error detected from object: {} code: {}, msg: {s}", .{ object, code, msg });
    unreachable;
}

fn handleGlobal(state: *State, data: []const u32) !void {
    const name = data[0];
    const intlen = data[1];
    const interface = try state.globals.allocator.alloc(u8, intlen - 1);
    @memcpy(interface, @as([]const u8, @ptrCast(data[2..]))[0 .. intlen - 1]);
    const version = data[data.len - 1];
    std.log.debug("discovered global: {:2} {s:^45} {:2}", .{ name, interface, version });
    try state.globals.put(name, .{
        .name = name,
        .interface = interface,
        .version = version,
    });
}

fn handleGlobalRemove(state: *State, data: []const u32) !void {
    const name = data[0];
    if (state.globals.fetchSwapRemove(name)) |glob| {
        std.log.warn("global {} removed", .{glob.value});
        state.globals.allocator.free(glob.value.interface);
    }
}

fn handleSyncDone(state: *State, _: []const u32) !void {
    state.sync_done = true;
}
