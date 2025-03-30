const std = @import("std");

const Allocator = std.mem.Allocator;
const Stream = std.net.Stream;

fn lessThan(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

var next_id: u32 = 2;

inline fn Dispatcher(
    T: type,
    W: type,
    handler: fn (*W, T, W.Event) anyerror!void,
) *const fn (*anyopaque, *anyopaque, u32, []const u32) anyerror!void {
    const _Dispatcher = struct {
        fn dispatcher(
            object_ptr: *anyopaque,
            ptr: *anyopaque,
            event: u32,
            data: []const u32,
        ) !void {
            if (W.Event == void) {
                try handler(@ptrCast(@alignCast(object_ptr)), @ptrCast(@alignCast(ptr)), {});
                return;
            }
            if (W.Event == u32) {
                try handler(@ptrCast(@alignCast(object_ptr)), @ptrCast(@alignCast(ptr)), data[0]);
                return;
            }
            const e = try W.Event.parse(event, data);
            try handler(@ptrCast(@alignCast(object_ptr)), @ptrCast(@alignCast(ptr)), e);
        }
    };
    return _Dispatcher.dispatcher;
}

fn setHandlerNamespace(T: type) type {
    return struct {
        pub fn setHandler(
            self: *const T,
            data: anytype,
            handler: fn (*T, @TypeOf(data), T.Event) anyerror!void,
        ) !void {
            try self.display.addHandler(
                self,
                Dispatcher(@TypeOf(data), T, handler),
                @ptrCast(@constCast(data)),
            );
        }
    };
}

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
    const Handler = struct {
        dispatcher: *const fn (*anyopaque, *anyopaque, u32, []const u32) anyerror!void,
        object: *anyopaque,
        data: *anyopaque,
    };
    const ID: u32 = 1;
    id: u32 = 1,
    conn: Stream,
    handlers: std.AutoArrayHashMap(u32, Handler),

    pub fn setHandler(
        disp: *Display,
        ptr: anytype,
        handler: fn (*Display, @TypeOf(ptr), Event) anyerror!void,
    ) !void {
        try disp.addHandler(disp, Dispatcher(@TypeOf(ptr), @This(), handler), ptr);
    }

    /// The allocator is only used temporarily and freed up before
    /// return
    pub fn init(allocator: std.mem.Allocator) !Display {
        // Open the socket
        const conn = blk: {
            const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
            const wayland = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
            const path = if (wayland[0] == '/')
                wayland
            else
                try std.fs.path.join(allocator, &.{ dir, wayland });
            defer if (wayland[0] != '/') allocator.free(path);
            std.log.debug("Opening connection to {s}", .{path});
            const conn = try std.net.connectUnixSocket(path);
            break :blk conn;
        };

        const handlers = std.AutoArrayHashMap(u32, Handler).init(allocator);

        return .{
            .conn = conn,
            .handlers = handlers,
        };
    }

    pub fn deinit(disp: *Display) void {
        disp.conn.close();
        disp.handlers.deinit();
    }
    pub fn read(disp: *Display) !void {
        var header: [2]u32 = undefined;
        if (try disp.conn.readAll(@ptrCast(&header)) != 8) {
            return error.ReadHeader;
        }

        const len = header[1] >> 18;
        if (len == 2) {
            if (disp.handlers.get(header[0])) |handler| {
                try handler.dispatcher(handler.object, handler.data, header[1] & 0xffff, &.{});
            }
            return;
        }

        const data = try disp.handlers.allocator.alloc(u32, len - 2);
        defer disp.handlers.allocator.free(data);

        if (try disp.conn.readAll(@ptrCast(data)) != (len - 2) << 2) {
            return error.ReadData;
        }

        if (disp.handlers.get(header[0])) |handler| {
            try handler.dispatcher(handler.object, handler.data, header[1] & 0xffff, data);
        }
    }

    pub fn sync(disp: *Display) !Callback {
        const cb = Callback{
            .id = next_id,
            .display = disp,
        };
        next_id += 1;
        try disp.sendMsg(ID, 0, .{cb.id});
        return cb;
    }

    pub fn getRegistry(disp: *Display) !Registry {
        try disp.sendMsg(ID, 1, .{next_id});
        next_id += 1;
        return .{
            .id = next_id - 1,
            .display = disp,
        };
    }

    fn sendMsg(disp: *Display, id: u32, opcode: comptime_int, args: anytype) !void {
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
                .comptime_int, .int => _ =
                    try stream.write(std.mem.asBytes(&@as(u32, @bitCast(@field(args, fi.name))))),
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
        try disp.conn.writeAll(stream.getWritten());
    }

    fn addHandler(
        disp: *Display,
        object: anytype,
        dispatcher: *const fn (*anyopaque, *anyopaque, u32, []const u32) anyerror!void,
        data: *anyopaque,
    ) !void {
        try disp.handlers.put(object.id, .{
            .dispatcher = dispatcher,
            .object = @ptrCast(@constCast(object)),
            .data = data,
        });
    }
};

