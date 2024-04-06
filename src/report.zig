const std = @import("std");
const parse = @import("parse.zig");
const sema = @import("sema.zig");

pub const FileData = struct {
    name: []const u8,
    pos: usize,
    lines: usize,
    pub fn init(name: []const u8, pos: usize, lines: usize) FileData {
        return .{ .name = name, .pos = pos, .lines = lines };
    }
};

pub const Reporter = struct {
    out: std.fs.File.Writer,
    files: []const FileData,
    source: []const u8,
    options: Options,
    src: []const u8,

    pub fn reportError(self: *const Reporter, err: anyerror) !void {
        const src = self.src;
        const global_line_no = std.mem.count(u8, before(self.source, src), "\n") + 1;
        const file, const line_no = self.getFileAndLine(global_line_no);

        const config = self.options.color_config;
        defer config.setColor(self.out, .reset) catch {};

        try config.setColor(self.out, .bold);
        try config.setColor(self.out, .bright_white);
        try self.out.print("{s}:{d}: ", .{ file.name, line_no });
        try config.setColor(self.out, .bright_red);
        try self.out.print("{s}\n", .{@errorName(err)});
        try config.setColor(self.out, .reset);

        const line = getLine(self.source, src);
        try self.out.print("{s}\n", .{line});
        try config.setColor(self.out, .green);
        try underline(line, src, 8, '^', self.out); // TODO detect tab-width
    }

    fn getFileAndLine(self: *const Reporter, line: usize) struct { FileData, usize } {
        var start_line: usize = 0;
        for (self.files) |file| {
            if (start_line + file.lines >= line) {
                return .{ file, line - start_line };
            }
            start_line += file.lines;
        }
        return .{ FileData.init("???", 0, 0), 0 };
    }

    const Options = struct {
        color_config: std.io.tty.Config,
    };
};

fn index(string: []const u8, slice: []const u8) usize {
    return @intFromPtr(slice.ptr) - @intFromPtr(string.ptr);
}

/// assumes that slice is a slice of string
fn before(string: []const u8, slice: []const u8) []const u8 {
    return string[0..index(string, slice)];
}

/// assumes that slice is a slice of string
fn getLine(string: []const u8, slice: []const u8) []const u8 {
    const ix = index(string, slice);
    const start = for (0..ix) |off| (if (string[ix - off] == '\n') break ix - off + 1) else 0;
    const end = for (start..string.len) |i| (if (string[i] == '\n') break i) else string.len;

    return string[start..end];
}

fn underline(string: []const u8, slice: []const u8, tabwidth: usize, char: u8, out: anytype) !void {
    const ix = index(string, slice);
    const tab_count = std.mem.count(u8, string, "\t");
    const pre_width = ix - tab_count + tab_count * tabwidth;
    try out.writeByteNTimes(' ', pre_width);
    try out.writeByteNTimes(char, slice.len);
    try out.writeByte('\n');
}
