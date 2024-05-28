const std = @import("std");
const tiny = @import("tiny");

pub fn run(args: [][]const u8, gpa: Allocator) void {
    const stdout = std.io.getStdOut().writer();

    const command = Command.parse(args);

    const file = std.fs.cwd().openFile(command.file, .{}) catch |err|
        fatal("cannot read file '{s}': {s}\n", .{ command.file, @errorName(err) });
    defer file.close();

    const source = file.reader().readAllAlloc(gpa, tiny.max_read_size) catch |err|
        fatal("cannot read file '{s}': {s}\n", .{ command.file, @errorName(err) });
    defer gpa.free(source);

    var parser = tiny.Parser.init(source);
    var debug_slice: []const u8 = undefined;
    tiny.sema.printFmt(&parser, stdout, &debug_slice) catch |err| switch (err) {
        else => fatal("unhandled error: '{s}'\n", .{@errorName(err)}),
    };
}

const Command = struct {
    file: []const u8,
    semantic_condensing: bool = false,
    rename_labels: bool = false,
    strip_comments: bool = true,
    mode: enum { stdout, inplace } = .stdout,

    fn parse(args: [][]const u8) Command {
        var file: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "-h") or eql(u8, args[i], "--help")) fatalHelp();

            if (args[i][0] == '-' and args[i][1] != '-') {
                for (args[i][1..]) |f| switch (f) {
                    else => fatal("unknown option: -{c}\n", .{f}),
                };
            }

            if (std.mem.startsWith(u8, args[i], "--"))
                fatal("unknown option: {s}\n", .{args[i]});

            if (file != null) fatal("unexpected positional argument '{s}'\n", .{args[i]});
            file = args[i];
        }

        if (file == null) fatal("no file specified\n", .{});
        return .{
            .file = file.?,
        };
    }

    fn fatalHelp() noreturn {
        std.debug.print(
            \\Usage: tiny fmt [OPTIONS] SOURCE_FILE
            \\
            \\Options:
            \\
        , .{});
        std.process.exit(1);
    }
};
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
