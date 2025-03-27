const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = std.net.Stream;

/// Allocator is used to create connection string from
/// environment variables which is then freed.
pub fn displayConnect(allocator: Allocator) !Stream {
    const display = std.posix.getenv("WAYLAND_DISPLAY");
    if (display == null) {
        return error.WAYLAND_DISPLAY_NotSet;
    }
    if (display.?[0] == '/') {
        return try std.net.connectUnixSocket(display.?);
    }
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |rd| {
        const path = try std.fs.path.join(allocator, &.{ rd, display.? });
        defer allocator.free(path);
        return try std.net.connectUnixSocket(path);
    }
    return error.XDG_RUNTIME_DIR_NotSet;
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

pub fn getRegistry(conn: Stream) !void {
    try sendMsg(conn, 1, 1, .{2});
}

pub fn sync(conn: Stream, cb: u32) !void {
    try sendMsg(conn, 1, 0, .{cb});
}

pub const Msg = struct {
    object: u32,
    event: u32,
    data: []const u32,
    allocator: ?Allocator,

    /// Frees the data of the msg
    pub fn free(msg: *const Msg) void {
        if (msg.allocator) |allocator|
            allocator.free(msg.data);
    }
};

/// It is the callers responsibility to call free
/// on the returned Msg.
pub fn readMsg(allocator: Allocator, conn: Stream) !Msg {
    var header: [2]u32 = undefined;
    if (try conn.readAll(@ptrCast(&header)) != 8) {
        return error.ReadHeader;
    }

    const len = header[1] >> 18;
    if (len == 2)
        return Msg{
            .object = header[0],
            .event = header[1] & 0xFFFF,
            .data = &.{},
            .allocator = null,
        };

    const data = try allocator.alloc(u32, len - 2);
    errdefer allocator.free(data);

    if (try conn.readAll(@ptrCast(data)) != (len - 2) << 2) {
        return error.ReadData;
    }
    return Msg{
        .object = header[0],
        .event = header[1] & 0xFFFF,
        .data = data,
        .allocator = allocator,
    };
}

pub fn bind(conn: Stream, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
    try sendMsg(conn, 2, 0, .{ name, interface, version, new_id });
}

pub const ShmPool = struct {
    fd: std.posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    id: u32,

    pub fn create(conn: Stream, shm_id: u32, new_id: u32, size: u32) !ShmPool {
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

        const msg: [5]u32 = .{ shm_id, 4 << 18, new_id, size, 0 };
        const iov = std.posix.iovec_const{
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
        @memset(&buf, 0);
        var control: *CMSGHDR = @ptrCast(&buf);
        control.len = buf.len;
        control.level = std.posix.SOL.SOCKET;
        control.type = 1;
        const cmsgdata: []u8 = buf[@sizeOf(CMSGHDR)..];
        @memcpy(cmsgdata[0..@sizeOf(std.posix.fd_t)], std.mem.asBytes(&fd));
        const msghdr = std.os.linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &.{iov},
            .iovlen = 1,
            .control = &buf,
            .controllen = buf.len,
            .flags = 0,
        };
        const n = try std.posix.sendmsg(conn.handle, &msghdr, std.posix.MSG.OOB);
        if (n != 17) {
            return error.SendMsgFd;
        }
        return .{
            .fd = fd,
            .data = data,
            .id = new_id,
        };
    }

    /// Resizes the ShmPool, however the pool must grow!
    pub fn resize(pool: *ShmPool, conn: Stream, new_size: u32) !void {
        if (new_size <= pool.len) return error.ThePoolMustGrow;
        try std.posix.ftruncate(pool.fd, new_size);
        pool.data = try std.posix.mremap(
            pool.data,
            0,
            new_size,
            0,
            null,
        );
        try sendMsg(conn, pool.id, 2, .{new_size});
    }

    pub fn destroy(pool: *const ShmPool, conn: ?Stream) void {
        if (conn) |c| {
            sendMsg(c, pool.id, 0, .{}) catch |err| {
                std.log.err("wl_shm_pool unable to send destroy: {}", .{err});
            };
        }
        std.posix.munmap(pool.data);
        std.posix.close(pool.fd);
    }
};
