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
    file_in: ?[]const u8,
    file_out: ?[]const u8,
    file_err: ?[]const u8,
    file_prepend: ?[]const u8,
    max_steps: ?usize,

    fn parse(args: [][]const u8) Command {
        var file: ?[]const u8 = null;
        var file_in: ?[]const u8 = null;
        var file_out: ?[]const u8 = null;
        var file_err: ?[]const u8 = null;
        var file_prepend: ?[]const u8 = null;
        var max_steps: ?usize = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "-h") or eql(u8, args[i], "--help")) fatalHelp();

            if (optionMatches(args[i], "in", 'i')) {
                if (file_in != null) fatal("{s} specified multiple times\n", .{args[i]});
                i += 1;
                if (i == args.len) fatal("{s} requires a FILE argument\n", .{args[i]});
                file_in = args[i];
                continue;
            }

            if (optionMatches(args[i], "out", 'o')) {
                if (file_prepend != null) fatal("{s} specified multiple times\n", .{args[i]});
                i += 1;
                if (i == args.len) fatal("{s} requires a FILE argument\n", .{args[i]});
                file_out = args[i];
                continue;
            }

            if (optionMatches(args[i], "err", 'e')) {
                if (file_err != null) fatal("{s} specified multiple times\n", .{args[i]});
                i += 1;
                if (i == args.len) fatal("{s} requires a FILE argument\n", .{args[i]});
                file_err = args[i];
                continue;
            }

            if (optionMatches(args[i], "prepend", 'p')) {
                if (file_prepend != null) fatal("{s} specified multiple times\n", .{args[i]});
                i += 1;
                if (i == args.len) fatal("{s} requires a FILE argument\n", .{args[i]});
                file_prepend = args[i];
                continue;
            }

            if (optionMatches(args[i], "max-steps", null)) {
                if (max_steps != null) fatal("{s} specified multiple times\n", .{args[i]});
                i += 1;
                if (i == args.len) fatal("{s} requires a FILE argument\n", .{args[i]});
                max_steps = std.fmt.parseInt(usize, args[i], 10) catch |err|
                    fatal("{s}: --max-steps expects a usize integer\n", .{@errorName(err)});
                continue;
            }

            if (std.mem.startsWith(u8, args[i], "-"))
                fatal("unknown option: {s}\n", .{args[i]});

            if (file != null) fatal("unexpected positional argument '{s}'\n", .{args[i]});
            file = args[i];
        }

        if (file == null) fatal("no file specified\n", .{});
        return .{
            .file = file.?,
            .file_in = file_in,
            .file_out = file_out,
            .file_err = file_err,
            .file_prepend = file_prepend,
            .max_steps = max_steps,
        };
    }

    fn optionMatches(arg: []const u8, long: []const u8, short: ?u8) bool {
        return if (std.mem.startsWith(u8, arg, "--"))
            std.mem.eql(u8, arg[2..], long)
        else
            (short != null and arg.len == 2 and arg[0] == '-' and arg[1] == short.?);
    }

    fn fatalHelp() noreturn {
        std.debug.print(
            \\Usage: tiny run [OPTIONS] SOURCE_FILE
            \\
            \\Options:
            \\  -e, --error FILE
            \\      file to write any errors to.
            \\  -i, --in FILE
            \\      file to read input from during evaluation.
            \\  --max-steps N
            \\      the maximum number of steps to evaluate.
            \\      if execution surpasses this, a MaxStepsExceeded is thrown.
            \\  -o, --out FILE
            \\      file to write output to during evaluation.
            \\  -p, --prepend FILE
            \\      file to prepend to the main file for parsing.
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
