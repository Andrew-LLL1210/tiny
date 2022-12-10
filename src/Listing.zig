const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;
const Listing = @This();

listing: []const Segment,
pub const Segment = struct {
    begin_index: u16,
    data: []const Word,
};

pub fn read(src: Reader, alloc: Allocator) !Listing {
    _ = src;
    _ = alloc;
    @compileError("not implemented");
}

pub fn write(self: Listing, out: Writer) !void {
    _ = self;
    _ = out;
    @compileError("not implemented");
}


const Token = union(enum) {
    adr: u16,
    value: u24,
};

fn nextToken(src: Reader) !?Token {
    while (src.readByte()) |byte| switch (byte) {
        ':' => {
            const digits: [3]u8 = .{
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
            };
            return Token{ .adr = parseInt(u16, &digits) };
        },
        '0'...'9' => |digit| {
            const digits: [5]u8 = .{
                digit,
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
            };
            return Token{ .value = parseInt(u24, &digits) };
        },
        ' ', '\n', '\t', '\r' => {},
        else => return error.BadByte,
    } else |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    }
}

fn parseInt(comptime T: type, src: []const u8) T {
    var acc: T = 0;
    for (src) |digit| acc = acc * 10 + digit - '0';
    return acc;
}
