const std = @import("std");
const builtin = @import("builtin");

const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn pngToArgb8888(png_datastream: []const u8, width: u32, height: u32, outBuffer: []u8) !void {
    if (!std.mem.startsWith(u8, png_datastream, &SIGNATURE)) return error.NotPNGDatastream;

    var png_data: []const u8 = png_datastream[8..];
    const ihdr = parseChunk(IHDR, Chunk.extract(&png_data).data);
    std.log.debug("ihdr: {}", .{ihdr});
    if (ihdr.width != width or ihdr.height != height) return error.WrongDimensions;
    // Only truecolor is supported
    if (ihdr.color_type != 6) return error.UnsupportedPNGColorType;
    var writer = TrueColorWriter{
        .bitdepth = @enumFromInt(ihdr.bit_depth),
        .outBuffer = outBuffer,
    };
    var reader = IDATReader{
        .datastream = png_data,
        .chunk_data = &.{},
    };
    try std.compress.zlib.decompress(reader.reader(), writer.writer());
}

const TrueColorWriter = struct {
    const WriteError = error{TooMuchInput};
    bitdepth: enum(u8) {
        byte = 8,
        word = 16,
    },
    outBuffer: []u8,
    fn write(self: *TrueColorWriter, bytes: []const u8) WriteError!usize {
        switch (self.bitdepth) {
            .byte => {
                if (bytes.len > self.outBuffer.len) {
                    return error.TooMuchInput;
                }
                for (0..bytes.len / 4) |i| {
                    self.outBuffer[i * 4] = bytes[i * 4 + 3];
                    self.outBuffer[i * 4 + 1] = bytes[i * 4];
                    self.outBuffer[i * 4 + 2] = bytes[i * 4 + 1];
                    self.outBuffer[i * 4 + 3] = bytes[i * 4 + 2];
                }
                const written = bytes.len - (bytes.len % 4);
                self.outBuffer = self.outBuffer[written..];
                return written;
            },
            .word => {
                if (bytes.len / 2 > self.outBuffer.len) {
                    return error.TooMuchInput;
                }
                for (0..bytes.len / 8) |i| {
                    self.outBuffer[i * 4] = bytes[i * 8 + 6];
                    self.outBuffer[i * 4 + 1] = bytes[i * 8];
                    self.outBuffer[i * 4 + 2] = bytes[i * 8 + 2];
                    self.outBuffer[i * 4 + 3] = bytes[i * 8 + 4];
                }
                const written = bytes.len - (bytes.len % 8);
                self.outBuffer = self.outBuffer[written / 2 ..];
                return written;
            },
        }
    }

    fn writer(self: *TrueColorWriter) std.io.GenericWriter(*TrueColorWriter, WriteError, write) {
        return .{ .context = self };
    }
};

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
    try pngToArgb8888(png_data, 32, 32, &buffer);
}
