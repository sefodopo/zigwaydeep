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

    try wlClient.sync();

    const compositor = try WlCompositor.init(wlClient);
    defer allocator.destroy(compositor);

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
        objects[1] = .{ .ptr = client, .handleEvent = &handleEvent, .destroying = &false };
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

    fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) std.mem.Allocator.Error!void {
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
                    } else {
                        std.log.debug("wl_display delete_id for {} found and freeing id for future use", .{did});
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

    fn handleRegistryEvent(ptr: *anyopaque, event: u16, data: []const u32) std.mem.Allocator.Error!void {
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

    fn sync(d: *WlClient) !void {
        std.log.debug("wl_display sync() BEGIN", .{});
        var cbid: u32 = undefined;
        const wlobject = try d.newId(&cbid);
        const msg: [3]u32 = .{ DISPLAY_ID, 12 << 16 | 0, cbid };
        var done = false;
        const CB = struct {
            fn handle(ptr: *anyopaque, event: u16, data: []const u32) !void {
                _ = event;
                _ = data;
                const donesys: *bool = @ptrCast(@alignCast(ptr));
                donesys.* = true;
            }
        };
        wlobject.* = .{
            .ptr = &done,
            .handleEvent = CB.handle,
            .destroying = &true,
        };
        try d.conn.writeAll(@ptrCast(&msg));
        while (!done) {
            try d.read();
        }
        std.log.debug("wl_display sync() END", .{});
    }

    fn newId(d: *WlClient, new_id: *u32) !*?WlObject {
        if (d.free_ids.removeOrNull()) |id| {
            new_id.* = id;
            return &d.objects.items[id];
        }
        new_id.* = d.next_id;
        d.next_id += 1;
        return try d.objects.addOne();
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

    fn bind(c: *WlClient, interface: []const u8, version: u32, new_id: *u32, wl_object: WlObject, destroy: ?*const fn () void) !void {
        // find global
        var git = c.globals.iterator();
        const global: *WlGlobalEntry = while (git.next()) |entry| {
            if (std.mem.startsWith(u8, entry.value_ptr.interface, interface)) {
                break entry.value_ptr;
            }
        } else {
            return error.GlobalInterfaceNotSupported;
        };
        var vers = version;
        if (vers == 0) {
            vers = global.version;
        }
        if (global.destroy) |_| {
            return error.GlobalAlreadyBound;
        }

        (try c.newId(new_id)).* = wl_object;
        global.destroy = destroy;

        const int_len = global.interface.len >> 2;
        const msg_size = 6 + int_len;
        const msg: []u32 = try c.allocator.alloc(u32, msg_size);
        msg[0] = REGISTRY_ID;
        msg[1] = @intCast(msg_size << 20 | 0);
        msg[2] = global.name;
        msg[3] = @intCast(interface.len);
        std.mem.copyForwards(u8, @ptrCast(msg[4..]), global.interface);
        msg[4 + int_len] = vers;
        msg[5 + int_len] = new_id.*;
        try c.conn.writeAll(@ptrCast(msg));
    }
};

const WlCompositor = struct {
    id: u32,
    client: *WlClient,

    fn init(client: *WlClient) !*WlCompositor {
        // TODO: handle the compositor being removed globaly
        const comp = try client.allocator.create(WlCompositor);
        comp.client = client;

        try client.bind("wl_compositor", 0, &comp.id, .{
            .ptr = comp,
            .handleEvent = null,
            .destroying = &false,
        }, null);

        std.log.debug("wl_compositor created with id: {}", .{comp.id});
        return comp;
    }
};
