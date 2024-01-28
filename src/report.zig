const std = @import("std");
const parse = @import("parse.zig");

pub const Reporter = struct {
    out: std.fs.File.Writer,
    file_name: []const u8,
    source: []const u8,
    options: Options,
    listing: ?parse.Listing = null,

    pub const ReportedError = error{ReportedError};

    pub fn reportErrorLine(
        self: *const Reporter,
        line_no: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) ReportedError {
        return self.reportErrorLineCol(line_no, 0, 0, fmt, args);
    }

    pub fn reportErrorLineCol(
        self: *const Reporter,
        line_no: usize,
        col_start: usize,
        col_end: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) ReportedError {
        self.reportErrorRaw(line_no, col_start, col_end, fmt, args) catch {};
        return ReportedError.ReportedError;
    }

    pub fn reportErrorRaw(
        self: *const Reporter,
        line_no: usize,
        col_start: usize,
        col_end: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const config = self.options.color_config;
        defer config.setColor(self.out, .reset) catch {};

        try config.setColor(self.out, .bold);
        try config.setColor(self.out, .bright_white);
        try self.out.print("{s}:{d}: ", .{ self.file_name, line_no });
        try config.setColor(self.out, .bright_red);
        try self.out.writeAll("error: ");
        try config.setColor(self.out, .bright_white);
        try self.out.print(fmt ++ "\n", args);

        if (line_no == 0) return;
        try config.setColor(self.out, .dim);
        try config.setColor(self.out, .bright_white);
        var line_it = std.mem.splitScalar(u8, self.source, '\n');
        for (1..line_no) |_| _ = line_it.next();
        if (line_it.next()) |line| try self.out.print("{s}\n", .{line});

        if (col_start == 0) return;
        try self.out.writeByteNTimes(' ', col_start - 1);
        try self.out.writeByteNTimes('~', col_end - col_start + 1);
        try self.out.writeAll("\n");
    }

    const Options = struct {
        color_config: std.io.tty.Config,
    };
};
