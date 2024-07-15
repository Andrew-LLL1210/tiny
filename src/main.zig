const std = @import("std");
const cli = @import("cli/fmt.zig");

// cli design ripped from github.com/kristoff-it/ziggy on 2024-05-25
pub const Command = enum { run, fmt, check, flow, help };

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_impl.deinit() == .ok);
    const gpa = gpa_impl.allocator();

    const args = std.process.argsAlloc(gpa) catch fatal("oom\n", .{});
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) fatalHelp();
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("unrecognized subcommand: '{s}'\n", .{args[1]});
        fatalHelp();
    };

    switch (command) {
        .fmt => cli.fmt_exe(args[2..], gpa) catch |err| {
            std.debug.print("unexpected error: {s}\n", .{@errorName(err)});
            return;
        },
        .check => cli.check_exe(args[2..], gpa) catch |err| {
            std.debug.print("unexpected error: {s}\n", .{@errorName(err)});
            return;
        },
        .flow => @panic("TODO"),
        .run => cli.run_exe(args[2..], gpa) catch |err| {
            std.debug.print("unexpected error: {s}\n", .{@errorName(err)});
        },
        .help => fatalHelp(),
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn fatalHelp() noreturn {
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
    , .{});
}
