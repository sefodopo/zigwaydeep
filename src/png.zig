const std = @import("std");
const builtin = @import("builtin");

const SIGNATURE = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn pngToArgb8888(png_datastream: []const u8, width: u32, height: u32, outBuffer: []u8) !void {
    if (!std.mem.startsWith(u8, png_datastream, &SIGNATURE)) return error.NotPNGDatastream;

    comptime var i = 8;
    const len: u32 = std.mem.bigToNative(u32, @as([]const u32, @ptrCast(@alignCast(png_datastream[i .. i + 4])))[0]);
    if (!std.mem.eql(u8, png_datastream[i + 4 .. i + 8], "IHDR")) return error.IHDRNotFound;
    i += 8;
    const data = png_datastream[i .. i + len];
    var ihdr: IHDR = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&ihdr), data);
    if (builtin.cpu.arch.endian() == .little) {
        std.mem.byteSwapAllFields(IHDR, &ihdr);
    }
    std.debug.print("ihdr: {}", .{ihdr});
    if (ihdr.width != width or ihdr.height != height) return error.WrongDimensions;
    _ = outBuffer;
}

const IHDR = packed struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_depth: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

test "ihdr" {
    const imgtest = @embedFile("White_dot.png");
    var buf: [32 * 32 * 4]u8 = undefined;
    try pngToArgb8888(imgtest, 32, 32, &buf);
}
