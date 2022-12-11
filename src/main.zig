const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const Operation = @import("Operation.zig");
const Listing = @import("listing.zig").Listing;
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

    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fin = file.reader();

    const listing = try tiny.readListing(fin, std.heap.page_allocator);
    defer std.heap.page_allocator.free(listing);

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);
    try machine.run();
}
