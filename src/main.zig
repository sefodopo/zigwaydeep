const builtin = @import("builtin");
const std = @import("std");

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    const allocator = gpalloc.allocator();

    var wlClient = try WlClient.init(allocator);
    defer wlClient.deinit();

    while (true) {
        try wlClient.read();
    }

    std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
}

const WlObject = struct {
    ptr: *anyopaque,
    destroying: *const bool,
    handleEvent: ?*const fn (ptr: *anyopaque, event: u16, data: []const u32) std.mem.Allocator.Error!void,
};

const WlGlobalEntry = struct {
    name: u32,
    interface: []const u8,
    version: u32,
    /// Called when the global is removed by the server and should be destroyed
    destroy: ?*const fn () void = null,
};

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

const NewIdQueue = std.PriorityQueue(u32, void, lessThan);

const WlClient = struct {
    const DISPLAY_ID: u32 = 1;
    const REGISTRY_ID: u32 = 2;
    conn: std.net.Stream,
    next_id: u32,
    free_ids: NewIdQueue,
    objects: std.ArrayList(?WlObject),
    allocator: std.mem.Allocator,
    globals: std.AutoArrayHashMap(u32, WlGlobalEntry),

    /// The allocator is used to create the client;
    /// it is the callers responsibility to call deinit
    /// to free up the memory allocated.
    fn init(allocator: std.mem.Allocator) !*WlClient {
        // Open the socket
        const conn = blk: {
            const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirNotFound;
            const wayland = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
            const path = if (wayland[0] == '/')
                wayland
            else
                try std.fs.path.join(allocator, &.{ dir, wayland });
            std.log.debug("Opening connection to {s}", .{path});
            const conn = try std.net.connectUnixSocket(path);
            if (wayland[0] != '/') allocator.free(path);
            break :blk conn;
        };

        // Connect the registry
        const reg_msg: [3]u32 = .{ 1, 12 << 16 | 1, 2 };
        try conn.writeAll(@ptrCast(&reg_msg));

        var client = try allocator.create(WlClient);
        client.* = .{
            .conn = conn,
            .next_id = 3,
            .free_ids = NewIdQueue.init(allocator, {}),
            .objects = std.ArrayList(?WlObject).init(allocator),
            .allocator = allocator,
            .globals = std.AutoArrayHashMap(u32, WlGlobalEntry).init(allocator),
        };
        const objects = try client.objects.addManyAsArray(3);
        objects[0] = null;
        objects[1] = .{ .ptr = client, .handleEvent = handleEvent, .destroying = &false };
        objects[2] = .{ .ptr = client, .handleEvent = &handleRegistryEvent, .destroying = &false };

        return client;
    }

    /// Frees all the memory created
    fn deinit(d: *WlClient) void {
        d.objects.deinit();
        var it = d.globals.iterator();
        while (it.next()) |global| {
            d.allocator.free(global.value_ptr.interface);
        }
        d.globals.deinit();
        d.free_ids.deinit();
        d.allocator.destroy(d);
    }

    fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
        const c: *WlClient = @ptrCast(@alignCast(ptr));
        switch (event) {
            0 => {
                // error
                const object_id = data[0];
                const code = data[1];
                const errmsg: []const u8 = @ptrCast(data[3..]);
                const Err = enum(u32) {
                    invalid_object,
                    invalid_method,
                    no_memory,
                    implementation,
                    _,
                };
                const err: Err = @enumFromInt(code);
                std.log.err("wl_display received an error: object: {}, code: {}, message: {s}", .{ object_id, err, errmsg });
            },
            1 => {
                // delete_id
                const did = data[0];
                if (c.objects.items[did]) |object| {
                    if (!object.destroying.*) {
                        std.log.err("wl_display got delete_id for client object: {} which was not being destroyed!", .{did});
                        return;
                    }
                }
                c.objects.items[did] = null;
                try c.free_ids.add(did);
            },
            else => {
                std.log.warn("wl_display got unrecognized event: {}", .{event});
            },
        }
    }

    fn handleRegistryEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
        const c: *WlClient = @ptrCast(@alignCast(ptr));
        switch (event) {
            0 => {
                // global
                const name = data[0];
                var interface_len = data[1];
                if (interface_len & 0b11 != 0) {
                    interface_len += 4;
                }
                interface_len >>= 2;
                const interface: []const u8 = if (interface_len > 0)
                    try c.allocator.dupe(u8, @ptrCast(data[2 .. 2 + interface_len]))
                else
                    &.{};
                const version: u32 = data[2 + interface_len];
                std.log.debug("global discovered: id: {}, {s}, {}", .{ name, interface, version });
                try c.globals.put(name, .{
                    .name = name,
                    .interface = interface,
                    .version = version,
                });
            },
            1 => {
                // global_remove
                const name = data[0];
                if (c.globals.get(name)) |global| {
                    if (global.destroy) |destroy| {
                        std.log.warn("wl_registry received global_remove for {} which is currently in use, destroying...", .{global.name});
                        destroy();
                    }
                } else {
                    std.log.err("wl_registry received global_remove for {} which does not exist", .{name});
                }
            },
            else => {
                std.log.err("wl_registry received unknown event {}", .{event});
            },
        }
    }

    fn read(d: *WlClient) !void {
        var header: [2]u32 = undefined;
        var n = try d.conn.readAtLeast(@ptrCast(&header), 8);
        if (n != 8) {
            std.log.err("Only got {} bytes instead of 8", .{n});
            return error.NotFullHeader;
        }
        const sender: u32 = header[0];
        const size: u16 = @intCast(header[1] >> 16);
        const event: u16 = @intCast(header[1] & 0xffff);

        // Wayland spec has every message structured as 32bit words
        if (size % 4 != 0) {
            return error.MessageAlignmentError;
        }

        const data = try d.allocator.alloc(u8, size - 8);
        defer d.allocator.free(data);
        n = try d.conn.readAtLeast(data, size - 8);
        if (n != size - 8) @panic("Did not receive rest of message!");

        if (d.objects.items[sender]) |sobj| {
            if (sobj.handleEvent) |he| {
                try he(sobj.ptr, event, @ptrCast(@alignCast(data)));
            }
        } else {
            std.log.warn("event received from server for unknown object: {}, event: {}", .{ sender, event });
        }
    }
};
