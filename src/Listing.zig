const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

pub const Listing = []const Token;

pub const ReadError =
    error { NoStartAddress, BadByte, EndOfStream }
    || Allocator.Error
    || std.fs.File.ReadError;

/// caller owns returned memory
pub fn read(in: Reader, alloc: Allocator) ReadError!Listing {
    var tokens = ArrayList(Token).init(alloc);
    errdefer tokens.deinit();

    while (try nextToken(in)) |token| try tokens.append(token);

    return tokens.toOwnedSlice();
}

pub fn write(listing: Listing, out: Writer) !void {
    var expect_i: u16 = 40404;
    var i: u16 = 0;
    for (listing) |token| switch (token) {
        .addr => |x| i = x,
        .value => |word| {
            if (i == expect_i)
                try out.print("     {d:0>5}\n", .{word})
            else
                try out.print("\n:{d:0>3} {d:0>5}\n", .{i, word});
            
            i += 1;
            expect_i = i;
        }
    };
}


const Token = union(enum) {
    addr: u16,
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
            return Token{ .addr = parseInt(u16, &digits) };
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
        else => return ReadError.BadByte,
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
