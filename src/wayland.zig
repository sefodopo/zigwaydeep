const std = @import("std");

const Allocator = std.mem.Allocator;
const Stream = std.net.Stream;
const Writer = std.io.Writer;

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

pub fn sendMsg(conn: Stream, id: u32, opcode: comptime_int, args: anytype) !void {
    var buf: [2048]u8 align(4) = undefined;
    const buf32: []u32 = @ptrCast(&buf);
    var stream = std.io.fixedBufferStream(&buf);
    stream.seekTo(8) catch unreachable;
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct" or !args_type_info.@"struct".is_tuple) {
        @compileError("expected tuple, found " ++ @typeName(ArgsType));
    }

    const fields_info = args_type_info.@"struct".fields;

    inline for (fields_info) |fi| {
        switch (@typeInfo(fi.type)) {
            .comptime_int, .int => _ = try stream.write(std.mem.asBytes(&@as(u32, @field(args, fi.name)))),
            .array, .pointer => {
                const field = @field(args, fi.name);
                _ = try stream.write(std.mem.asBytes(&@as(u32, @intCast(field.len + 1))));
                var n = try stream.write(field);
                n += try stream.write(&.{0});
                while (n % 4 != 0) {
                    n += try stream.write(&.{0});
                }
            },
            else => {
                @compileError("Invalid type for arg " ++ @typeName(fi.type));
            },
        }
    }

    const len = stream.getPos() catch unreachable;
    buf32[0] = id;
    buf32[1] = @intCast(len << 16 | opcode);
    try conn.writeAll(stream.getWritten());
}

var next_id: u32 = 2;

inline fn Dispatcher(T: type, W: type, handler: fn (T, W.Event) anyerror!void) *const fn (*anyopaque, u32, []const u32) anyerror!void {
    const _Dispatcher = struct {
        fn dispatcher(ptr: *anyopaque, event: u32, data: []const u32) !void {
            const e = try W.Event.parse(event, data);
            try handler(@ptrCast(@alignCast(ptr)), e);
        }
    };
    return _Dispatcher.dispatcher;
}

pub const Decoder = struct {
    const Handler = struct {
        dispatcher: *const fn (*anyopaque, u32, []const u32) anyerror!void,
        data: *anyopaque,
    };
    handlers: std.AutoArrayHashMap(u32, Handler),
    pub fn init(allocator: Allocator) Decoder {
        const handlers = std.AutoArrayHashMap(u32, Handler).init(allocator);
        return .{
            .handlers = handlers,
        };
    }

    pub fn deinit(dec: *Decoder) void {
        dec.handlers.deinit();
    }

    fn addHandler(
        dec: *Decoder,
        id: u32,
        dispatcher: *const fn (*anyopaque, u32, []const u32) anyerror!void,
        data: *anyopaque,
    ) !void {
        try dec.handlers.put(id, .{ .dispatcher = dispatcher, .data = data });
    }
};

pub const Display = struct {
    pub const Event = union(enum) {
        err: struct {
            object_id: u32,
            code: enum(u32) {
                invalid_object,
                invalid_method,
                no_memory,
                implementation,
                _,
            },
            message: []const u8,
        },
        delete_id: u32,
        fn parse(event: u32, data: []const u32) !Event {
            return switch (event) {
                0 => .{ .err = .{
                    .object_id = data[0],
                    .code = @enumFromInt(data[1]),
                    .message = @as([]const u8, @ptrCast(data[3..]))[0 .. data[2] - 1],
                } },
                1 => .{ .delete_id = data[0] },
                else => unreachable,
            };
        }
    };
    const id: u32 = 1;
    conn: Stream,

    pub fn setHandler(
        disp: Display,
        decoder: *Decoder,
        ptr: anytype,
        handler: fn (@TypeOf(ptr), Event) anyerror!void,
    ) !void {
        _ = disp;
        try decoder.addHandler(id, Dispatcher(@TypeOf(ptr), @This(), handler), ptr);
    }

    /// The allocator is only used temporarily and freed up before
    /// return
    pub fn connect(allocator: std.mem.Allocator) !Display {
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

        return .{
            .conn = conn,
        };
    }

    pub fn close(disp: Display) void {
        disp.conn.close();
    }

    pub fn sync(disp: Display) !Callback {
        const cb = Callback{
            .id = next_id,
        };
        next_id += 1;
        try sendMsg(disp.conn, id, 0, .{cb.id});
        return cb;
    }

    pub fn getRegistry(disp: Display) !Registry {
        try sendMsg(disp.conn, id, 1, .{next_id});
        next_id += 1;
        return .{
            .id = next_id - 1,
            .conn = disp.conn,
        };
    }
};

