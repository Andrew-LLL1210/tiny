const std = @import("std");
const Word = @import("run.zig").Word;
const Reporter = @import("report.zig").Reporter;

pub const Listing = []const struct { ip: usize, word: Word, line_no: usize };

pub fn parse(
    source: []const u8,
    reporter: *const Reporter,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, ReportedError }!Listing {
    _ = alloc;
    _ = source;

    reporter.reportErrorLine(0, "parse() is not implemented", .{});
    return error.ReportedError;
}

const LabelTable = std.HashMap([]const u8, usize, CaseInsensitiveContext, 80);
const CaseInsensitiveContext = struct {
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
