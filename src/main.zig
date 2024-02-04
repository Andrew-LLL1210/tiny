const std = @import("std");
const report = @import("report.zig");
const parse = @import("parse.zig");
const run = @import("run.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const out_color_config = std.io.tty.detectConfig(std.io.getStdOut());
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    const color_config = std.io.tty.detectConfig(std.io.getStdErr());

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // parse command-line arguments
    // TODO use a real argparse library
    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.skip(); // skip binary name

    // get command
    // one of "run" or "labels"
    const command = args_it.next() orelse {
        try stderr.writeAll("expected command (run, labels)\n");
        return error.IncorrectUsage;
    };

    // get source
    const file_name = args_it.next() orelse {
        try stderr.writeAll("expected filename\n");
        return error.IncorrectUsage;
    };
    const source = blk: {
        var file = try std.fs.cwd().openFile(file_name, .{});
        const fin = file.reader();
        defer file.close();

        break :blk try fin.readAllAlloc(alloc, 20_000);
    };
    defer alloc.free(source);

    // prepare Reporter
    var reporter = report.Reporter{
        .out = stderr,
        .file_name = file_name,
        .source = source,
        .options = .{ .color_config = color_config },
    };

    // dispatch command
    if (std.mem.eql(u8, command, "run")) {

        // Get listing from parser
        const listing = try parse.parse(source, &reporter, alloc);
        defer alloc.free(listing);

        reporter.listing = listing;
        try run.runMachine(listing, stdin, stdout, &reporter);
    } else if (std.mem.eql(u8, command, "labels")) {
        try parse.printSkeleton(stdout, out_color_config, source, &reporter, alloc);
    } else {
        try stderr.print("{s} is not a command", .{command});
        return error.IncorrectUsage;
    }
}
