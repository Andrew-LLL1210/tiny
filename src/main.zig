const std = @import("std");
const report = @import("report.zig");
const parse = @import("parse.zig");
const run = @import("run.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
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
    const file_name = args_it.next() orelse {
        return stdout.writeAll("expected filename\n");
    };

    // get source
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

    // Get listing from parser
    const listing = try parse.parse(source, &reporter, alloc);
    defer alloc.free(listing);

    reporter.listing = listing;
    try run.runMachine(listing, stdin, stdout, &reporter);
}
