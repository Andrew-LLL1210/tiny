const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Word = u24;

const tiny = @import("tiny.zig");
const operation = @import("operation.zig");
const Diagnostic = tiny.Diagnostic;
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
    const listing: Listing = tiny.readSource(src, alloc, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| return handle(e, diagnostic, stderr),
    };
    defer alloc.free(listing);

    var machine = Machine.init(stdin, stdout, stderr);
    machine.loadListing(listing);
    try machine.run();
}

fn handle(err: AssemblyError, info: Diagnostic, writer: Writer) !void {
    const closure = (struct {
        w: Writer,
        i: Diagnostic,
        fn write(self: @This(), comptime message: []const u8, args: anytype) !void {
            return errorWrite(self.w, self.i.filepath, self.i.line, null, message, args);
        }
    }{ .w = writer, .i = info });
    switch (err) {
        error.DuplicateLabel => {
            try closure.write(msg.duplicate_label, .{info.label_name});
            try errorWrite(writer, info.filepath, info.label_prior_line, null, msg.duplicate_label_note, .{});
        },
        error.ReservedLabel => try closure.write(msg.reserved_label, .{info.label_name}),
        error.UnknownLabel => try closure.write(msg.unknown_label, .{info.label_name}),
        error.UnknownInstruction => try closure.write(msg.unknown_instruction, .{info.op}),
        error.BadByte => try closure.write(msg.bad_byte, .{info.byte}),
        error.UnexpectedCharacter => return err,
        error.DislikesImmediate => return err,
        error.DislikesOperand => return err,
        error.NeedsImmediate => {
            try closure.write(msg.err ++ "'{s}' instruction requires an immediate value as its operand", .{info.op});
            try closure.write(msg.argument_range_note, .{});
        },
        error.NeedsOperand => try closure.write("\x1b[91merror:\x1b[97m '{s}' instruction requires an operand", .{info.op}),
        error.RequiresLabel => return err,
        error.DirectiveExpectedAgument => return err,
        error.ArgumentOutOfRange => return err,
        error.DbOutOfRange => return err,
        error.DsOutOfRange => return err,
    }
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
    const warning = "\x1b[93mwarning:\x1b[97m ";

    // CLI errors
    const no_filename = err ++ "no file provided" ++ endl;
    const not_command = err ++ "'{s}' is not a command" ++ endl;
    const file_not_found = err ++ "file not found: '{s}'" ++ endl;

    // Assembly errors
    const duplicate_label = err ++ "duplicate label '{s}'";
    const duplicate_label_note = note ++ "original label here";
    const reserved_label = err ++ "'{s}' is a reserved label name";
    const unknown_label = err ++ "unknown label '{s}'";
    const unknown_instruction = err ++ "unknown instruction '{s}'";
    const bad_byte = err ++ "bad byte {d}";
    const db_range_note = note ++ "'db' expects an integer in the range -99999 to 99999";
    const argument_range_note = note ++ "tiny allows only numeric arguments in the range 0 to 999";
};

fn errorWrite(writer: Writer, filename: []const u8, line: usize, col: ?usize, comptime message: []const u8, args: anytype) !void {
    try writer.print("\x1b[97m{s}:{d}:", .{ filename, line });
    if (col) |c| try writer.print("{d}: ", .{c}) else try writer.writeAll(" ");
    try writer.print(message, args);
    try writer.writeAll(msg.endl);
}