pub const Callback = struct {
    const Event = u32;
    id: u32,
    display: *Display,
    pub usingnamespace setHandlerNamespace(@This());
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
                else => unreachable,
            };
        }
    };
    id: u32,
    display: *Display,

    pub usingnamespace setHandlerNamespace(@This());

    pub fn bind(
        reg: Registry,
        name: u32,
        interface: []const u8,
        version: u32,
        global: anytype,
    ) !void {
        try reg.display.sendMsg(reg.id, 0, .{ name, interface, version, global.id });
    }
};

pub const Compositor = struct {
    id: u32,
    display: *Display,

    /// Caller is responsible for destroying the memory from the
    /// client's allocator
    pub fn init(disp: *Display) Compositor {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .display = disp,
        };
    }

    /// Caller is responsible for calling destroy() to free the surface memory
    /// and binding with the server
    pub fn createSurface(comp: Compositor) !Surface {
        const new_id = next_id;
        next_id += 1;
        std.log.debug("wl_compositor creating wl_surface {}", .{new_id});

        try comp.display.sendMsg(comp.id, 0, .{new_id});

        return .{
            .id = new_id,
            .display = comp.display,
        };
    }
};

pub const Surface = struct {
    id: u32,
    display: *Display,

    const Event = union(enum(u32)) {
        enter: u32,
        leave: u32,
        preferred_buffer_scale: i32,
        preferred_buffer_transform: u32,
        fn parse(event: u32, data: []const u32) !Event {
            return @as(@enumFromInt(event), data[0]);
        }
    };

    pub fn destroy(s: Surface) void {
        s.display.sendMsg(s.id, 0, .{}) catch |err| std.log.err("destroy surface: {}", .{err});
    }

    /// Just set x and y to 0 as version 5 and above would be a protocol violation
    pub fn attach(s: Surface, buf: Buffer, x: i32, y: i32) !void {
        try s.display.sendMsg(s.id, 1, .{ buf.id, x, y });
    }

    pub fn damage(s: Surface, x: i32, y: i32, width: i32, height: i32) !void {
        try s.display.sendMsg(s.id, 2, .{ x, y, width, height });
    }

    pub fn frame(s: Surface) !Callback {
        const id = next_id;
        next_id += 1;
        try s.display.sendMsg(s.id, 3, .{id});
        return .{ .id = id, .display = s.display };
    }

    pub fn commit(s: Surface) !void {
        try s.display.sendMsg(s.id, 6, .{});
    }

    pub fn damageBuffer(s: Surface, x: i32, y: i32, width: i32, height: i32) !void {
        try s.display.sendMsg(s.id, 9, .{ x, y, width, height });
    }
};

