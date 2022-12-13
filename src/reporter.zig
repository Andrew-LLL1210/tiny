const eqlIgnoreCase = @import("std").ascii.eqlIgnoreCase;

pub fn Reporter(comptime WriterT: type) type {
    return struct {
        const Self = @This();

        line: usize = 0,
        path: []const u8,
        writer: WriterT,

        pub const ReportType = enum {
            err,
            note,
            warning,
        };

        pub const ReportLayout = enum {
            auto, // file:line:
            line, // file:{d}:
            col, // file:line:{d}:
            bare, //
            pub fn tag(layout: ReportLayout) []const u8 {
                return switch (layout) {
                    .auto, .line => "\x1b[97m{s}:{d}: ",
                    .col => "\x1b[97m{s}:{d}:{d}: ",
                    .bare => "",
                };
            }
        };

        pub const ReportOptions = struct {
            path: bool = true,
            line: bool = true,
            col: bool = false,
        };

        pub const LocOptions = struct {
            path: ?[]const u8 = null,
            line: ?usize = null,
            col: ?usize = null,
        };

        pub const LocInfo = struct {
            path: []const u8,
            line: usize,
            col: usize,
        };

        pub fn report(
            self: Self,
            comptime layout: ReportLayout,
            comptime severity: ReportType,
            comptime message: []const u8,
            args: anytype,
        ) !void {
            const loc_args = switch (layout) {
                .auto, .col => .{ self.path, self.line },
                .line => .{self.path},
                .bare => .{},
            };

            const sev_tag: []const u8 = switch (severity) {
                .err => "\x1b[91merror:",
                .warning => "\x1b[93mwarning:",
                .note => "\x1b[96mnote:",
            } ++ "\x1b[97m ";

            try self.writer.print(
                layout.tag() ++ sev_tag ++ message ++ "\x1b[0m\n",
                loc_args ++ args,
            );
        }

        pub fn reportDuplicateLabel(
            self: Self,
            label_name: []const u8,
            line_no: usize,
            is_rom: bool,
        ) !void {
            try self.report(.auto, .err, "duplicate label '{s}'", .{label_name});
            if (is_rom)
                try self.report(.auto, .note, "'{s}' is reserved", .{canonicalName(label_name).?})
            else
                try self.report(.line, .note, "original label here", .{line_no});
        }

        pub fn canonicalName(label_name: []const u8) ?[]const u8 {
            inline for (.{
                "printInteger",
                "printString",
                "inputInteger",
                "inputString",
            }) |name|
                if (eqlIgnoreCase(label_name, name)) return name;
            return null;
        }
    };
}
