const std = @import("std");
const tiny = @import("tiny");

const Node = tiny.parse.Ast.Node;

pub fn fmt_exe(args: [][]const u8, gpa: Allocator) !void {
    Command.subcommand = .fmt;
    const command = Command.parse(args);
    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);
    const res = try formatSource(gpa, source);
    defer gpa.free(res);

    switch (command) {
        .file => |file_name| {
            const cwd = std.fs.cwd();

            var atomic_file = try cwd.atomicFile(file_name, .{});
            defer atomic_file.deinit();

            try atomic_file.file.writeAll(res);
            try atomic_file.finish();
        },
        .stdin => {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(res);
        },
    }
}

pub fn check_exe(args: [][]const u8, gpa: Allocator) !void {
    Command.subcommand = .check;
    const command = Command.parse(args);
    const stdout = std.io.getStdOut().writer();
    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);

    const ast = try tiny.Ast.init(gpa, source, false);
    defer gpa.free(ast.nodes);
    defer gpa.free(ast.errors);

    try printErrors(
        ast,
        gpa,
        source,
        command.file_name(),
        stdout,
    );
}

pub fn run_exe(args: [][]const u8, gpa: Allocator) !void {
    Command.subcommand = .run;
    const command = Command.parse(args);
    const file_name = command.file_name();
    const stderr = std.io.getStdErr().writer();

    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);
    const ast = try tiny.Ast.init(gpa, source, false);
    defer gpa.free(ast.nodes);
    defer gpa.free(ast.errors);

    if (ast.errors.len > 0) {
        try printErrors(ast, gpa, source, file_name, stderr);
        return;
    }

    var assembly = try tiny.sema.assemble(gpa, ast, source);
    defer assembly.deinit(gpa);

    //for (assembly.listing, 0..) |word, idx| {
    //std.debug.print("{d:0>3} {?d: >6}\n", .{ idx, word });
    //}

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var machine = tiny.run.Machine.load(assembly.listing);
    tiny.run.runMachine(&machine, stdin, stdout) catch |err| {
        if (machine.ip >= assembly.index_map.len) {
            try stderr.print("{s}: error: {s}\n\n", .{ file_name, @errorName(err) });
            return;
        }
        const node = ast.nodes[assembly.index_map[machine.ip] orelse 0];
        try printRunError(err, node, gpa, source, file_name, stderr);
    };
}

fn getSource(gpa: Allocator, command: Command) ?[]const u8 {
    switch (command) {
        .file => |file_name| {
            const cwd = std.fs.cwd();

            const file = cwd.openFile(file_name, .{}) catch |err| {
                std.debug.print("cannot read file '{s}': {s}\n", .{ file_name, @errorName(err) });
                return null;
            };

            defer file.close();

            const source = file.readToEndAlloc(gpa, tiny.max_read_size) catch |err| {
                std.debug.print("cannot read file '{s}': {s}\n", .{ file_name, @errorName(err) });
                return null;
            };

            return source;
        },
        .stdin => {
            const stdin = std.io.getStdIn().reader();

            const source = stdin.readAllAlloc(gpa, tiny.max_read_size) catch |err| {
                std.debug.print("error reading from stdin: '{s}'\n", .{@errorName(err)});
                return null;
            };

            return source;
        },
    }
}

/// caller owns returned memory
fn formatSource(gpa: std.mem.Allocator, source: []const u8) ![]const u8 {
    const ast = try tiny.Ast.init(gpa, source, true);
    defer gpa.free(ast.nodes);
    defer gpa.free(ast.errors);

    var w = std.ArrayList(u8).init(gpa);
    errdefer w.deinit();

    try ast.render(source, w.writer());
    return try w.toOwnedSlice();
}

fn printErrors(ast: tiny.Ast, gpa: Allocator, source: []const u8, file_name: []const u8, w: anytype) !void {
    for (ast.errors) |err| {
        const line = err.span.line(source);
        const pos = err.span.range(source).start;
        const line2 = try gpa.dupe(u8, line.line);
        defer gpa.free(line2);

        for (line2, line.start..) |*char, i| if (char.* != '\t') {
            char.* = if (err.span.start <= i and i < err.span.end) '^' else ' ';
        };

        try w.print("{s}:{d}:{d}: error: {s}\n{s}\n{s}\n\n", .{
            file_name,
            pos.row + 1,
            pos.col + 1,
            @tagName(err.tag),
            line.line,
            line2,
        });
    }
}

fn printRunError(err: anyerror, node: Node, gpa: Allocator, source: []const u8, file_name: []const u8, w: anytype) !void {
    const line = node.span().line(source);
    const pos = node.span().range(source).start;
    const line2 = try gpa.dupe(u8, line.line);
    defer gpa.free(line2);

    for (line2, line.start..) |*char, i| if (char.* != '\t') {
        char.* = if (node.span().start <= i and i < node.span().end) '^' else ' ';
    };

    try w.print("{s}:{d}:{d}: error: {s}\n{s}\n{s}\n\n", .{
        file_name,
        pos.row + 1,
        pos.col + 1,
        @errorName(err),
        line.line,
        line2,
    });
}

const Mode = enum { file, stdin };
const Command = union(Mode) {
    var subcommand: enum { fmt, check, run } = undefined;

    file: []const u8,
    stdin: void,

    fn file_name(command: Command) []const u8 {
        return switch (command) {
            .file => |name| name,
            .stdin => "stdin",
        };
    }

    fn parse(args: [][]const u8) Command {
        var file: ?[]const u8 = null;
        var mode: ?Mode = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "-h") or eql(u8, args[i], "--help")) fatalHelp();

            if (args[i][0] == '-' and args[i][1] != '-') {
                for (args[i][1..]) |f| switch (f) {
                    else => fatalWithHelp("unknown option: -{c}\n", .{f}),
                };
            }

            if (std.mem.eql(u8, args[i], "--stdin")) {
                if (mode) |m| switch (m) {
                    .stdin => fatalWithHelp("--stdin specified more than once", .{}),
                    .file => fatalWithHelp("--stdin and FILE are incompatible", .{}),
                };
                mode = .stdin;
                continue;
            }

            if (std.mem.startsWith(u8, args[i], "--"))
                fatalWithHelp("unknown option: {s}\n", .{args[i]});

            if (file != null) fatalWithHelp("unexpected positional argument '{s}'\n", .{args[i]});
            if (mode) |m| switch (m) {
                .stdin => fatalWithHelp("--stdin and FILE are incompatible", .{}),
                .file => fatalWithHelp("FILE specified more than once", .{}),
            };

            mode = .file;
            file = args[i];
        }

        const m = mode orelse fatalWithHelp("no input specified\n", .{});

        return switch (m) {
            .file => .{ .file = file.? },
            .stdin => .stdin,
        };
    }

    fn fatalHelp() noreturn {
        std.debug.print(
            \\
            \\Usage: tiny {s} [OPTIONS] (--stdin | FILE)
            \\
            \\Options:
            \\  -p FILE,
            \\  --prepend FILE    TODO
            \\  -h,
            \\  --help            Display this message
            \\
            \\
        , .{@tagName(Command.subcommand)});
        std.process.exit(1);
    }

    fn fatalWithHelp(comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print(fmt, args);
        fatalHelp();
    }
};
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