pub const Shm = struct {
    id: u32,
    display: *Display,

    pub const Format = enum(u32) {
        argb8888 = 0,
        xrgb8888 = 1,
        c8 = 0x20203843,
        rgb332 = 0x38424752,
        bgr233 = 0x38524742,
        xrgb4444 = 0x32315258,
        rbgr4444 = 0x32314258,
        abgr8888 = 0x34324241,
        xbgr8888 = 0x34324258,
        _,
        fn parse(event: u32, data: []const u32) !Format {
            if (event != 0) unreachable;
            return @enumFromInt(data[0]);
        }
    };

    pub const Event = Format;
    pub usingnamespace setHandlerNamespace(@This());

    pub fn init(disp: *Display) Shm {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .display = disp,
        };
    }

    pub fn createPool(shm: Shm, size: u32) !ShmPool {
        const pool = try ShmPool.create(shm.display, size);
        if (pool.data.len != size) {
            std.log.warn("ShmPool data len {} != size {}", .{ pool.data.len, size });
        }
        const msg: [5]u32 = .{ shm.id, 16 << 16 | 0, pool.id, size, 0 };

        // use sendmsg to send the file descriptor over...
        const iov: std.posix.iovec_const = std.posix.iovec_const{
            .base = @ptrCast(&msg),
            .len = 17,
        };
        const cmsghdr = Cmsghdr(std.posix.fd_t).init(.{
            .level = std.posix.SOL.SOCKET,
            .type = 1,
            .data = pool.fd,
        });
        const cmsg = std.os.linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &.{iov},
            .iovlen = 1,
            .control = &cmsghdr.bytes,
            .controllen = cmsghdr.bytes.len,
            .flags = 0,
        };
        const n = try std.posix.sendmsg(shm.display.conn.handle, &cmsg, std.posix.MSG.OOB);
        if (n != 17) {
            std.log.err(
                "Only sent {} bytes instead of {} bytes while creating wl_shm_pool",
                .{ n, msg.len },
            );
            return error.CouldNotSendBuffer;
        }

        std.log.debug("wl_shm: {} created pool {} with size: {}", .{ shm.id, pool.id, size });
        return pool;
    }

    pub fn release(shm: Shm) void {
        std.log.debug("wl_shm {} release()", .{shm.id});
        shm.display.sendMsg(shm.id, 1, .{}) catch |err| {
            std.log.err("wl_shm: {} could not send release() to server: {}", .{ shm.id, err });
        };
    }
};

/// This definition enables the use of Zig types with a cmsghdr structure.
/// The oddity of this layout is that the data must be aligned to @sizeOf(usize)
/// rather than its natural alignment.
pub fn Cmsghdr(comptime T: type) type {
    const Header = extern struct {
        len: usize,
        level: c_int,
        type: c_int,
    };

    const data_align = @sizeOf(usize);
    const data_offset = std.mem.alignForward(usize, @sizeOf(Header), data_align);

    return extern struct {
        const Self = @This();

        bytes: [data_offset + @sizeOf(T)]u8 align(@alignOf(Header)),

        pub fn init(args: struct {
            level: c_int,
            type: c_int,
            data: T,
        }) Self {
            var self: Self = undefined;
            self.headerPtr().* = .{
                .len = data_offset + @sizeOf(T),
                .level = args.level,
                .type = args.type,
            };
            self.dataPtr().* = args.data;
            return self;
        }

        // TODO: include this version if we submit a PR to add this to std
        pub fn initNoData(args: struct {
            level: c_int,
            type: c_int,
        }) Self {
            var self: Self = undefined;
            self.headerPtr().* = .{
                .len = data_offset + @sizeOf(T),
                .level = args.level,
                .type = args.type,
            };
            return self;
        }

        pub fn headerPtr(self: *Self) *Header {
            return @as(*Header, @ptrCast(self));
        }
        pub fn dataPtr(self: *Self) *align(data_align) T {
            return @as(*align(data_align) T, @ptrCast(self.bytes[data_offset..]));
        }
    };
}

