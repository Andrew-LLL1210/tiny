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

const test_module = @import("test.zig");
const TestCase = test_module.TestCase;

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
    } else if (mem.eql(u8, command, "test")) {
        try tests(stdout, stderr, &args_it, alloc);
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
    const listing: Listing = tiny.parseListing(src, alloc, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| return diagnostic.printAssemblyErrorMessage(e),
    };
    defer alloc.free(listing);

    const MachineT = Machine(std.fs.File.Reader, std.fs.File.Writer);

    var machine = MachineT.init(stdin, stdout, &diagnostic);
    machine.loadListing(listing);
    machine.run() catch |err| switch (err) {
        error.Stop => unreachable,
        error.AccessDenied, error.BrokenPipe, error.ConnectionResetByPeer, error.DiskQuota, error.FileTooBig, error.InputOutput, error.LockViolation, error.NoSpaceLeft, error.NotOpenForWriting, error.OperationAborted, error.SystemResources, error.Unexpected, error.WouldBlock, error.StreamTooLong, error.ConnectionTimedOut, error.IsDir, error.NotOpenForReading => |e| return e,
        else => |e| return diagnostic.printRuntimeErrorMessage(MachineT, e, &machine),
    };
}

pub fn tests(
    stdout: Writer,
    stderr: Writer,
    args: anytype,
    alloc: Allocator,
) !void {
    const test_cases: []const TestCase = &.{
        TestCase{
            .name = "hello world",
            .input = "",
            .output = "Hallo Welt\n",
        },
        .{
            .name = null,
            .input = "1\n2\n5\n4\n0\n",
            .output = 
            \\This program calculates the arithmetic mean of a set of integers.
            \\Enter a number (0 -> exit): 
            \\Enter a number (0 -> exit): 
            \\Enter a number (0 -> exit): 
            \\Enter a number (0 -> exit): 
            \\Enter a number (0 -> exit): 
            \\The integer arithmetic mean is 3
            \\
            ,
        },
    };

    const dirname = args.next() orelse {
        try stderr.writeAll(msg.usage);
        try stderr.writeAll(msg.no_filename);
        return;
    };
    const path = std.fs.realpathAlloc(alloc, dirname) catch |err| switch (err) {
        error.FileNotFound => return stderr.print(msg.file_not_found, .{dirname}),
        else => return err,
    };
    defer alloc.free(path);

    var dir = try std.fs.openIterableDirAbsolute(path, .{});
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .File and mem.endsWith(u8, entry.name, ".tny")) {
            try stdout.print("testing file {s}...\n", .{entry.name});
            const filepath = try std.fs.path.join(alloc, &.{ path, entry.name });
            defer alloc.free(filepath);

            for (test_cases) |case, i| {
                try stdout.print("test {d}", .{i});
                if (case.name) |nm| try stdout.print(" ({s})", .{nm});
                try stdout.writeAll(":\n");
                try testOneFile(stdout, case, filepath, alloc);
            }

            try stdout.writeAll("\n");
            count += 1;
        }
    }

    try stdout.print("tested {d} programs\n", .{count});
}

fn testOneFile(
    out: Writer,
    test_case: TestCase,
    filepath: []const u8,
    alloc: Allocator,
) !void {
    const src = blk: {
        var file = try std.fs.openFileAbsolute(filepath, .{});
        const fin = file.reader();
        defer file.close();

        break :blk try fin.readAllAlloc(alloc, 20_000);
    };
    defer alloc.free(src);

    var diagnostic: Diagnostic = undefined;
    diagnostic.filepath = filepath;
    diagnostic.stderr = out;
    diagnostic.use_ansi = false;
    const listing: Listing = tiny.parseListing(src, alloc, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| return diagnostic.printAssemblyErrorMessage(e),
    };
    defer alloc.free(listing);

    var input_buffer = std.io.FixedBufferStream([]const u8){
        .buffer = test_case.input,
        .pos = 0,
    };
    const reader = input_buffer.reader();
    var output_buffer = std.ArrayList(u8).init(alloc);
    defer output_buffer.deinit();
    const writer = output_buffer.writer();

    const MachineT = Machine(std.io.FixedBufferStream([]const u8).Reader, std.ArrayList(u8).Writer);

    var machine = MachineT.init(reader, writer, &diagnostic);
    machine.loadListing(listing);
    machine.run() catch |err| switch (err) {
        error.Stop => unreachable,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
        else => |e| return diagnostic.printRuntimeErrorMessage(MachineT, e, &machine),
    };

    if (!mem.eql(u8, test_case.output, output_buffer.items)) {
        try out.writeAll("test failed: outputs differ\n");
    } else {
        try out.writeAll("test passed: outputs matched\n");
    }
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

    // Runtime warnings and errors
    pub const cannot_decode = "cannot decode word {d} into an instruction at address {d}";
    pub const divide_by_zero = "divide by zero";
    pub const end_of_stream = "end of stream";
    pub const unexpected_eof = "unexpected end of file";
    pub const input_integer_too_large = "integer from input too large; truncating to 99999";
    pub const input_integer_too_small = "integer from input too small; truncating to -99999";
    pub const invalid_character = "invalid character";
    pub const invalid_adress = "attempt to read address {d} which does not exist";
};

test "everything compiles" {
    std.testing.refAllDecls(@This());
}
