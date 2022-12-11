const std = @import("std");
const lib = @import("lib");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

pub const Listing = []const ?Word;

pub const ReadError =
    error { NoStartAddress, BadByte, EndOfStream }
    || Allocator.Error
    || std.fs.File.ReadError;

/// caller owns returned memory
pub fn read(in: Reader, alloc: Allocator) ReadError!Listing {
    var tokens = ArrayList(?Word).init(alloc);
    errdefer tokens.deinit();

    while (try nextToken(in)) |token| try tokens.append(token);

    return tokens.toOwnedSlice();
}

pub fn write(listing: Listing, out: Writer) !void {
    for (listing) |word| if (word) |data| {
        try out.print("{d:0>5}\n", .{data});
    } else {
        try out.print("?????\n", .{});
    };
}

fn nextToken(src: Reader) !??Word {
    while (src.readByte()) |byte| switch (byte) {
        '?' => {
            try src.skipBytes(4, .{});
            return @as(?Word, null);
        },
        '0'...'9' => |digit| {
            const digits: [5]u8 = .{
                digit,
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
            };
            return try lib.parseInt(u24, &digits);
        },
        ' ', '\n', '\t', '\r' => {},
        else => return ReadError.BadByte,
    } else |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    }
}
