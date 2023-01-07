const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const operation = @import("operation.zig");
const Diagnostic = @import("Diagnostic.zig");
const AssemblyError = tiny.AssemblyError;
const Machine = @import("machine.zig").Machine;
const Listing = @import("machine.zig").Listing;

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

    const src = blk: {
        var file = try std.fs.openFileAbsolute(filepath, .{});
        const fin = file.reader();
        defer file.close();

        break :blk try fin.readAllAlloc(alloc, 20_000);
    };
    defer alloc.free(src);

    var diagnostic: Diagnostic = undefined;
    diagnostic.filepath = filepath;
    diagnostic.stderr = stderr;
    const listing: Listing = tiny.readSource(src, alloc, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| return diagnostic.printErrorMessage(e),
    };
    defer alloc.free(listing);

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);
    try machine.run();
}

pub const msg = struct {
    const usage =
        \\
        \\tiny run [file]   - build and run a tiny program
        \\tiny help         - display this help
        \\
        \\
    ;

    pub const b = "\x1b[91m";
    pub const endl = "\x1b[0m\n";
    pub const err = "\x1b[91merror:\x1b[97m ";
    pub const note = "\x1b[96mnote:\x1b[97m ";
    pub const warning = "\x1b[93mwarning:\x1b[97m ";

    // CLI errors
    pub const no_filename = err ++ "no file provided" ++ endl;
    pub const not_command = err ++ "'{s}' is not a command" ++ endl;
    pub const file_not_found = err ++ "file not found: '{s}'" ++ endl;

    // Assembly errors
    pub const duplicate_label = "duplicate label '{s}'";
    pub const duplicate_label_note = "original label here";
    pub const reserved_label = "'{s}' is a reserved label name";
    pub const unknown_label = "unknown label '{s}'";
    pub const unknown_instruction = "unknown instruction '{s}'";
    pub const bad_byte = "unexpected byte with ASCII value {d}";
    pub const db_range_note = "'db' expects an integer in the range -99999 to 99999";
    pub const ds_range_note = "the argument for 'ds' must be small enough to fit in the machine";
    pub const ds_range_note2 = "the machine has 900 memory cells, so the argument should be (much) lower than this";
    pub const argument_range_note = "numeric arguments must be in the range 0 to 999";
    pub const unexpected_character = "unexpected character '{c}'";
    pub const dislikes_immediate = "'{s}' expects a label (or nothing) for its argument";
    pub const dislikes_operand = "'{s}' does not take an argument";
    pub const requires_label = "'{s}' expects a label for its argument";
    pub const directive_expected_agument = "'{s}' directive expects an argument";
    pub const out_of_range = "'{s}' is out of range";
};
