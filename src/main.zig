const builtin = @import("builtin");
const std = @import("std");
const wayland = @import("wayland.zig");

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    const allocator = gpalloc.allocator();

    var client = try wayland.Client.init(allocator);
    defer client.deinit();

    try client.sync();

    const compositor = try wayland.Compositor.init(client);
    defer allocator.destroy(compositor);

    const surface = try compositor.createSurface();
    defer surface.destroy() catch |err| {
        std.log.err("unable to update server about destroyed surface: {}", .{err});
    };

    const shm = try wayland.Shm.create(client);
    defer shm.release() catch |err| {
        std.log.err("unable to release wl_shm from the server: {}", .{err});
    };

    const pool = try shm.createPool(300 * 300 * 4);
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, 300, 300, 4, wayland.Shm.Format.xrgb8888);
    defer buffer.destroy();

    while (true) {
        try client.read();
    }

    std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
}
