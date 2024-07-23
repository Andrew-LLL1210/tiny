pub fn HashMap(comptime T: type) type {
    return std.HashMap([]const u8, T, Context, 80);
}

pub const Context = struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        var wh = std.hash.Wyhash.init(0);
        for (key) |char| {
            if (std.ascii.isLower(char)) {
                const e = char - ('a' - 'A');
                wh.update(std.mem.asBytes(&e));
            } else {
                wh.update(std.mem.asBytes(&char));
            }
        }
        return wh.final();
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

const std = @import("std");
