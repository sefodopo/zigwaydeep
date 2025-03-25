const builtin = @import("builtin");
const std = @import("std");
const wayland = @import("wayland.zig");

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    const allocator = gpalloc.allocator();

    var client = try wayland.WlClient.init(allocator);
    defer client.deinit();

    try client.sync();

    const compositor = try wayland.WlCompositor.init(client);
    defer allocator.destroy(compositor);

    const surface = try compositor.createSurface();
    defer surface.destroy() catch |err| {
        std.log.err("unable to update server about destroyed surface: {}", .{err});
    };

    const shm = try wayland.WlShm.create(client);
    defer shm.release() catch |err| {
        std.log.err("unable to release wl_shm from the server: {}", .{err});
    };

    const pool = try shm.createPool(300 * 300 * 4);
    defer pool.destroy();

    while (true) {
        try client.read();
    }

    std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
}
