const std = @import("std");

const WlGlobalEntry = struct {
    name: u32,
    interface: []const u8,
    version: u32,
    /// Called when the global is removed by the server and should be destroyed
    object: ?u32,
};

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

const NewIdQueue = std.PriorityQueue(u32, void, lessThan);

pub const WlClient = struct {
    const WlObject = struct {
        ptr: *anyopaque,
        handleEvent: ?EventHandler,
        destroying: bool = false,
        /// Should be set for global objects, should not free the memory, called when
        /// the global_remove event is received for the global object.
        remove: ?*const fn (ptr: *anyopaque) void = null,
    };
    const EventHandler = *const fn (ptr: *anyopaque, event: u16, data: []const u32) std.mem.Allocator.Error!void;
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
    pub fn init(allocator: std.mem.Allocator) !*WlClient {
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
        objects[1] = .{ .ptr = client, .handleEvent = &handleEvent };
        objects[2] = .{ .ptr = client, .handleEvent = &handleRegistryEvent };

        return client;
    }

    /// Frees all the memory created
    pub fn deinit(d: *WlClient) void {
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
                    if (!object.destroying) {
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
                    .object = null,
                });
            },
            1 => {
                // global_remove
                const name = data[0];
                if (c.globals.get(name)) |global| {
                    if (global.object) |objid| {
                        std.log.warn("wl_registry received global_remove for {} which is currently in use, destroying...", .{global.name});
                        if (c.objects.items[objid]) |obj| {
                            if (obj.remove) |remove| {
                                remove(obj.ptr);
                            }
                        }
                        c.objects.items[objid] = null;
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

    pub fn sync(d: *WlClient) !void {
        std.log.debug("wl_display sync() BEGIN", .{});
        var cbid: u32 = undefined;
        var done = false;
        const CB = struct {
            fn handle(ptr: *anyopaque, event: u16, data: []const u32) !void {
                _ = event;
                _ = data;
                const donesys: *bool = @ptrCast(@alignCast(ptr));
                donesys.* = true;
            }
        };
        try d.newId(&cbid, &done, &CB.handle);
        const msg: [3]u32 = .{ DISPLAY_ID, 12 << 16 | 0, cbid };
        try d.conn.writeAll(@ptrCast(&msg));
        while (!done) {
            try d.read();
        }
        d.objects.items[cbid].?.destroying = true;
        std.log.debug("wl_display sync() END", .{});
    }

    fn newId(
        d: *WlClient,
        new_id: *u32,
        ptr: *anyopaque,
        handler: ?EventHandler,
    ) !void {
        const obj = WlObject{
            .ptr = ptr,
            .handleEvent = handler,
        };
        if (d.free_ids.removeOrNull()) |id| {
            new_id.* = id;
            d.objects.items[id] = obj;
            return;
        }
        new_id.* = d.next_id;
        d.next_id += 1;
        try d.objects.append(obj);
    }

    pub fn read(d: *WlClient) !void {
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

    fn bind(c: *WlClient, interface: []const u8, version: u32, new_id: *u32, ptr: *anyopaque, event_handler: ?EventHandler, remove: ?*const fn (*anyopaque) void) !void {
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
        if (global.object) |_| {
            return error.GlobalAlreadyBound;
        }

        try c.newId(new_id, ptr, event_handler);
        c.objects.items[new_id.*].?.remove = remove;
        global.object = new_id.*;

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

pub const WlCompositor = struct {
    id: u32,
    client: *WlClient,
    removed: bool = false,

    /// Caller is responsible for destroying the memory from the
    /// client's allocator
    pub fn init(client: *WlClient) !*WlCompositor {
        const comp = try client.allocator.create(WlCompositor);
        comp.* = WlCompositor{
            .id = 0,
            .client = client,
        };

        try client.bind("wl_compositor", 0, &comp.id, comp, null, &remove);

        std.log.debug("wl_compositor created with id: {}", .{comp.id});
        return comp;
    }

    fn remove(ptr: *anyopaque) void {
        const comp: *WlCompositor = @ptrCast(@alignCast(ptr));
        comp.removed = true;
    }

    /// Caller is responsible for calling destroy() to free the surface memory
    /// and binding with the server
    pub fn createSurface(comp: *WlCompositor) !*WlSurface {
        if (comp.removed) return error.ObjectRemoved;
        const surface = try WlSurface.init(comp.client);
        std.log.debug("wl_compositor creating wl_surface {}", .{surface.id});

        const msg: [3]u32 = .{ comp.id, 12 << 16 | 0, surface.id };
        try comp.client.conn.writeAll(@ptrCast(&msg));

        return surface;
    }
};

pub const WlSurface = struct {
    id: u32,
    client: *WlClient,

    pub fn init(client: *WlClient) !*WlSurface {
        const surface = try client.allocator.create(WlSurface);
        surface.client = client;
        try client.newId(&surface.id, surface, &handleEvent);

        return surface;
    }

    /// Frees the memory and updates the server(compositor)
    pub fn destroy(s: *WlSurface) !void {
        std.log.debug("wl_surface {} destroy()", .{s.id});
        defer s.client.allocator.destroy(s);
        s.client.objects.items[s.id].?.destroying = true;
        const msg: [2]u32 = .{ s.id, 8 << 16 | 0 };
        try s.client.conn.writeAll(@ptrCast(&msg));
    }

    fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
        _ = data;
        const s: *WlSurface = @ptrCast(@alignCast(ptr));
        std.log.warn("wl_surface {} got event {} which is not yet implemented", .{ s.id, event });
    }
};

pub const WlShm = struct {
    pub const Format = enum(u32) {
        argb8888 = 0,
        xrgb8888 = 1,
        c8 = 0x20203843,
        _,
    };
    id: u32,
    client: *WlClient,
    removed: bool = false,

    /// Caller must release this object to free used memory
    /// when done with it.
    pub fn create(client: *WlClient) !*WlShm {
        const shm = try client.allocator.create(WlShm);
        shm.* = WlShm{
            .id = 0,
            .client = client,
        };
        try client.bind("wl_shm", 0, &shm.id, shm, &handleEvent, &remove);
        std.log.debug("wl_shm created and bound to id: {}", .{shm.id});
        return shm;
    }

    /// Creates a pool, TODO: update docstring
    pub fn createPool(shm: *WlShm, size: u32) !*WlShmPool {
        const pool = try WlShmPool.create(shm.client, size);
        errdefer pool.destroy();
        if (pool.data.len != size) {
            std.log.warn("WlShmPool data len {} != size {}", .{ pool.data.len, size });
        }
        const msg = [4]u32{ shm.id, 4 << 20 | 0, pool.id, size };

        // use sendmsg to send the file descriptor over...
        const iov = [_]std.posix.iovec_const{.{
            .base = @ptrCast(&msg),
            .len = msg.len,
        }};
        const cmsg = std.os.linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &extern struct {
                len: usize,
                level: c_int,
                type: c_int,
                data: [@sizeOf(std.posix.fd_t)]u8,
            }{
                .len = 1,
                .level = std.posix.SOL.SOCKET,
                .type = 1, // SCM_RIGHTS
                .data = std.mem.toBytes(pool.fd),
            },
            .controllen = 1,
            .flags = 0,
        };
        const n = try std.posix.sendmsg(shm.client.conn.handle, &cmsg, std.posix.MSG.OOB);
        std.log.info("wl_shm create pool send {} bytes", .{n});
        try shm.client.conn.writeAll(@ptrCast(@alignCast(&msg)));
        return pool;
    }

    fn remove(ptr: *anyopaque) void {
        const shm: *WlShm = @ptrCast(@alignCast(ptr));
        shm.removed = true;
        std.log.warn("wl_shm {} removed by server", .{shm.id});
    }

    /// Destroys the shm and tells the server that the shm
    /// is no longer going to be used anymore. Objects
    /// created via this interface remain unaffected.
    pub fn release(shm: *WlShm) !void {
        std.log.debug("wl_shm {} release()", .{shm.id});
        const msg = [_]u32{ shm.id, 2 << 20 | 1 };
        shm.client.allocator.destroy(shm);
        try shm.client.conn.writeAll(@ptrCast(&msg));
    }

    fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
        _ = ptr;
        if (event != 0) {
            std.log.err("wl_shm got unknown event: {}", .{event});
            return;
        }
        const format: Format = @enumFromInt(data[0]);
        std.log.info("wl_shm: format supported: {}", .{format});
    }
};

pub const WlShmPool = struct {
    id: u32,
    client: *WlClient,
    fd: std.posix.fd_t,
    data: []align(std.heap.page_size_min) u8,

    /// Called internally from WlShm.createPool
    fn create(client: *WlClient, size: u32) !*WlShmPool {
        // try to allocate and mmap shared memory
        const fd = try std.posix.memfd_create("wl_shm_pool", 0);
        errdefer std.posix.close(fd);
        try std.posix.ftruncate(fd, size);

        const data = try std.posix.mmap(
            null,
            @intCast(size),
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(data);

        const pool = try client.allocator.create(WlShmPool);
        pool.* = WlShmPool{
            .id = 0,
            .client = client,
            .fd = fd,
            .data = data,
        };
        errdefer client.allocator.destroy(pool);

        try pool.client.newId(&pool.id, pool, null);
        return pool;
    }

    /// Caller owns the buffer which must be destroy()ed.
    pub fn createBuffer(
        pool: *WlShmPool,
        offset: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: WlShm.Format,
    ) !*WlBuffer {
        const buf = try WlBuffer.init(pool.client);
        errdefer buf.destroy();

        const msg = [_]u32{
            pool.id,
            8 << 20 | 0,
            buf.id,
            offset,
            width,
            height,
            stride,
            @intFromEnum(format),
        };
        try pool.client.conn.writeAll(@ptrCast(&msg));

        return buf;
    }

    /// Destroys and frees up the memory
    pub fn destroy(pool: *WlShmPool) void {
        std.posix.munmap(pool.data);
        std.posix.close(pool.fd);
        const msg = [_]u32{ pool.id, 2 << 20 | 1 };
        pool.client.allocator.destroy(pool);
        pool.client.conn.writeAll(@ptrCast(@alignCast(&msg))) catch |err| {
            std.log.err("wl_shm_pool: unable to send destroy message to server, hope everything is okay: {}", .{err});
        };
    }

    pub fn resize(pool: *WlShmPool, new_size: u32) !void {
        try std.posix.ftruncate(pool.fd, new_size);
        pool.data = try std.posix.mremap(
            pool.data,
            0, // will create a mapping with the same pages since it is shared
            new_size,
            0,
            null,
        );
        const msg = [_]u32{ pool.id, 3 << 20 | 2, new_size };
        try pool.client.conn.writeAll(@ptrCast(&msg));
    }
};

pub const WlBuffer = struct {
    id: u32,
    client: *WlClient,

    fn init(client: *WlClient) !*WlBuffer {
        const buf = try client.allocator.create(WlBuffer);
        errdefer client.allocator.destroy(buf);
        buf.* = .{
            .id = 0,
            .client = client,
        };

        try client.newId(&buf.id, buf, &handleEvent);

        return buf;
    }

    // Destroys and releases the memory
    pub fn destroy(buf: *WlBuffer) void {
        const msg = [_]u32{ buf.id, 2 << 20 | 0 };
        buf.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
            std.log.err("wl_buffer: unable to send destroy to server: {}", .{err});
        };
        buf.client.allocator.destroy(buf);
    }

    fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
        _ = data;
        const buf: *WlBuffer = @ptrCast(@alignCast(ptr));
        if (event != 0) {
            std.log.err("wl_buffer: {} received unknown event: {}", .{ buf.id, event });
            return;
        }
        std.log.info("wl_buffer: {} received release() which is not implemented", .{buf.id});
    }
};
