const std = @import("std");
const report = @import("report.zig");
const parse = @import("parse.zig");
const sema = @import("sema.zig");
const run = @import("run.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const out_color_config = std.io.tty.detectConfig(std.io.getStdOut());
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

    // get command
    // one of "run" or "flow"
    const command = args_it.next() orelse {
        try stderr.writeAll("error: expected command (run, flow)\n");
        return error.IncorrectUsage;
    };

    // get source(s)
    var source_list = std.ArrayList(u8).init(alloc);
    errdefer source_list.deinit();
    var files = std.ArrayList(report.FileData).init(alloc);
    defer files.deinit();
    while (args_it.next()) |file_name| {
        var file = try std.fs.cwd().openFile(file_name, .{});
        const fin = file.reader();
        defer file.close();

        const len = source_list.items.len;
        try fin.readAllArrayList(&source_list, 20_000);
        try source_list.append('\n');
        const contents = source_list.items[len..];
        try files.append(report.FileData.init(
            file_name,
            len,
            std.mem.count(u8, contents, "\n"),
        ));
    }
    const source = try source_list.toOwnedSlice();
    defer alloc.free(source);

    if (files.items.len == 0) {
        try stderr.writeAll("error: expected source files\n");
        return error.IncorrectUsage;
    }

    // prepare Reporter
    var reporter = report.Reporter{
        .out = stderr,
        .files = files.items,
        .source = source,
        .src = source[0..0],
        .options = .{ .color_config = color_config },
    };

    // dispatch command
    if (std.mem.eql(u8, command, "run")) {
        var parser = parse.Parser.init(source);
        const listing = sema.assemble(&parser, alloc, &reporter.src) catch |err|
            return reporter.reportError(err);
        defer alloc.free(listing);

        var machine = run.Machine.load(listing);
        run.runMachine(&machine, stdin, stdout) catch |err| {
            reporter.setSrcByIp(machine.ip, listing);
            return reporter.reportError(err);
        };
    } else if (std.mem.eql(u8, command, "flow")) {
        var parser = parse.Parser.init(source);
        sema.printSkeleton(&parser, stdout, out_color_config, alloc, &reporter.src) catch |err|
            return reporter.reportError(err);
    } else if (std.mem.eql(u8, command, "lex")) {
        var tokens = parse.TokenIterator{ .index = 0, .src = source };

        while (try tokens.next(&reporter.src)) |token| {
            std.debug.print("{s} <{s}>\n", .{ @tagName(token.kind), token.src });
        }
    } else {
        try stderr.print("'{s}' is not a command", .{command});
    }
}

fn readShim(_: void, _: []u8) error{}!usize {
    unreachable;
}

test "hello world" {
    const alloc = std.testing.allocator;
    const source =
        \\jmp main
        \\string: dc 'hello world!\n'
        \\
        \\main:
        \\    lda string
        \\    call printString
        \\    stop
    ;

    var out = std.ArrayList(u8).init(std.testing.allocator);
    const shim = std.io.GenericReader(void, error{}, readShim){ .context = {} };

    var parser = parse.Parser.init(source);
    const listing = sema.assemble(&parser, alloc) catch {
        std.debug.print("{any}", .{parser.nextInstruction()});
        return error.SkipZigTest;
    };
    defer alloc.free(listing);
    var machine = run.Machine.load(listing);
    try run.runMachine(&machine, shim, out.writer());

    try std.testing.expectEqualStrings("hello world!\n", out.items);
}
