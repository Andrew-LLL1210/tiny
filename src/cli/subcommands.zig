const std = @import("std");
const tiny = @import("tiny");

const Node = tiny.parse.Node;

pub fn fmt_exe(args: [][]const u8, gpa: Allocator) !void {
    Command.subcommand = .fmt;
    const command = try Command.parse(args);

    const stderr = std.io.getStdErr().writer();
    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);

    var errors = std.ArrayList(tiny.Error).init(gpa);
    defer errors.deinit();

    const nodes = try tiny.parse.parse(gpa, source, true, &errors);
    defer gpa.free(nodes);

    if (errors.items.len > 0) {
        try printErrors(errors.items, gpa, source, command.file_name(), stderr);
        return error.ReportedError;
    }

    const air = try tiny.parse.analyze(gpa, nodes, source, &errors);
    defer air.deinit(gpa);

    var w = std.ArrayList(u8).init(gpa);
    errdefer w.deinit();

    if (errors.items.len > 0) {
        try tiny.parse.renderNodes(nodes, source, w.writer());
    } else {
        try tiny.parse.renderAir(air, source, w.writer());
    }

    const res = try w.toOwnedSlice();
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
    const command = try Command.parse(args);
    const stdout = std.io.getStdOut().writer();
    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);
    var errors = std.ArrayList(tiny.Error).init(gpa);
    defer errors.deinit();

    const nodes = try tiny.parse.parse(gpa, source, false, &errors);
    defer gpa.free(nodes);
    const air = try tiny.parse.analyze(gpa, nodes, source, &errors);
    defer air.deinit(gpa);

    if (errors.items.len > 0) {
        try printErrors(
            errors.items,
            gpa,
            source,
            command.file_name(),
            stdout,
        );
    }
}

pub fn run_exe(args: [][]const u8, gpa: Allocator) !void {
    Command.subcommand = .run;
    const command = try Command.parse(args);
    const file_name = command.file_name();
    const stderr = std.io.getStdErr().writer();

    var errors = std.ArrayList(tiny.Error).init(gpa);
    defer errors.deinit();

    const source = getSource(gpa, command) orelse return;
    defer gpa.free(source);
    const nodes = try tiny.parse.parse(gpa, source, false, &errors);
    defer gpa.free(nodes);

    if (errors.items.len > 0) {
        try printErrors(errors.items, gpa, source, file_name, stderr);
        return;
    }

    const air = try tiny.parse.analyze(gpa, nodes, source, &errors);
    defer air.deinit(gpa);

    var machine, const index_map = tiny.assemble(air);

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    machine.run(stdin, stdout, 1200) catch |err| {
        const node = nodes[
            index_map[machine.ip] orelse {
                try printRunError(
                    err,
                    Node{ .comment = .{ .start = 0, .end = 0 } },
                    gpa,
                    source,
                    file_name,
                    stderr,
                );
                return;
            }
        ];
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

fn printErrors(
    errors: []const tiny.Error,
    gpa: Allocator,
    source: []const u8,
    file_name: []const u8,
    w: anytype,
) !void {
    for (errors) |err| switch (err) {
        .duplicate_label => |spans| {
            const err_line = spans[0].line(source).line;
            const err_pos = spans[0].range(source).start;
            const err_underline = try spans[0].underline(gpa, source);
            defer gpa.free(err_underline);

            const note_line = spans[1].line(source).line;
            const note_pos = spans[1].range(source).start;
            const note_underline = try spans[1].underline(gpa, source);
            defer gpa.free(note_underline);

            try w.print("{s}:{d}:{d}: error: duplicate label\n{s}\n{s}\n" ++
                "{s}:{d}:{d}: note: original label here\n{s}\n{s}\n\n", .{
                file_name,
                err_pos.row + 1,
                err_pos.col + 1,
                err_line,
                err_underline,
                file_name,
                note_pos.row + 1,
                note_pos.col + 1,
                note_line,
                note_underline,
            });
        },
        .builtin_label_redefinition => |span_name| {
            const line = span_name[0].line(source).line;
            const pos = span_name[0].range(source).start;
            const underline = try span_name[0].underline(gpa, source);
            defer gpa.free(underline);

            try w.print("{s}:{d}:{d}: error: redefinition of builtin label {s}\n{s}\n{s}\n\n", .{
                file_name,
                pos.row + 1,
                pos.col + 1,
                @as([]const u8, span_name[1]),
                line,
                underline,
            });
        },
        inline else => |span| {
            _ = @as(Span, span);
            const line = span.line(source).line;
            const pos = span.range(source).start;
            const underline = try span.underline(gpa, source);
            defer gpa.free(underline);

            try w.print("{s}:{d}:{d}: error: {s}\n{s}\n{s}\n\n", .{
                file_name,
                pos.row + 1,
                pos.col + 1,
                @tagName(err),
                line,
                underline,
            });
        },
    };
}

fn printRunError(err: anyerror, node: Node, gpa: Allocator, source: []const u8, file_name: []const u8, w: anytype) !void {
    const line = node.jointSpan().line(source);
    const pos = node.jointSpan().range(source).start;
    const line2 = try gpa.dupe(u8, line.line);
    defer gpa.free(line2);

    for (line2, line.start..) |*char, i| if (char.* != '\t') {
        char.* = if (node.jointSpan().start <= i and i < node.jointSpan().end) '^' else ' ';
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

const Span = tiny.Span;

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

    fn parse(args: [][]const u8) error{ReportedError}!Command {
        var file: ?[]const u8 = null;
        var mode: ?Mode = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "-h") or eql(u8, args[i], "--help")) return fatalHelp();

            if (args[i][0] == '-' and args[i][1] != '-') {
                for (args[i][1..]) |f| switch (f) {
                    else => return fatalWithHelp("unknown option: -{c}\n", .{f}),
                };
            }

            if (std.mem.eql(u8, args[i], "--stdin")) {
                if (mode) |m| switch (m) {
                    .stdin => return fatalWithHelp("--stdin specified more than once", .{}),
                    .file => return fatalWithHelp("--stdin and FILE are incompatible", .{}),
                };
                mode = .stdin;
                continue;
            }

            if (std.mem.startsWith(u8, args[i], "--"))
                return fatalWithHelp("unknown option: {s}\n", .{args[i]});

            if (file != null)
                return fatalWithHelp("unexpected positional argument '{s}'\n", .{args[i]});
            if (mode) |m| switch (m) {
                .stdin => return fatalWithHelp("--stdin and FILE are incompatible", .{}),
                .file => return fatalWithHelp("FILE specified more than once", .{}),
            };

            mode = .file;
            file = args[i];
        }

        const m = mode orelse return fatalWithHelp("no input specified\n", .{});

        return switch (m) {
            .file => .{ .file = file.? },
            .stdin => .stdin,
        };
    }

    fn fatalHelp() error{ReportedError} {
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
        return error.ReportedError;
    }

    fn fatalWithHelp(comptime fmt: []const u8, args: anytype) error{ReportedError} {
        std.debug.print(fmt, args);
        return fatalHelp();
    }
};
fn fatal(comptime fmt: []const u8, args: anytype) error{ReportedError} {
    std.debug.print(fmt, args);
    return error.ReportedError;
}

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
