const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const Operation = @import("Operation.zig");
const Listing = @import("Listing.zig");
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

    _ = args_it.skip();
    const filename = args_it.next() orelse return (stderr.writeAll(usage));

    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fin = file.reader();
    _ = fin;

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);

    try machine.run();
}

// :000 91042
//      16900
//      00000
const listing = Listing {.listing = &[_]Listing.Segment{
    .{.begin_index = 0, .data = &[_]Word{
        91042,
        16900,
        0
    }},
}};
