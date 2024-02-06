const std = @import("std");
const parse = @import("parse.zig");

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
    listing: ?parse.Listing = null,

    location: [3]usize = .{ 0, 0, 0 },

    pub const ReportedError = error{ReportedError};

    pub fn reportIp(self: *const Reporter, ip: usize, comptime fmt: []const u8, args: anytype) ReportedError {
        const listing = self.listing orelse {
            self.reportErrorLine(0, fmt, args) catch {};
            // TODO make this a 'note'
            return self.reportErrorLine(0, "Could not load listing to report runtime error", .{});
        };

        const ix = @min(ip, listing.len - 1);
        for (0..ix + 1) |offset| {
            if (listing[ix - offset].ip == ip)
                return self.reportErrorLine(listing[ix - offset].line_no, fmt, args);
        }

        self.reportErrorLine(0, fmt, args) catch {};
        // TODO find nearest previous line and 'note' that instead of vague answer
        return self.reportErrorLine(0, "Error occurred at an IP not found in the listing", .{});
    }

    pub fn setLineCol(self: *Reporter, line_no: usize, col_start: usize, col_end: usize) void {
        self.location = .{ line_no, col_start, col_end };
    }

    pub fn reportHere(self: *const Reporter, comptime fmt: []const u8, args: anytype) ReportedError {
        return self.reportErrorLineCol(self.location[0], self.location[1], self.location[2], fmt, args);
    }

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

    fn reportErrorRaw(
        self: *const Reporter,
        global_line_no: usize,
        col_start: usize,
        col_end: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const file, const line_no = self.getFileAndLine(global_line_no);

        const config = self.options.color_config;
        defer config.setColor(self.out, .reset) catch {};

        try config.setColor(self.out, .bold);
        try config.setColor(self.out, .bright_white);
        try self.out.print("{s}:{d}: ", .{ file.name, line_no });
        try config.setColor(self.out, .bright_red);
        try self.out.writeAll("error: ");
        try config.setColor(self.out, .bright_white);
        try self.out.print(fmt ++ "\n", args);

        if (line_no == 0) return;
        try config.setColor(self.out, .reset);
        var line_it = std.mem.splitScalar(u8, self.source[file.pos..], '\n');
        for (1..line_no) |_| _ = line_it.next();
        if (line_it.next()) |line| try self.out.print("{s}\n", .{line});

        if (col_start == 0) return;
        try config.setColor(self.out, .green);
        try self.out.writeByteNTimes(' ', col_start - 1);
        try self.out.writeByteNTimes('~', col_end - col_start + 1);
        try self.out.writeAll("\n");
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