pub const ShmPool = struct {
    id: u32,
    display: *Display,
    fd: std.posix.fd_t,
    data: []align(std.heap.page_size_min) u8,

    /// Called internally from Shm.createPool
    fn create(display: *Display, size: u32) !ShmPool {
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

        const new_id = next_id;
        next_id += 1;

        return .{
            .id = new_id,
            .display = display,
            .fd = fd,
            .data = data,
        };
    }

    /// Caller owns the buffer which must be destroy()ed.
    pub fn createBuffer(
        pool: ShmPool,
        offset: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: Shm.Format,
    ) !Buffer {
        const id = next_id;
        next_id += 1;

        try pool.display.sendMsg(pool.id, 0, .{
            id,
            offset,
            width,
            height,
            stride,
            @intFromEnum(format),
        });

        return .{
            .id = id,
            .display = pool.display,
        };
    }

    /// Destroys and frees up the memory
    pub fn destroy(pool: ShmPool) void {
        std.posix.munmap(pool.data);
        std.posix.close(pool.fd);
        pool.display.sendMsg(pool.id, 1, .{}) catch |err| {
            std.log.err(
                "wl_shm_pool: unable to send destroy message to server, hope everything is okay: {}",
                .{err},
            );
        };
    }

    pub fn resize(pool: *ShmPool, new_size: u32) !void {
        try std.posix.ftruncate(pool.fd, new_size);
        pool.data = try std.posix.mremap(
            @ptrCast(pool.data),
            0, // will create a mapping with the same pages since it is shared
            new_size,
            .{ .MAYMOVE = true },
            null,
        );
        try pool.display.sendMsg(pool.id, 2, .{new_size});
    }
};

pub const Buffer = struct {
    id: u32,
    display: *Display,

    const Event = void;
    pub usingnamespace setHandlerNamespace(@This());

    pub fn destroy(b: Buffer) void {
        b.display.sendMsg(b.id, 0, .{}) catch |err| std.log.err("destroy buffer: {}", .{err});
    }
};

pub const XdgWmBase = struct {
    id: u32 = 0,
    display: *Display,

    pub const Event = union(enum) {
        ping: u32,
        fn parse(_: u32, data: []const u32) !Event {
            return .{ .ping = data[0] };
        }
    };
    pub usingnamespace setHandlerNamespace(@This());

    pub fn init(disp: *Display) XdgWmBase {
        const id = next_id;
        next_id += 1;
        std.log.debug("xdg_wm_base: {} init()", .{id});
        return .{
            .id = id,
            .display = disp,
        };
    }

    pub fn destroy(base: XdgWmBase) void {
        std.log.debug("xdg_wm_base: {} destroy()", .{base.id});
        base.display.sendMsg(base.id, 0, .{}) catch |err|
            std.log.err("destroy xdg_wm_base: {}", .{err});
    }

    pub fn getXdgSurface(base: XdgWmBase, surface: Surface) !XdgSurface {
        const id = next_id;
        next_id += 1;
        try base.display.sendMsg(base.id, 2, .{ id, surface.id });

        return .{
            .id = id,
            .display = base.display,
        };
    }

    pub fn pong(base: XdgWmBase, serial: u32) !void {
        try base.display.sendMsg(base.id, 3, .{serial});
    }
};

pub const XdgSurface = struct {
    id: u32,
    display: *Display,

    pub const Event = union(enum) {
        configure: u32,
        fn parse(_: u32, data: []const u32) !Event {
            return .{ .configure = data[0] };
        }
    };
    pub usingnamespace setHandlerNamespace(@This());

    pub fn destroy(d: @This()) void {
        d.display.sendMsg(d.id, 0, .{}) catch |err|
            std.log.err("destroy xdg_surface: {}", .{err});
    }

    pub fn getToplevel(s: XdgSurface) !XdgToplevel {
        const id = next_id;
        next_id += 1;
        try s.display.sendMsg(s.id, 1, .{id});

        return .{
            .id = id,
            .display = s.display,
        };
    }

    pub fn ackConfigure(s: XdgSurface, serial: u32) !void {
        try s.display.sendMsg(s.id, 4, .{serial});
    }
};