pub const Callback = struct {
    id: u32,
    done: bool = false,
    fn handleEvent(cb: *Callback, event: u32, data: []const u32) !void {
        _ = event;
        _ = data;
        cb.done = true;
    }
};

pub const Registry = struct {
    pub const Event = union(enum) {
        global: struct {
            name: u32,
            interface: []const u8,
            version: u32,
        },
        global_remove: u32,
        fn parse(event: u32, data: []const u32) !Event {
            return switch (event) {
                0 => .{ .global = .{
                    .name = data[0],
                    .interface = @as([]const u8, @ptrCast(data[2..]))[0 .. data[1] - 1],
                    .version = data[data.len - 1],
                } },
                1 => .{ .global_remove = data[0] },
            };
        }
    };
    id: u32,
    conn: Stream,

    pub fn bind(reg: Registry, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
        try sendMsg(reg.conn, reg.id, 0, .{ name, interface, version, new_id });
    }
};

// pub const Compositor = struct {
//     id: u32,
//
//     /// Caller is responsible for destroying the memory from the
//     /// client's allocator
//     pub fn init(client: *Client) !Compositor {
//         const comp = try client.allocator.create(Compositor);
//         comp.* = Compositor{
//             .id = 0,
//             .client = client,
//         };
//
//         try client.bind("wl_compositor", 0, &comp.id, comp, null, &remove);
//
//         std.log.debug("wl_compositor created with id: {}", .{comp.id});
//         return comp;
//     }
//
//     pub fn deinit(comp: *Compositor) void {
//         comp.client.allocator.destroy(comp);
//     }
//
//     fn remove(ptr: *anyopaque) void {
//         const comp: *Compositor = @ptrCast(@alignCast(ptr));
//         comp.removed = true;
//     }
//
//     /// Caller is responsible for calling destroy() to free the surface memory
//     /// and binding with the server
//     pub fn createSurface(comp: *Compositor) !*Surface {
//         if (comp.removed) return error.ObjectRemoved;
//         const surface = try Surface.create(comp.client);
//         std.log.debug("wl_compositor creating wl_surface {}", .{surface.base.id});
//
//         const msg: [3]u32 = .{ comp.id, 3 << 18 | 0, surface.base.id };
//         try comp.client.conn.writeAll(@ptrCast(&msg));
//
//         return surface;
//     }
// };
//
// pub const Surface = struct {
//     base: BaseObject(@This()),
//     pub usingnamespace BaseObject(@This());
//
//     /// Just set x and y to 0 as version 5 and above would be a protocol violation
//     pub fn attach(s: *Surface, buf: *Buffer, x: i32, y: i32) !void {
//         const msg = [_]u32{ s.base.id, 5 << 18 | 1, buf.base.id, @bitCast(x), @bitCast(y) };
//         try s.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     pub fn damage(s: *Surface, x: i32, y: i32, width: i32, height: i32) !void {
//         const msg = [_]u32{
//             s.id,
//             6 << 18 | 2,
//             x,
//             y,
//             width,
//             height,
//         };
//         try s.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     pub fn commit(s: *Surface) !void {
//         const msg = [_]u32{ s.base.id, 2 << 18 | 6 };
//         try s.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     pub fn damageBuffer(s: *Surface, x: i32, y: i32, width: i32, height: i32) !void {
//         const msg = [_]u32{
//             s.id,
//             6 << 18 | 9,
//             x,
//             y,
//             width,
//             height,
//         };
//         try s.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     fn handleEvent(s: *Surface, event: u16, data: []const u32) !void {
//         _ = data;
//         std.log.warn("wl_surface {} got event {} which is not yet implemented", .{ s.base.id, event });
//     }
// };
//
// pub const Shm = struct {
//     pub const Format = enum(u32) {
//         argb8888 = 0,
//         xrgb8888 = 1,
//         c8 = 0x20203843,
//         _,
//     };
//     id: u32,
//     client: *Client,
//     removed: bool = false,
//
//     /// Caller must release this object to free used memory
//     /// when done with it.
//     pub fn create(client: *Client) !*Shm {
//         const shm = try client.allocator.create(Shm);
//         shm.* = Shm{
//             .id = 0,
//             .client = client,
//         };
//         try client.bind("wl_shm", 0, &shm.id, shm, &handleEvent, &remove);
//         std.log.debug("wl_shm created and bound to id: {}", .{shm.id});
//         return shm;
//     }
//
//     /// Creates a pool, TODO: update docstring
//     pub fn createPool(shm: *Shm, size: u32) !*ShmPool {
//         const pool = try ShmPool.create(shm.client, size);
//         errdefer pool.destroy();
//         if (pool.data.len != size) {
//             std.log.warn("ShmPool data len {} != size {}", .{ pool.data.len, size });
//         }
//         const msg: [5]u32 = .{ shm.id, 16 << 16 | 0, pool.id, size, 0 };
//
//         // use sendmsg to send the file descriptor over...
//         const iov: std.posix.iovec_const = std.posix.iovec_const{
//             .base = @ptrCast(&msg),
//             .len = 17,
//         };
//         const CMSGHDR = extern struct {
//             len: usize,
//             level: c_int,
//             type: c_int,
//         };
//         const buflen = @sizeOf(CMSGHDR) + ((@sizeOf(std.posix.fd_t) + @sizeOf(c_long) - 1) & ~@as(usize, @sizeOf(c_long) - 1));
//         var buf: [buflen]u8 align(@sizeOf(CMSGHDR)) = undefined;
//         for (&buf) |*d| {
//             d.* = 0;
//         }
//         var control: *CMSGHDR = @ptrCast(&buf);
//         control.len = buf.len;
//         control.level = std.posix.SOL.SOCKET;
//         control.type = 1;
//         const cmsgdata: []u8 = buf[@sizeOf(CMSGHDR)..];
//         std.mem.copyForwards(u8, cmsgdata, std.mem.asBytes(&pool.fd));
//         const cmsg = std.os.linux.msghdr_const{
//             .name = null,
//             .namelen = 0,
//             .iov = &.{iov},
//             .iovlen = 1,
//             .control = &buf,
//             .controllen = buf.len,
//             .flags = 0,
//         };
//         const n = try std.posix.sendmsg(shm.client.conn.handle, &cmsg, std.posix.MSG.OOB);
//         if (n != 17) {
//             std.log.err("Only sent {} bytes instead of {} bytes while creating wl_shm_pool", .{ n, msg.len });
//             return error.CouldNotSendBuffer;
//         }
//
//         std.log.debug("wl_shm: {} created pool {} with size: {}", .{ shm.id, pool.id, size });
//         return pool;
//     }
//
//     fn remove(ptr: *anyopaque) void {
//         const shm: *Shm = @ptrCast(@alignCast(ptr));
//         shm.removed = true;
//         std.log.warn("wl_shm {} removed by server", .{shm.id});
//     }
//
//     /// Destroys the shm and tells the server that the shm
//     /// is no longer going to be used anymore. Objects
//     /// created via this interface remain unaffected.
//     pub fn release(shm: *Shm) void {
//         std.log.debug("wl_shm {} release()", .{shm.id});
//         const msg = [_]u32{ shm.id, 2 << 18 | 1 };
//         shm.client.allocator.destroy(shm);
//         shm.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
//             std.log.err("wl_shm: {} could not send release() to server: {}", .{ shm.id, err });
//         };
//     }
//
//     fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
//         _ = ptr;
//         if (event != 0) {
//             std.log.err("wl_shm got unknown event: {}", .{event});
//             return;
//         }
//         const format: Format = @enumFromInt(data[0]);
//         std.log.info("wl_shm: format supported: {}", .{format});
//     }
// };
//
// pub const ShmPool = struct {
//     id: u32,
//     client: *Client,
//     fd: std.posix.fd_t,
//     data: []align(std.heap.page_size_min) u8,
//
//     /// Called internally from Shm.createPool
//     fn create(client: *Client, size: u32) !*ShmPool {
//         // try to allocate and mmap shared memory
//         const fd = try std.posix.memfd_create("wl_shm_pool", 0);
//         errdefer std.posix.close(fd);
//         try std.posix.ftruncate(fd, size);
//
//         const data = try std.posix.mmap(
//             null,
//             @intCast(size),
//             std.posix.PROT.READ | std.posix.PROT.WRITE,
//             .{ .TYPE = .SHARED },
//             fd,
//             0,
//         );
//         errdefer std.posix.munmap(data);
//
//         const pool = try client.allocator.create(ShmPool);
//         pool.* = ShmPool{
//             .id = 0,
//             .client = client,
//             .fd = fd,
//             .data = data,
//         };
//         errdefer client.allocator.destroy(pool);
//
//         try pool.client.newId(&pool.id, pool, null);
//         return pool;
//     }
//
//     /// Caller owns the buffer which must be destroy()ed.
//     pub fn createBuffer(
//         pool: *ShmPool,
//         offset: u32,
//         width: u32,
//         height: u32,
//         stride: u32,
//         format: Shm.Format,
//     ) !*Buffer {
//         const buf = try Buffer.create(pool.client);
//         errdefer buf.destroy();
//
//         const msg = [_]u32{
//             pool.id,
//             8 << 18 | 0,
//             buf.base.id,
//             offset,
//             width,
//             height,
//             stride,
//             @intFromEnum(format),
//         };
//         try pool.client.conn.writeAll(@ptrCast(&msg));
//
//         return buf;
//     }
//
//     /// Destroys and frees up the memory
//     pub fn destroy(pool: *ShmPool) void {
//         std.posix.munmap(pool.data);
//         std.posix.close(pool.fd);
//         const msg = [_]u32{ pool.id, 2 << 18 | 1 };
//         pool.client.allocator.destroy(pool);
//         pool.client.conn.writeAll(@ptrCast(@alignCast(&msg))) catch |err| {
//             std.log.err("wl_shm_pool: unable to send destroy message to server, hope everything is okay: {}", .{err});
//         };
//     }
//
//     pub fn resize(pool: *ShmPool, new_size: u32) !void {
//         try std.posix.ftruncate(pool.fd, new_size);
//         pool.data = try std.posix.mremap(
//             pool.data,
//             0, // will create a mapping with the same pages since it is shared
//             new_size,
//             0,
//             null,
//         );
//         const msg = [_]u32{ pool.id, 3 << 18 | 2, new_size };
//         try pool.client.conn.writeAll(@ptrCast(&msg));
//     }
// };
//
// pub const Buffer = struct {
//     base: BaseObject(@This()),
//     pub usingnamespace BaseObject(@This());
//
//     fn handleEvent(buf: *Buffer, event: u16, data: []const u32) !void {
//         _ = data;
//         if (event != 0) {
//             std.log.err("wl_buffer: {} received unknown event: {}", .{ buf.base.id, event });
//             return;
//         }
//         std.log.info("wl_buffer: {} received release() which is not implemented", .{buf.base.id});
//     }
// };
//
// pub const XdgWmBase = struct {
//     id: u32 = 0,
//     client: *Client,
//     removed: bool = false,
//
//     pub fn init(client: *Client) !*XdgWmBase {
//         const base = try client.allocator.create(XdgWmBase);
//         errdefer client.allocator.destroy(base);
//         base.* = .{
//             .client = client,
//         };
//
//         try client.bind(
//             "xdg_wm_base",
//             0,
//             &base.id,
//             base,
//             &handleEvent,
//             &remove,
//         );
//
//         std.log.debug("xdg_wm_base: {} init()", .{base.id});
//         return base;
//     }
//
//     fn remove(ptr: *anyopaque) void {
//         const base: *XdgWmBase = @ptrCast(@alignCast(ptr));
//         base.removed = true;
//         std.log.warn("xdg_wm_base: {} forcibly removing", .{base.id});
//     }
//
//     pub fn destroy(base: *XdgWmBase) void {
//         std.log.debug("xdg_wm_base: {} destroy()", .{base.id});
//         const msg = [_]u32{ base.id, 2 << 18 | 0 };
//         base.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
//             std.log.err("xdg_wm_base: {} unable to send destroy: {}", .{ base.id, err });
//         };
//         base.client.allocator.destroy(base);
//     }
//
//     pub fn getXdgSurface(base: *XdgWmBase, surface: *Surface) !*XdgSurface {
//         if (base.removed) return error.ObjectRemoved;
//         const s = try XdgSurface.create(base.client);
//         errdefer s.destroy();
//
//         const msg = [_]u32{ base.id, 4 << 18 | 2, s.base.id, surface.base.id };
//         try base.client.conn.writeAll(@ptrCast(&msg));
//
//         return s;
//     }
//
//     fn pong(base: *XdgWmBase, serial: u32) !void {
//         const msg = [_]u32{ base.id, 3 << 18 | 3, serial };
//         try base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     fn handleEvent(ptr: *anyopaque, event: u16, data: []const u32) !void {
//         const base: *XdgWmBase = @ptrCast(@alignCast(ptr));
//         if (event != 0) {
//             std.log.err("xdg_wm_base: {} received unknown event {}", .{ base.id, event });
//             return;
//         }
//         // Ping event received, lets pong back
//         const serial = data[0];
//         std.log.debug("xdg_wm_base: {} received ping: {}, ponging", .{ base.id, serial });
//         try base.pong(serial);
//     }
// };
//
// pub const XdgSurface = struct {
//     configureHandler: ?*const fn (*A) anyerror!void = null,
//     configurePtr: ?*anyopaque = null,
//
//     base: BaseObject(@This()),
//     pub usingnamespace BaseObject(@This());
//
//     pub fn getToplevel(s: *XdgSurface) !*XdgToplevel {
//         const tl = try XdgToplevel.create(s.base.client);
//         errdefer tl.destroy();
//
//         const msg = [_]u32{ s.base.id, 3 << 18 | 1, tl.base.id };
//         try s.base.client.conn.writeAll(@ptrCast(&msg));
//
//         return tl;
//     }
//
//     fn ackConfigure(s: *XdgSurface, serial: u32) !void {
//         const msg = [_]u32{ s.base.id, 3 << 18 | 4, serial };
//         try s.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     fn handleEvent(s: *XdgSurface, event: u16, data: []const u32) !void {
//         if (event != 0) {
//             std.log.err(
//                 "xdg_surface: {} received unknown event: {}",
//                 .{ s.base.id, event },
//             );
//             return;
//         }
//         const serial = data[0];
//         std.log.warn(
//             "xdg_surface: {} received configure {}, probably should do something...",
//             .{ s.base.id, serial },
//         );
//         try s.ackConfigure(serial);
//         if (s.configureHandler) |handle| {
//             try handle(s.base.client.app);
//         }
//     }
// };
//
// pub const XdgToplevel = struct {
//     closeHandler: ?*const fn (ptr: *A) void = null,
//
//     base: BaseObject(@This()),
//     pub usingnamespace BaseObject(@This());
//
//     pub fn setTitle(tl: *XdgToplevel, new_title: []const u8) !void {
//         var ntl: u32 = @intCast(new_title.len + 1);
//         if (ntl & 0b11 != 0) {
//             ntl += 4;
//         }
//         ntl >>= 2;
//         const msg = try tl.base.client.allocator.alloc(u32, 3 + ntl);
//         defer tl.base.client.allocator.free(msg);
//         msg[0] = tl.base.id;
//         msg[1] = @intCast(msg.len << 18 | 2);
//         msg[2] = @intCast(new_title.len + 1);
//         msg[2 + ntl] = 0;
//         std.mem.copyForwards(u8, @ptrCast(msg[3..]), new_title);
//         try tl.base.client.conn.writeAll(@ptrCast(msg));
//     }
//
//     pub fn setMaxSize(tl: *XdgToplevel, width: i32, height: i32) !void {
//         const msg = [_]u32{ tl.base.id, 4 << 18 | 7, @bitCast(width), @bitCast(height) };
//         try tl.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     pub fn setMinSize(tl: *XdgToplevel, width: i32, height: i32) !void {
//         const msg = [_]u32{ tl.base.id, 4 << 18 | 8, @bitCast(width), @bitCast(height) };
//         try tl.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     fn handleEvent(tl: *XdgToplevel, event: u16, data: []const u32) !void {
//         // TODO: implement
//         _ = data;
//         const ev = switch (event) {
//             0 => "configure",
//             1 => {
//                 if (tl.closeHandler) |ch| {
//                     ch(tl.base.client.app);
//                 } else {
//                     std.log.warn("xdg_toplevel: {} received close event that isn't handled", .{tl.base.id});
//                 }
//                 return;
//             },
//             2 => "configure_bounds",
//             3 => "wm_capabilities",
//             else => "unknown",
//         };
//         std.log.warn("xdg_toplevel: {} received {s} event", .{ tl.base.id, ev });
//     }
// };
//
// pub const XdgDecorationManager = struct {
//     id: u32,
//     client: *Client,
//     removed: bool,
//
//     pub fn create(client: *Client) !*XdgDecorationManager {
//         const dm = try client.allocator.create(XdgDecorationManager);
//         errdefer client.allocator.destroy(dm);
//         dm.* = .{
//             .id = 0,
//             .client = client,
//             .removed = false,
//         };
//
//         try client.bind("zxdg_decoration_manager_v1", 1, &dm.id, dm, null, &remove);
//         return dm;
//     }
//
//     pub fn destroy(dm: *@This()) void {
//         const msg = [_]u32{ dm.id, 2 << 18 };
//         dm.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
//             std.log.err("xdg_decoration_manager {} unable to send destroy {}", .{ dm.id, err });
//         };
//         dm.client.allocator.destroy(dm);
//     }
//
//     pub fn getToplevelDecoration(dm: *@This(), tl: *XdgToplevel) !*XdgToplevelDecoration {
//         const tld = try XdgToplevelDecoration.create(dm.client);
//         errdefer tld.destroy();
//         const msg = [_]u32{ dm.id, 4 << 18 | 1, tld.base.id, tl.base.id };
//         try dm.client.conn.writeAll(@ptrCast(&msg));
//         return tld;
//     }
//
//     fn remove(ptr: *anyopaque) void {
//         const dm: *@This() = @ptrCast(@alignCast(ptr));
//         dm.removed = true;
//     }
// };
//
// pub const XdgToplevelDecoration = struct {
//     const Mode = enum(u32) {
//         client_side = 1,
//         server_side = 2,
//     };
//     base: BaseObject(@This()),
//     pub usingnamespace BaseObject(@This());
//
//     pub fn setMode(tld: *@This(), mode: Mode) !void {
//         const msg = [_]u32{ tld.base.id, 3 << 18 | 1, @intFromEnum(mode) };
//         try tld.base.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     pub fn unsetMode(tld: *@This()) !void {
//         const msg = [_]u32{ tld.id, 2 << 18 | 2 };
//         try tld.client.conn.writeAll(@ptrCast(&msg));
//     }
//
//     fn handleEvent(dm: *@This(), event: u16, data: []const u32) !void {
//         if (event != 0) {
//             std.log.err("xdg_toplevel_decoration {} got unsupported event {}", .{ dm.base.id, event });
//             return;
//         }
//         const mode: Mode = @enumFromInt(data[0]);
//         std.log.info("xdg_toplevel_decoration {} got mode {}", .{ dm.base.id, mode });
//     }
// };
//
// fn BaseObject(T: type) type {
//     return struct {
//         id: u32,
//         client: *Client,
//
//         fn create(client: *Client) !*T {
//             const self = try client.allocator.create(T);
//             errdefer client.allocator.destroy(self);
//             self.* = .{
//                 .base = .{
//                     .id = 0,
//                     .client = client,
//                 },
//             };
//
//             try client.newId(&self.base.id, self, if (@hasDecl(T, "handleEvent")) @ptrCast(&T.handleEvent) else null);
//             return self;
//         }
//
//         pub fn destroy(self: *T) void {
//             const msg = [_]u32{ self.base.id, 2 << 18 };
//             self.base.client.conn.writeAll(@ptrCast(&msg)) catch |err| {
//                 std.log.err(@typeName(T) ++ " {} could not send destroy: {}", .{ self.base.id, err });
//             };
//             self.base.client.allocator.destroy(self);
//         }
//     };
// }
