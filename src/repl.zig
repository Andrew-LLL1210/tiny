const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const Reporter = @import("reporter.zig").Reporter;
const Operation = @import("Operation.zig");
const Listing = tiny.listing;
const Machine = @import("Machine.zig");

const separateParts = tiny.separateParts;

pub fn run(stdin: Reader, stdout: Writer, stderr: Writer, alloc: Allocator) !void {
    var reporter = Reporter(Writer){
        .path = "REPL",
        .writer = stderr,
    };

    var machine = Machine.init(stdin, stdout, stderr, &reporter);

    // holds the lines because we need them to last
    var arena = std.heap.ArenaAllocator.init(alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 200)) |rline| {
        defer alloc.free(rline);

        if (replDirective(rline)) |dir| switch (dir) {};

        const parts = try separateParts(rline, arena_alloc, reporter);
    }
}

const Directive = union(enum) {
    help, // display help
    state, // display the registers
    do: []const u8, // execute a tiny command immediately
    labels, // list all labels
    start, // begin execution
    goto: Ptr, // move ip to address
    move: isize, // move ip relatively
};