pub const XdgToplevel = struct {
    id: u32,
    display: *Display,

    pub const Event = union(enum) {
        pub const State = enum(u32) {
            maximized = 1,
            fullscreen = 2,
            resizing = 3,
            activated = 4,
            tiled_left = 5,
            tiled_right = 6,
            tiled_top = 7,
            tiled_bottom = 8,
            suspended = 9,
            _,
        };
        configure: struct {
            width: u32,
            height: u32,
            states: []const State,
        },
        close: void,
        configure_bounds: struct {
            width: u32,
            height: u32,
        },
        wm_capabilities: void,
        fn parse(event: u32, data: []const u32) !Event {
            return switch (event) {
                0 => .{ .configure = .{
                    .width = data[0],
                    .height = data[1],
                    .states = @ptrCast(data[3..]),
                } },
                1 => .close,
                2 => .{ .configure_bounds = .{
                    .width = data[0],
                    .height = data[1],
                } },
                3 => .wm_capabilities,
                else => unreachable,
            };
        }
    };
    pub usingnamespace setHandlerNamespace(@This());

    pub fn destroy(d: @This()) void {
        d.display.sendMsg(d.id, 0, .{}) catch |err|
            std.log.err("destroy xdg_toplevel: {}", .{err});
    }

    pub fn setTitle(tl: XdgToplevel, new_title: []const u8) !void {
        try tl.display.sendMsg(tl.id, 2, .{new_title});
    }

    pub fn setMaxSize(tl: XdgToplevel, width: i32, height: i32) !void {
        try tl.display.sendMsg(tl.id, 7, .{ width, height });
    }

    pub fn setMinSize(tl: XdgToplevel, width: i32, height: i32) !void {
        try tl.display.sendMsg(tl.id, 8, .{ width, height });
    }
};

pub const XdgDecorationManager = struct {
    id: u32,
    display: *Display,

    pub fn init(disp: *Display) XdgDecorationManager {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .display = disp,
        };
    }

    pub fn destroy(dm: @This()) void {
        dm.display.sendMsg(dm.id, 0, .{}) catch |err|
            std.log.err("destroy xdg_decoration_manager: {}", .{err});
    }

    pub fn getToplevelDecoration(dm: @This(), tl: XdgToplevel) !XdgToplevelDecoration {
        const id = next_id;
        next_id += 1;
        try dm.display.sendMsg(dm.id, 1, .{ id, tl.id });
        return .{
            .id = id,
            .display = dm.display,
        };
    }
};

pub const XdgToplevelDecoration = struct {
    id: u32,
    display: *Display,

    pub const Mode = enum(u32) {
        client_side = 1,
        server_side = 2,
        fn parse(_: u32, data: []const u32) !Mode {
            return @enumFromInt(data[0]);
        }
    };
    pub const Event = Mode;
    pub usingnamespace setHandlerNamespace(@This());

    pub fn destroy(d: @This()) void {
        d.display.sendMsg(d.id, 0, .{}) catch |err|
            std.log.err("destroy xdg_toplevel_decoration: {}", .{err});
    }

    pub fn setMode(tld: @This(), mode: Mode) !void {
        try tld.display.sendMsg(tld.id, 1, .{@intFromEnum(mode)});
    }

    pub fn unsetMode(tld: @This()) !void {
        try tld.display.sendMsg(tld.id, 2, .{});
    }
};

pub const Subcompositor = struct {
    id: u32,
    display: *Display,

    pub fn init(display: *Display) Subcompositor {
        const id = next_id;
        next_id += 1;
        return .{
            .id = id,
            .display = display,
        };
    }

    pub fn destroy(s: @This()) void {
        s.display.sendMsg(s.id, 0, .{}) catch |err|
            std.log.err("destroy wl_subcompositor: {}", .{err});
    }

    pub fn getSubsurface(s: @This(), surface: Surface, parent: Surface) !Subsurface {
        const id = next_id;
        next_id += 1;
        try s.display.sendMsg(s.id, 1, .{ id, surface.id, parent.id });
        return .{
            .id = id,
            .display = s.display,
        };
    }
};

pub const Subsurface = struct {
    id: u32,
    display: *Display,

    pub fn destroy(s: @This()) void {
        s.display.sendMsg(s.id, 0, .{}) catch |err|
            std.log.err("destroy wl_subsurface: {}", .{err});
    }

    pub fn setPosition(s: @This(), x: i32, y: i32) !void {
        try s.display.sendMsg(s.id, 1, .{ x, y });
    }

    pub fn placeAbove(s: @This(), sibling: Surface) !void {
        try s.display.sendMsg(s.id, 2, .{sibling.id});
    }

    pub fn placeBelow(s: @This(), sibling: Surface) !void {
        try s.display.sendMsg(s.id, 3, .{sibling.id});
    }

    pub fn setSync(s: @This()) !void {
        try s.display.sendMsg(s.id, 4, .{});
    }

    pub fn setDesync(s: @This()) !void {
        try s.display.sendMsg(s.id, 5, .{});
    }
};
