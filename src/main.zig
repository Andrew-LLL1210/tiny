const std = @import("std");
const mem = std.mem;
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

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    const alloc: Allocator = std.heap.page_allocator;

    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    _ = args_it.skip(); // executable name
    const command = args_it.next() orelse {
        try stderr.writeAll(msg.usage);
        return;
    };

    if (mem.eql(u8, command, "run")) {
        try run(stdin, stdout, stderr, &args_it, alloc);
    } else if (mem.eql(u8, command, "help")) {
        try stderr.writeAll(msg.usage);
    } else {
        try stderr.writeAll(msg.usage);
        try stderr.print(msg.not_command, .{command});
    }
}

pub fn run(
    stdin: Reader,
    stdout: Writer,
    stderr: Writer,
    args: anytype,
    alloc: Allocator,
) !void {
    const filename = args.next() orelse {
        try stderr.writeAll(msg.usage);
        try stderr.writeAll(msg.no_filename);
        return;
    };
    const filepath = std.fs.realpathAlloc(alloc, filename) catch |err| switch (err) {
        error.FileNotFound => return stderr.print(msg.file_not_found, .{filename}),
        else => return err,
    };
    defer alloc.free(filepath);

    var reporter = Reporter(Writer){
        .path = filepath,
        .writer = stderr,
    };

    var file = try std.fs.openFileAbsolute(filepath, .{});
    const fin = file.reader();
    defer file.close();

    const listing = tiny.readSource(fin, alloc, &reporter) catch |err| switch (err) {
        error.ReportedError => return,
        else => return err,
    };
    defer alloc.free(listing);

    var machine = Machine.init(stdin, stdout, stderr, &reporter);
    machine.loadListing(listing);
    machine.run() catch |err| switch (err) {
        error.ReportedError => return,
        else => return err,
    };
}

const msg = struct {
    const usage =
        \\
        \\tiny run [file]   - build and run a tiny program
        \\tiny help         - display this help
        \\
        \\
    ;

    const no_filename = "\x1b[91merror:\x1b[97m no file provided\x1b[0m\n";
    const not_command = "\x1b[91merror:\x1b[97m '{s}' is not a command\x1b[0m\n";
    const file_not_found = "\x1b[91merror:\x1b[97m file not found: '{s}'\x1b[0m\n";
};
