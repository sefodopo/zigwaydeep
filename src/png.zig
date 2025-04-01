const std = @import("std");
const builtin = @import("builtin");

const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn pngToArgb8888(allocator: std.mem.Allocator, png_datastream: []const u8, width: u32, height: u32, outBuffer: []u8) !void {
    if (!std.mem.startsWith(u8, png_datastream, &SIGNATURE)) return error.NotPNGDatastream;

    var png_data: []const u8 = png_datastream[8..];
    const ihdr = parseChunk(IHDR, Chunk.extract(&png_data).data);
    std.log.debug("ihdr: {}", .{ihdr});
    if (ihdr.width != width or ihdr.height != height) return error.WrongDimensions;
    // Only truecolor with alpha is supported
    if (ihdr.color_type != 6) return error.UnsupportedPNGColorType;
    var reader = IDATReader{
        .datastream = png_data,
        .chunk_data = &.{},
    };
    var decompressor = std.compress.zlib.decompressor(reader.reader());
    const decompressed_stream = decompressor.reader();
    const stride = ihdr.width * 4 * ihdr.bit_depth / 8;
    const in_offset = ihdr.bit_depth / 2;
    const scanlines: []u8 = try allocator.alloc(u8, stride * 2);
    @memset(scanlines, 0);
    defer allocator.free(scanlines);
    for (0..ihdr.height) |y| {
        const filter = try decompressed_stream.readByte();
        const last_scanline = if (y % 2 == 0) scanlines[0..stride] else scanlines[stride..];
        const scanline = if (y % 2 == 0) scanlines[stride..] else scanlines[0..stride];
        try decompressed_stream.readNoEof(scanline);
        switch (filter) {
            0 => {},
            1 => { // Sub
                for (4..stride) |i| {
                    scanline[i] = @truncate(@as(u9, scanline[i]) + @as(u9, scanline[i - 4]));
                }
            },
            2 => { // Up
                for (0..stride) |i| {
                    scanline[i] = @truncate(@as(u9, scanline[i]) + @as(u9, last_scanline[i]));
                }
            },
            3 => { // Average
                for (0..4) |i| {
                    scanline[i] = @truncate(@as(u9, scanline[i]) + (@as(u9, last_scanline[i]) >> 1));
                }
                for (4..stride) |i| {
                    scanline[i] = @truncate(@as(u9, scanline[i]) + (@as(u9, scanline[i - 4]) + @as(u9, last_scanline[i])) / 2);
                }
            },
            4 => { // Paeth
                std.log.debug("PNG: encountered Paeth filter, hopefully this is correct", .{});
                for (0..4) |i| {
                    scanline[i] = @truncate(@as(u9, scanline[i]) + @as(u9, last_scanline[i]));
                }
                for (4..stride) |i| {
                    const a = @as(i16, scanline[i - 4]);
                    const b = @as(i16, last_scanline[i]);
                    const c = @as(i16, last_scanline[i - 4]);
                    const p = a + b - c;
                    const pa = @abs(p - a);
                    const pb = @abs(p - b);
                    const pc = @abs(p - c);
                    const pr = if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                    scanline[i] = @truncate(@as(u9, scanline[i]) + @as(u9, @intCast(pr)));
                }
            },
            else => unreachable,
        }
        for (0..ihdr.width) |x| {
            outBuffer[y * width * 4 + x * 4] = scanline[x * in_offset + 3];
            outBuffer[y * width * 4 + x * 4 + 1] = scanline[x * in_offset];
            outBuffer[y * width * 4 + x * 4 + 2] = scanline[x * in_offset + 1];
            outBuffer[y * width * 4 + x * 4 + 3] = scanline[x * in_offset + 2];
        }
    }
}

const IDATReader = struct {
    const ReadError = error{InvalidPNGDatastream};
    datastream: []const u8,
    chunk_data: []const u8,
    done: bool = false,
    fn read(ir: *IDATReader, buffer: []u8) ReadError!usize {
        if (ir.done or buffer.len == 0) return 0;
        if (ir.chunk_data.len == 0) {
            while (ir.datastream.len >= 12) {
                const chunk = Chunk.extract(&ir.datastream);
                if (std.mem.eql(u8, chunk.type, "IEND")) {
                    ir.done = true;
                    std.log.debug("Reached end of PNG Datastream", .{});
                    return 0;
                }
                if (std.mem.eql(u8, chunk.type, "IDAT")) {
                    ir.chunk_data = chunk.data;
                    break;
                }
                std.log.debug("ignoring chunk: {s}", .{chunk.type});
            } else {
                // We expect IEND to come last before the end of datastream
                return error.InvalidPNGDatastream;
            }
        }
        if (ir.chunk_data.len > buffer.len) {
            std.mem.copyForwards(u8, buffer, ir.chunk_data[0..buffer.len]);
            ir.chunk_data = ir.chunk_data[buffer.len..];
            return buffer.len;
        }
        const len = ir.chunk_data.len;
        std.mem.copyForwards(u8, buffer, ir.chunk_data);
        ir.chunk_data = &.{};
        return len;
    }

    fn reader(ir: *IDATReader) std.io.GenericReader(*IDATReader, ReadError, read) {
        return .{ .context = ir };
    }
};

fn parseChunk(T: type, data: []const u8) T {
    var t: T = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&t), data);
    if (builtin.cpu.arch.endian() == .little)
        std.mem.byteSwapAllFields(T, &t);
    return t;
}

const Chunk = struct {
    length: u32,
    type: []const u8,
    data: []const u8,
    crc: []const u8,
    fn extract(data: *[]const u8) Chunk {
        const length = std.mem.bigToNative(u32, @as([]align(1) const u32, @ptrCast(data.*[0..4]))[0]);
        const ctype = data.*[4..8];
        const cdata = data.*[8 .. 8 + length];
        const crc = data.*[8 + length .. 8 + length + 4];
        data.* = data.*[8 + length + 4 ..];
        return .{
            .length = length,
            .type = ctype,
            .data = cdata,
            .crc = crc,
        };
    }
};

const IHDR = packed struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

test "ihdr" {
    const imgtest = @embedFile("White_dot.png");
    var buf: [32 * 32 * 4]u8 = undefined;
    try pngToArgb8888(imgtest, 32, 32, &buf);
}

pub fn main() !void {
    const png_data = @embedFile("White_dot.png");
    var buffer: [32 * 32 * 4]u8 = undefined;
    var alloc_buffer: [1024]u8 = undefined;
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&alloc_buffer);
    const allocator = fixed_buffer.allocator();
    try pngToArgb8888(allocator, png_data, 32, 32, &buffer);
}
