const std = @import("std");
const subcommands = @import("cli/subcommands.zig");
pub const version = "0.1.0";

// cli design ripped from github.com/kristoff-it/ziggy on 2024-05-25
pub const Command = enum { run, fmt, check, flow, help, lsp };

var ok: bool = true;
pub fn main() !void {
    ok = true;
    defer {
        if (!ok) std.process.exit(1);
    }

    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_impl.deinit() == .ok);
    const gpa = gpa_impl.allocator();

    const args = std.process.argsAlloc(gpa) catch return fatal("oom\n", .{});
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) fatalHelp();
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("unrecognized subcommand: '{s}'\n", .{args[1]});
        return fatalHelp();
    };

    (switch (command) {
        .fmt => subcommands.fmt_exe(args[2..], gpa),
        .check => subcommands.check_exe(args[2..], gpa),
        .flow => @panic("TODO"),
        .run => subcommands.run_exe(args[2..], gpa),
        .lsp => @import("cli/lsp.zig").run(gpa, args[2..]),
        .help => fatalHelp(),
    }) catch |err| switch (err) {
        error.ReportedError => ok = false,
        else => return err,
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    ok = false;
}

fn fatalHelp() void {
    fatal(
        \\Usage: tiny COMMAND [OPTIONS]
        \\
        \\Commands:
        \\  run          Interpret a tiny program
        \\  check        Check tiny program for syntax errors
        \\  fmt          Format a tiny program
        \\  flow         Print and colorize control flow in a tiny program
        \\  help         Show this menu and exit
        \\
        \\
    , .{});
}
