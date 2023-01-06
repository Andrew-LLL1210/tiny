const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const operation = @import("operation.zig");
const AssemblyResult = tiny.Result(Listing);
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

    const listing = try handle(try tiny.readSource(src, alloc), filepath, stderr) orelse return;
    defer alloc.free(listing);

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);
    try machine.run();
}

fn handle(result: AssemblyResult, f: []const u8, w: Writer) !?Listing {
    if (result == .Ok) return result.Ok;

    switch (result.Err) {
        .DuplicateLabel => |e| {
            try errorWrite(w, f, e.line2, null, msg.duplicate_label, .{e.name});
            try errorWrite(w, f, e.line1, null, msg.duplicate_label_note, .{});
        },
        .ReservedLabel => @panic("ReservedLabel"),
        .UnknownLabel => @panic("UnknownLabel"),
        .InvalidSourceInstruction => @panic("InvalidSourceInstruction"),
        .BadByte => @panic("BadByte"),
        .UnexpectedCharacter => @panic("UnexpectedCharacter"),
    }
    return null;
}

const msg = struct {
    const usage =
        \\
        \\tiny run [file]   - build and run a tiny program
        \\tiny help         - display this help
        \\
        \\
    ;

    const b = "\x1b[91m";
    const endl = "\x1b[0m\n";
    const err = "\x1b[91merror:\x1b[97m ";
    const note = "\x1b[96mnote:\x1b[97m ";
    const warning = "\x1b[91mwarning:\x1b[97m ";

    // CLI errors
    const no_filename = err ++ "no file provided" ++ endl;
    const not_command = err ++ "'{s}' is not a command" ++ endl;
    const file_not_found = err ++ "file not found: '{s}'" ++ endl;

    // Assembly errors
    const duplicate_label = err ++ "duplicate label '{s}'";
    const duplicate_label_note = note ++ "original label here";
};

fn errorWrite(writer: Writer, filename: []const u8, line: usize, col: ?usize, comptime message: []const u8, args: anytype) !void {
    try writer.print("\x1b[91m{s}:{d}:", .{ filename, line });
    if (col) |c| try writer.print("{d}: ", .{c}) else try writer.writeAll(" ");
    try writer.print(message, args);
    try writer.writeAll(msg.endl);
}
