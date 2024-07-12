const std = @import("std");
const tiny = @import("tiny");

pub fn run(args: [][]const u8, gpa: Allocator) !void {
    const command = Command.parse(args);
    switch (command) {
        .file => |file_name| {
            const cwd = std.fs.cwd();

            const res: []const u8 = blk: {
                const file = cwd.openFile(file_name, .{ .lock = .shared }) catch |err|
                    return std.debug.print("cannot read file '{s}': {s}\n", .{ file_name, @errorName(err) });
                defer file.close();

                const source = file.reader().readAllAlloc(gpa, tiny.max_read_size) catch |err|
                    return std.debug.print("cannot read file '{s}': {s}\n", .{ file_name, @errorName(err) });
                defer gpa.free(source);

                var parser = tiny.Parser.init(source);

                var out = std.ArrayList(u8).init(gpa);
                errdefer out.deinit();

                var debug_slice: []const u8 = undefined;
                tiny.sema.printFmt(&parser, out.writer(), &debug_slice) catch |err| switch (err) {
                    else => {
                        std.debug.print("unhandled error: '{s}'\n", .{@errorName(err)});
                        return;
                    },
                };

                break :blk try out.toOwnedSlice();
            };

            var atomic_file = try cwd.atomicFile(file_name, .{});
            defer atomic_file.deinit();

            try atomic_file.file.writeAll(res);
            try atomic_file.finish();
        },
        .stdin => {
            const stdin = std.io.getStdIn().reader();
            const stdout = std.io.getStdOut().writer();

            const source = stdin.readAllAlloc(gpa, tiny.max_read_size) catch |err|
                return std.debug.print("error reading from stdin: '{s}'\n", .{@errorName(err)});
            defer gpa.free(source);

            var out = std.ArrayList(u8).init(gpa);
            defer out.deinit();
            var parser = tiny.Parser.init(source);
            var debug_slice: []const u8 = undefined;
            tiny.sema.printFmt(&parser, stdout, &debug_slice) catch |err| switch (err) {
                else => {
                    std.debug.print("unhandled error: {s}\n", .{@errorName(err)});
                    return;
                },
            };

            try stdout.writeAll(out.items);
        },
    }
}

const Mode = enum { file, stdin };
const Command = union(Mode) {
    file: []const u8,
    stdin: void,

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
            \\Usage: tiny fmt (-h|--stdin|FILE)
            \\
            \\
        , .{});
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
