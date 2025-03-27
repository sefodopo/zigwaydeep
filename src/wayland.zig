const std = @import("std");

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

pub fn WaylandClient(comptime A: type) type {
    return struct {
        pub const Client = struct {
            const NewIdQueue = std.PriorityQueue(u32, void, lessThan);
            const Object = struct {
                ptr: *anyopaque,
                handleEvent: ?EventHandler,
                destroying: bool = false,
                /// Should be set for global objects, should not free the memory, called when
                /// the global_remove event is received for the global object.
                remove: ?*const fn (ptr: *anyopaque) void = null,
            };
            const Global = struct {
                name: u32,
                interface: []const u8,
                version: u32,
                /// Called when the global is removed by the server and should be destroyed
                object: ?u32,
            };
            const EventHandler = *const fn (ptr: *anyopaque, event: u16, data: []const u32) anyerror!void;
            const DISPLAY_ID: u32 = 1;
            const REGISTRY_ID: u32 = 2;
            conn: std.net.Stream,
            next_id: u32,
            free_ids: NewIdQueue,
            objects: std.ArrayList(?Object),
            allocator: std.mem.Allocator,
            globals: std.AutoArrayHashMap(u32, Global),
            app: *A,

            /// The allocator is used to create the client;
            /// it is the callers responsibility to call deinit
            /// to free up the memory allocated.
            pub fn init(allocator: std.mem.Allocator, app: *A) !*Client {
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

                var client = try allocator.create(Client);
                client.* = .{
                    .conn = conn,
                    .next_id = 3,
                    .free_ids = NewIdQueue.init(allocator, {}),
                    .objects = std.ArrayList(?Object).init(allocator),
                    .allocator = allocator,
                    .globals = std.AutoArrayHashMap(u32, Global).init(allocator),
                    .app = app,
                };
                const objects = try client.objects.addManyAsArray(3);
                objects[0] = null;
                objects[1] = .{ .ptr = client, .handleEvent = &handleEvent };
                objects[2] = .{ .ptr = client, .handleEvent = &handleRegistryEvent };

                return client;
            }

            /// Frees all the memory created
            pub fn deinit(d: *Client) void {
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
                const c: *Client = @ptrCast(@alignCast(ptr));
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
                const c: *Client = @ptrCast(@alignCast(ptr));
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

            pub fn sync(d: *Client) !void {
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
                std.log.debug("wl_display sync() BEGIN {}", .{cbid});
                const msg: [3]u32 = .{ DISPLAY_ID, 12 << 16 | 0, cbid };
                try d.conn.writeAll(@ptrCast(&msg));
                while (!done) {
                    try d.read();
                }
                d.objects.items[cbid].?.destroying = true;
                std.log.debug("wl_display sync() END", .{});
            }

            fn newId(
                d: *Client,
                new_id: *u32,
                ptr: *anyopaque,
                handler: ?EventHandler,
            ) !void {
                const obj = Object{
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

            pub fn read(d: *Client) !void {
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

            fn bind(
                c: *Client,
                interface: []const u8,
                version: u32,
                new_id: *u32,
                ptr: *anyopaque,
                event_handler: ?EventHandler,
                remove: ?*const fn (*anyopaque) void,
            ) !void {
                // find global
                var git = c.globals.iterator();
                const global: *Global = while (git.next()) |entry| {
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

                var int_len: u32 = @intCast(interface.len + 1);
                if (int_len & 0b11 != 0) {
                    int_len += 4;
                }
                int_len >>= 2;
                const msg_size: u32 = 6 + int_len;
                const msg: []u32 = try c.allocator.alloc(u32, msg_size);
                defer c.allocator.free(msg);
                msg[0] = REGISTRY_ID;
                msg[1] = msg_size << 18 | 0;
                msg[2] = global.name;
                msg[3] = @intCast(interface.len + 1);
                msg[3 + int_len] = 0;
                std.mem.copyForwards(u8, @ptrCast(msg[4..]), interface);
                msg[4 + int_len] = vers;
                msg[5 + int_len] = new_id.*;
                try c.conn.writeAll(@ptrCast(msg));
            }
        };

        pub const Compositor = struct {
            id: u32,
            client: *Client,
            removed: bool = false,

            /// Caller is responsible for destroying the memory from the
            /// client's allocator
            pub fn init(client: *Client) !*Compositor {
                const comp = try client.allocator.create(Compositor);
                comp.* = Compositor{
                    .id = 0,
                    .client = client,
                };

                try client.bind("wl_compositor", 0, &comp.id, comp, null, &remove);

                std.log.debug("wl_compositor created with id: {}", .{comp.id});
                return comp;
            }

            pub fn deinit(comp: *Compositor) void {
                comp.client.allocator.destroy(comp);
            }

            fn remove(ptr: *anyopaque) void {
                const comp: *Compositor = @ptrCast(@alignCast(ptr));
                comp.removed = true;
            }

            /// Caller is responsible for calling destroy() to free the surface memory
            /// and binding with the server
            pub fn createSurface(comp: *Compositor) !*Surface {
                if (comp.removed) return error.ObjectRemoved;
                const surface = try Surface.create(comp.client);
                std.log.debug("wl_compositor creating wl_surface {}", .{surface.id});

                const msg: [3]u32 = .{ comp.id, 3 << 18 | 0, surface.id };
                try comp.client.conn.writeAll(@ptrCast(&msg));

                return surface;
            }
        };

        pub const Surface = struct {
            id: u32,
            client: *Client,

            pub usingnamespace BaseObject(@This(), &handleEvent);

            /// Just set x and y to 0 as version 5 and above would be a protocol violation
            pub fn attach(s: *Surface, buf: *Buffer, x: i32, y: i32) !void {
                const msg = [_]u32{ s.id, 5 << 18 | 1, buf.id, @bitCast(x), @bitCast(y) };
                try s.client.conn.writeAll(@ptrCast(&msg));
            }

            pub fn damage(s: *Surface, x: i32, y: i32, width: i32, height: i32) !void {
                const msg = [_]u32{
                    s.id,
                    6 << 18 | 2,
                    x,
                    y,
                    width,
                    height,
                };
                try s.client.conn.writeAll(@ptrCast(&msg));
            }

            pub fn commit(s: *Surface) !void {
                const msg = [_]u32{ s.id, 2 << 18 | 6 };
                try s.client.conn.writeAll(@ptrCast(&msg));
            }

            pub fn damageBuffer(s: *Surface, x: i32, y: i32, width: i32, height: i32) !void {
                const msg = [_]u32{
                    s.id,
                    6 << 18 | 9,
                    x,
                    y,
                    width,
                    height,
                };
                try s.client.conn.writeAll(@ptrCast(&msg));
            }

            fn handleEvent(s: *Surface, event: u16, data: []const u32) !void {
                _ = data;
                std.log.warn("wl_surface {} got event {} which is not yet implemented", .{ s.id, event });
            }
        };

        pub const Shm = struct {
            pub const Format = enum(u32) {
                argb8888 = 0,
                xrgb8888 = 1,
                c8 = 0x20203843,
                _,
            };
            id: u32,
            client: *Client,
            removed: bool = false,

            /// Caller must release this object to free used memory
            /// when done with it.
            pub fn create(client: *Client) !*Shm {
                const shm = try client.allocator.create(Shm);
                shm.* = Shm{
                    .id = 0,
                    .client = client,
                };
                try client.bind("wl_shm", 0, &shm.id, shm, &handleEvent, &remove);
                std.log.debug("wl_shm created and bound to id: {}", .{shm.id});
                return shm;
            }

            /// Creates a pool, TODO: update docstring
            pub fn createPool(shm: *Shm, size: u32) !*ShmPool {
                const pool = try ShmPool.create(shm.client, size);
                errdefer pool.destroy();
                if (pool.data.len != size) {
                    std.log.warn("ShmPool data len {} != size {}", .{ pool.data.len, size });
                }
                const msg: [5]u32 = .{ shm.id, 16 << 16 | 0, pool.id, size, 0 };

                // use sendmsg to send the file descriptor over...
                const iov: std.posix.iovec_const = std.posix.iovec_const{
                    .base = @ptrCast(&msg),
                    .len = 17,
                };
                const CMSGHDR = extern struct {
                    len: usize,
                    level: c_int,
                    type: c_int,
                };
                const buflen = @sizeOf(CMSGHDR) + ((@sizeOf(std.posix.fd_t) + @sizeOf(c_long) - 1) & ~@as(usize, @sizeOf(c_long) - 1));
                var buf: [buflen]u8 align(@sizeOf(CMSGHDR)) = undefined;
                for (&buf) |*d| {
                    d.* = 0;
                }
                var control: *CMSGHDR = @ptrCast(&buf);
                control.len = buf.len;
                control.level = std.posix.SOL.SOCKET;
                control.type = 1;
                const cmsgdata: []u8 = buf[@sizeOf(CMSGHDR)..];
                std.mem.copyForwards(u8, cmsgdata, std.mem.asBytes(&pool.fd));
                const cmsg = std.os.linux.msghdr_const{
                    .name = null,
                    .namelen = 0,
                    .iov = &.{iov},
                    .iovlen = 1,
                    .control = &buf,
                    .controllen = buf.len,
                    .flags = 0,
                };
                const n = try std.posix.sendmsg(shm.client.conn.handle, &cmsg, std.posix.MSG.OOB);
                if (n != 17) {
                    std.log.err("Only sent {} bytes instead of {} bytes while creating wl_shm_pool", .{ n, msg.len });
                    return error.CouldNotSendBuffer;
                }

                std.log.debug("wl_shm: {} created pool {} with size: {}", .{ shm.id, pool.id, size });
                return pool;
            }

            fn remove(ptr: *anyopaque) void {
                const shm: *Shm = @ptrCast(@alignCast(ptr));
                shm.removed = true;
                std.log.warn("wl_shm {} removed by server", .{shm.id});
            }

            /// Destroys the shm and tells the server that the shm
            /// is no longer going to be used anymore. Objects
            /// created via this interface remain unaffected.
            pub fn release(shm: *Shm) void {
                std.log.debug("wl_shm {} release()", .{shm.id});
                const msg = [_]u32{ shm.id, 2 << 18 | 1 };
                shm.client.allocator.destroy(shm);
                shm.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
                    std.log.err("wl_shm: {} could not send release() to server: {}", .{ shm.id, err });
                };
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

        pub const ShmPool = struct {
            id: u32,
            client: *Client,
            fd: std.posix.fd_t,
            data: []align(std.heap.page_size_min) u8,

            /// Called internally from Shm.createPool
            fn create(client: *Client, size: u32) !*ShmPool {
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

                const pool = try client.allocator.create(ShmPool);
                pool.* = ShmPool{
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
                pool: *ShmPool,
                offset: u32,
                width: u32,
                height: u32,
                stride: u32,
                format: Shm.Format,
            ) !*Buffer {
                const buf = try Buffer.create(pool.client);
                errdefer buf.destroy();

                const msg = [_]u32{
                    pool.id,
                    8 << 18 | 0,
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
            pub fn destroy(pool: *ShmPool) void {
                std.posix.munmap(pool.data);
                std.posix.close(pool.fd);
                const msg = [_]u32{ pool.id, 2 << 18 | 1 };
                pool.client.allocator.destroy(pool);
                pool.client.conn.writeAll(@ptrCast(@alignCast(&msg))) catch |err| {
                    std.log.err("wl_shm_pool: unable to send destroy message to server, hope everything is okay: {}", .{err});
                };
            }

            pub fn resize(pool: *ShmPool, new_size: u32) !void {
                try std.posix.ftruncate(pool.fd, new_size);
                pool.data = try std.posix.mremap(
                    pool.data,
                    0, // will create a mapping with the same pages since it is shared
                    new_size,
                    0,
                    null,
                );
                const msg = [_]u32{ pool.id, 3 << 18 | 2, new_size };
                try pool.client.conn.writeAll(@ptrCast(&msg));
            }
        };

        pub const Buffer = struct {
            id: u32,
            client: *Client,

            pub usingnamespace BaseObject(@This(), &handleEvent);

            fn handleEvent(buf: *Buffer, event: u16, data: []const u32) !void {
                _ = data;
                if (event != 0) {
                    std.log.err("wl_buffer: {} received unknown event: {}", .{ buf.id, event });
                    return;
                }
                std.log.info("wl_buffer: {} received release() which is not implemented", .{buf.id});
            }
        };

        pub const XdgWmBase = struct {
            id: u32 = 0,
            client: *Client,
            removed: bool = false,

            pub fn init(client: *Client) !*XdgWmBase {
                const base = try client.allocator.create(XdgWmBase);
                errdefer client.allocator.destroy(base);
                base.* = .{
                    .client = client,
                };

                try client.bind(
                    "xdg_wm_base",
                    0,
                    &base.id,
                    base,
                    &handleEvent,
                    &remove,
                );

                std.log.debug("xdg_wm_base: {} init()", .{base.id});
                return base;
            }

            fn remove(ptr: *anyopaque) void {
                const base: *XdgWmBase = @ptrCast(@alignCast(ptr));
                base.removed = true;
                std.log.warn("xdg_wm_base: {} forcibly removing", .{base.id});
            }

            pub fn destroy(base: *XdgWmBase) void {
                std.log.debug("xdg_wm_base: {} destroy()", .{base.id});
                const msg = [_]u32{ base.id, 2 << 18 | 0 };
                base.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
                    std.log.err("xdg_wm_base: {} unable to send destroy: {}", .{ base.id, err });
                };
                base.client.allocator.destroy(base);
            }

            pub fn getXdgSurface(base: *XdgWmBase, surface: *Surface) !*XdgSurface {
                if (base.removed) return error.ObjectRemoved;
                const s = try XdgSurface.create(base.client);
                errdefer s.destroy();

                const msg = [_]u32{ base.id, 4 << 18 | 2, s.id, surface.id };
                try base.client.conn.writeAll(@ptrCast(&msg));

                return s;
            }

            fn pong(base: *XdgWmBase, serial: u32) !void {
                const msg = [_]u32{ base.id, 3 << 18 | 3, serial };
                try base.client.conn.writeAll(@ptrCast(&msg));
            }

            fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
                const base: *XdgWmBase = @ptrCast(@alignCast(ptr));
                if (event != 0) {
                    std.log.err("xdg_wm_base: {} received unknown event {}", .{ base.id, event });
                    return;
                }
                // Ping event received, lets pong back
                const serial = data[0];
                std.log.debug("xdg_wm_base: {} received ping: {}, ponging", .{ base.id, serial });
                try base.pong(serial);
            }
        };

        pub const XdgSurface = struct {
            id: u32,
            client: *Client,
            configureHandler: ?*const fn (*A) anyerror!void = null,
            configurePtr: ?*anyopaque = null,

            pub usingnamespace BaseObject(@This(), &handleEvent);

            pub fn getToplevel(s: *XdgSurface) !*XdgToplevel {
                const tl = try XdgToplevel.create(s.client);
                errdefer tl.destroy();

                const msg = [_]u32{ s.id, 3 << 18 | 1, tl.id };
                try s.client.conn.writeAll(@ptrCast(&msg));

                return tl;
            }

            fn ackConfigure(s: *XdgSurface, serial: u32) !void {
                const msg = [_]u32{ s.id, 3 << 18 | 4, serial };
                try s.client.conn.writeAll(@ptrCast(&msg));
            }

            fn handleEvent(s: *XdgSurface, event: u16, data: []const u32) !void {
                if (event != 0) {
                    std.log.err(
                        "xdg_surface: {} received unknown event: {}",
                        .{ s.id, event },
                    );
                    return;
                }
                const serial = data[0];
                std.log.warn(
                    "xdg_surface: {} received configure {}, probably should do something...",
                    .{ s.id, serial },
                );
                try s.ackConfigure(serial);
                if (s.configureHandler) |handle| {
                    try handle(s.client.app);
                }
            }
        };

        pub const XdgToplevel = struct {
            id: u32,
            client: *Client,
            closeHandler: ?*const fn (ptr: *A) void = null,

            pub usingnamespace BaseObject(@This(), &handleEvent);

            pub fn setTitle(tl: *XdgToplevel, new_title: []const u8) !void {
                var ntl: u32 = @intCast(new_title.len + 1);
                if (ntl & 0b11 != 0) {
                    ntl += 4;
                }
                ntl >>= 2;
                const msg = try tl.client.allocator.alloc(u32, 3 + ntl);
                defer tl.client.allocator.free(msg);
                msg[0] = tl.id;
                msg[1] = @intCast(msg.len << 18 | 2);
                msg[2] = @intCast(new_title.len + 1);
                msg[2 + ntl] = 0;
                std.mem.copyForwards(u8, @ptrCast(msg[3..]), new_title);
                try tl.client.conn.writeAll(@ptrCast(msg));
            }

            pub fn setMaxSize(tl: *XdgToplevel, width: i32, height: i32) !void {
                const msg = [_]u32{ tl.id, 4 << 18 | 7, @bitCast(width), @bitCast(height) };
                try tl.client.conn.writeAll(@ptrCast(&msg));
            }

            pub fn setMinSize(tl: *XdgToplevel, width: i32, height: i32) !void {
                const msg = [_]u32{ tl.id, 4 << 18 | 8, @bitCast(width), @bitCast(height) };
                try tl.client.conn.writeAll(@ptrCast(&msg));
            }

            fn handleEvent(tl: *XdgToplevel, event: u16, data: []const u32) !void {
                // TODO: implement
                _ = data;
                const ev = switch (event) {
                    0 => "configure",
                    1 => {
                        if (tl.closeHandler) |ch| {
                            ch(tl.client.app);
                        } else {
                            std.log.warn("xdg_toplevel: {} received close event that isn't handled", .{tl.id});
                        }
                        return;
                    },
                    2 => "configure_bounds",
                    3 => "wm_capabilities",
                    else => "unknown",
                };
                std.log.warn("xdg_toplevel: {} received {s} event", .{ tl.id, ev });
            }
        };

        pub const XdgDecorationManager = struct {
            id: u32,
            client: *Client,
            removed: bool,

            pub fn create(client: *Client) !*XdgDecorationManager {
                const dm = try client.allocator.create(XdgDecorationManager);
                errdefer client.allocator.destroy(dm);
                dm.* = .{
                    .id = 0,
                    .client = client,
                    .removed = false,
                };

                try client.bind("zxdg_decoration_manager_v1", 1, &dm.id, dm, null, &remove);
                return dm;
            }

            pub fn destroy(dm: *@This()) void {
                const msg = [_]u32{ dm.id, 2 << 18 };
                dm.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
                    std.log.err("xdg_decoration_manager {} unable to send destroy {}", .{ dm.id, err });
                };
                dm.client.allocator.destroy(dm);
            }

            pub fn getToplevelDecoration(dm: *@This(), tl: *XdgToplevel) !*XdgToplevedDecoration {
                const tld = try XdgToplevedDecoration.create(dm.client);
                errdefer tld.destroy();
                const msg = [_]u32{ dm.id, 4 << 18 | 1, tld.id, tl.id };
                try dm.client.conn.writeAll(@ptrCast(&msg));
                return tld;
            }

            fn remove(ptr: *anyopaque) void {
                const dm: *@This() = @ptrCast(@alignCast(ptr));
                dm.removed = true;
            }
        };

        pub const XdgToplevedDecoration = struct {
            const Mode = enum(u32) {
                client_side = 1,
                server_side = 2,
            };
            id: u32,
            client: *Client,

            pub usingnamespace BaseObject(@This(), &handleEvent);

            pub fn setMode(tld: *@This(), mode: Mode) !void {
                const msg = [_]u32{ tld.id, 3 << 18 | 1, @intFromEnum(mode) };
                try tld.client.conn.writeAll(@ptrCast(&msg));
            }

            pub fn unsetMode(tld: *@This()) !void {
                const msg = [_]u32{ tld.id, 2 << 18 | 2 };
                try tld.client.conn.writeAll(@ptrCast(&msg));
            }

            fn handleEvent(dm: *@This(), event: u16, data: []const u32) !void {
                if (event != 0) {
                    std.log.err("xdg_toplevel_decoration {} got unsupported event {}", .{ dm.id, event });
                    return;
                }
                const mode: Mode = @enumFromInt(data[0]);
                std.log.info("xdg_toplevel_decoration {} got mode {}", .{ dm.id, mode });
            }
        };

        fn BaseObject(T: type, event_handler: ?*const fn (*T, u16, []const u32) anyerror!void) type {
            return struct {
                fn create(client: *Client) !*T {
                    const self = try client.allocator.create(T);
                    errdefer client.allocator.destroy(self);
                    self.* = .{
                        .id = 0,
                        .client = client,
                    };

                    try client.newId(&self.id, self, @ptrCast(event_handler));
                    return self;
                }

                pub fn destroy(self: *T) void {
                    const msg = [_]u32{ self.id, 2 << 18 };
                    self.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
                        std.log.err(@typeName(T) ++ " {} could not send destroy: {}", .{ self.id, err });
                    };
                    self.client.allocator.destroy(self);
                }
            };
        }
    };
}
