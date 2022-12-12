const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const Operation = @import("Operation.zig");
const Listing = tiny.listing;
const Machine = @import("Machine.zig");

const usage =
    \\usage: tiny [program.state]
    \\
;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    var args_it = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args_it.deinit();

    _ = args_it.skip(); // executable name
    const filename = args_it.next() orelse return (stderr.writeAll(usage));
    const filepath = std.fs.realpathAlloc(std.heap.page_allocator, filename) catch |err| switch (err) {
        error.FileNotFound => return stderr.print(
            "\x1b[1;31merror:\x1b[39m FileNotFound:\x1b[0m '{s}'",
            .{filename},
        ),
        else => return err,
    };
    defer std.heap.page_allocator.free(filepath);

    var reporter = tiny.Reporter{
        .filepath = filepath,
        .writer = stderr,
    };

    var file = try std.fs.openFileAbsolute(filepath, .{});
    const fin = file.reader();
    defer file.close();

    const listing = tiny.readSource(fin, std.heap.page_allocator, &reporter) catch |err| switch (err) {
        error.ReportedError => return,
        else => return err,
    };
    defer std.heap.page_allocator.free(listing);

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);
    try machine.run();
}
