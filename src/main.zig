const std = @import("std");
const fmt_cli = @import("cli/fmt.zig");
const run_cli = @import("cli/run.zig");
const flow_cli = @import("cli/flow.zig");

// cli design ripped from github.com/kristoff-it/ziggy on 2024-05-25
pub const Command = enum { run, fmt, flow, help };

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = std.process.argsAlloc(gpa) catch fatal("oom\n", .{});
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) fatalHelp();
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.debug.print("unrecognized subcommand: '{s}'\n", .{args[1]});
        fatalHelp();
    };

    switch (command) {
        .fmt => fmt_cli.run(args[2..], gpa),
        .run => run_cli.run(args[2..], gpa),
        .help => fatalHelp(),
        else => fatal("TODO command {s}\n", .{@tagName(command)}),
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
        \\  run          Run any number of tiny files concatenated together
        \\  fmt          Format tiny files
        \\  flow         Print and colorize control flow in a tiny program
        \\  help         Show this menu and exit
        \\
    , .{});
}
