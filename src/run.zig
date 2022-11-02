const std = @import("std");
const lib = @import("main.zig");
const Machine = lib.Machine;
const Reader = std.fs.File.Reader;
const usage =
    \\usage: tiny [program.state]
    \\
;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    var args_it = std.process.args();
    _ = args_it.skip();
    const filename = try args_it.next(std.heap.page_allocator) orelse return (stderr.writeAll(usage));
    defer std.heap.page_allocator.free(filename);
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fin = file.reader();

    var machine = Machine.init();
    try readState(&machine, fin);

    try machine.run(stdin, stdout);
}

pub fn readState(machine: *Machine, src: Reader) !void {
    var i: u16 = 0;
    while (try nextToken(src)) |token| switch (token) {
        .adr => |adr| {
            i = adr;
        },
        .value => |value| {
            machine.memory[i] = value;
            i += 1;
        },
    };
}

pub const Token = union(enum) {
    adr: u16,
    value: u24,
};

pub fn nextToken(src: Reader) !?Token {
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
    } else |_| return null; // eof
}

fn parseInt(comptime T: type, set: []const u8) T {
    var acc: T = 0;
    for (set) |digit| acc = acc * 10 + digit - '0';
    return acc;
}
