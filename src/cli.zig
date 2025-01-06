const std = @import("std");
const tiny = @import("tiny");
const lsp = @import("cli/lsp.zig");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_impl.deinit() == .ok);
    const gpa = gpa_impl.allocator();
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const stderr = std.io.getStdErr().writer();

    const positional, const options = try eatArgs(&args, gpa, stderr);
    defer gpa.free(positional);

    dispatch(gpa, positional, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try stderr.print(
            "error: {s} while dispatching subcommand\n",
            .{@errorName(err)},
        ),
    };
}

// TODO find better name
pub fn dispatch(
    gpa: Allocator,
    positional: []const []const u8,
    options: Option.Struct(),
) !void {
    if (positional.len == 0) return error.no_subcommand;

    const subcommand = meta.stringToEnum(Subcommand, positional[0]) orelse
        return error.invalid_subcommand;

    if (options.help or subcommand == .help)
        fatalHelp();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = ColorPrinter.fromFile(std.io.getStdErr());

    const cwd = std.fs.cwd();
    const max_bytes = 2048 * 10;
    switch (subcommand) {
        .run, .check, .flow, .fmt => {
            var list = std.ArrayList(u8).init(gpa);
            defer list.deinit();

            var namer: FileNamer = undefined;

            if (options.prepend) |path| {
                namer.name_1 = path;
                if (subcommand == .fmt) return error.invalid_prepend;
                const file = try std.fs.cwd().openFile(path, .{ .lock = .shared });
                defer file.close();
                try file.reader().readAllArrayList(&list, max_bytes);
            }

            namer.len_1 = list.items.len;

            if (options.stdin) {
                namer.name_2 = "[stdin]";
                try stdin.readAllArrayList(&list, max_bytes);
            } else {
                if (positional.len == 1) return error.expected_positional_filepath;
                const path = positional[1];
                namer.name_2 = path;
                const file = try std.fs.cwd().openFile(path, .{ .lock = .shared });
                defer file.close();
                try file.reader().readAllArrayList(&list, max_bytes);
            }

            const src = list.items;

            const fmt_fout = if (options.stdout or positional.len == 1)
                std.io.getStdOut()
            else
                try cwd.openFile(options.out orelse positional[1], .{});
            defer if (!options.stdout and positional.len != 1) fmt_fout.close();

            const want_comments = subcommand == .fmt and !(options.@"strip-comments" orelse false);

            var errors = std.ArrayList(tiny.parse.Error).init(gpa);
            defer errors.deinit();
            const nodes = try tiny.parse.parse(gpa, src, want_comments, &errors);
            defer gpa.free(nodes);
            if (errors.items.len > 0) {
                try printErrors(errors.items, gpa, src, namer, stderr);
                return;
            }

            const air = try tiny.parse.analyze(gpa, nodes, src, &errors);
            defer air.deinit(gpa);
            if (errors.items.len > 0) if (subcommand == .fmt) {
                try tiny.parse.renderNodes(nodes, src, fmt_fout.writer());
                return;
            } else {
                try printErrors(errors.items, gpa, src, namer, stderr);
                return;
            };

            if (subcommand == .fmt) {
                try tiny.parse.renderAir(air, src, fmt_fout.writer());
                return;
            }

            if (subcommand == .check) return;
            if (subcommand == .flow) {
                const fout: std.fs.File = if (options.out) |fp|
                    try std.fs.cwd().createFile(fp, .{
                        .lock = .exclusive,
                    })
                else
                    std.io.getStdOut();
                defer if (options.out != null) fout.close();
                const use_color = options.color orelse true;
                try tiny.printFlow(air, src, fout, use_color, gpa);
                return;
            }

            var machine, const index_map = tiny.assemble(air);
            const max_cycles = 300;
            machine.run(stdin, stdout, max_cycles) catch |err| {
                try printRunError(err, nodes[index_map[machine.ip] orelse 0], gpa, src, namer, stderr);
            };
        },
        .lsp => {
            try lsp.run(gpa);
        },
        .help => unreachable,
    }
}

fn printErrors(
    errors: []const tiny.Error,
    gpa: Allocator,
    source: []const u8,
    namer: FileNamer,
    w: ColorPrinter,
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

            try w.print(
                \\{bright_black}{s}:{d}:{d}: {bright_red}error: {bright_white}duplicate label{reset}
                \\{s}
                \\{red}{s}{reset}
                \\{bright_black}{s}:{d}:{d}: {bright_green}note: {bright_white}original label here{reset}
                \\{s}
                \\{green}{s}{reset}
                \\
                \\
            , .{
                namer.nameSpan(spans[0]),
                err_pos.row + 1,
                err_pos.col + 1,
                err_line,
                err_underline,
                namer.nameSpan(spans[1]),
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

            try w.print(
                \\{bright_black}{s}:{d}:{d}: {bright_red}error: {bright_white}redefinition of builtin label {s}{reset}
                \\{s}
                \\{red}{s}{reset}
                \\
                \\
            , .{
                namer.nameSpan(span_name[0]),
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

            try w.print(
                \\{bright_black}{s}:{d}:{d}: {bright_red}error: {bright_white}{s}{reset}
                \\{s}
                \\{red}{s}{reset}
                \\
                \\
            , .{
                namer.nameSpan(span),
                pos.row + 1,
                pos.col + 1,
                @tagName(err),
                line,
                underline,
            });
        },
    };
}

const ColorPrinter = struct {
    writer: std.fs.File.Writer,
    config: std.io.tty.Config,

    fn fromFile(file: std.fs.File) ColorPrinter {
        return .{ .writer = file.writer(), .config = std.io.tty.detectConfig(file) };
    }

    fn print(printer: ColorPrinter, comptime fmt: []const u8, args: anytype) !void {
        // for some arcane reason this wasn't working my way
        // so i'm just ripping std.fmt.format
        @setEvalBranchQuota(20000);
        comptime var ix = 0;
        comptime var arg_ix = 0;
        inline while (ix < fmt.len) : (ix += 1) {
            const start = ix;

            inline while (ix < fmt.len) : (ix += 1)
                if (fmt[ix] == '{') break;

            comptime var end = ix;
            comptime var unescape_brace = false;

            if (ix + 1 < fmt.len and fmt[ix + 1] == '{') {
                unescape_brace = true;
                end += 1;
                ix += 2;
            }
            if (start != end)
                try printer.writer.writeAll(fmt[start..end]);

            if (unescape_brace) continue;
            if (ix >= fmt.len) break;

            comptime std.debug.assert(fmt[ix] == '{');
            ix += 1;

            const fmt_begin = ix;
            inline while (ix < fmt.len and fmt[ix] != '}') : (ix += 1) {}
            const fmt_end = ix;
            if (ix >= fmt.len)
                @compileError("missing closing }");

            if (comptime meta.stringToEnum(std.io.tty.Color, fmt[fmt_begin..fmt_end])) |color| {
                try printer.config.setColor(printer.writer, color);
            } else {
                try printer.writer.print(fmt[fmt_begin - 1 .. fmt_end + 1], .{args[arg_ix]});
                arg_ix += 1;
            }
        }
    }
};

const Node = tiny.Node;
fn printRunError(
    err: anyerror,
    node: Node,
    gpa: Allocator,
    source: []const u8,
    namer: FileNamer,
    w: ColorPrinter,
) !void {
    const line = node.jointSpan().line(source);
    const pos = node.jointSpan().range(source).start;
    const line2 = try gpa.dupe(u8, line.line);
    defer gpa.free(line2);

    for (line2, line.start..) |*char, i| if (char.* != '\t') {
        char.* = if (node.jointSpan().start <= i and i < node.jointSpan().end) '^' else ' ';
    };

    try w.print(
        \\{bright_black}{s}:{d}:{d}: {bright_red}error: {bright_white}{s}{reset}
        \\{s}
        \\{red}{s}{reset}
        \\
        \\
    , .{
        namer.nameSpan(node.jointSpan()),
        pos.row + 1,
        pos.col + 1,
        @errorName(err),
        line.line,
        line2,
    });
}

const Span = tiny.Span;

const FileNamer = struct {
    name_1: []const u8,
    len_1: usize,
    name_2: []const u8,

    fn nameSpan(x: FileNamer, span: Span) []const u8 {
        return if (span.start < x.len_1) x.name_1 else x.name_2;
    }
};

const Subcommand = std.meta.FieldEnum(@FieldType(Command, "subcommand"));

pub const Command = struct {
    subcommand: union(enum) {
        run: struct {
            file: FilePath,
            prepend: ?FilePath,
        },
        fmt: struct {
            file: FilePath,
            out: FilePath,
            strip_comments: bool,
        },
        check: struct {
            file: FilePath,
        },
        flow: struct {
            file: FilePath = .stdio,
        },
        lsp,
        help,
    },
    color: enum { yes, no, auto } = .auto,

    const FilePath = union(enum) { path: []const u8, stdio };
};

const ArgPack = struct { []const []const u8, Option.Struct() };

fn eatArgs(
    args: *std.process.ArgIterator,
    gpa: std.mem.Allocator,
    err: std.fs.File.Writer, // TODO update to colored writer
) (std.mem.Allocator.Error || std.fs.File.WriteError)!ArgPack {
    var positional = std.ArrayList([]const u8).init(gpa);
    errdefer positional.deinit();
    var options = Option.Struct(){};

    while (args.next()) |arg| {
        // positional arg
        if (arg.len > 0 and arg[0] != '-') {
            try positional.append(arg);
            continue;
        }

        // option or flag
        const option_name = Option.parseNameFromArgument(arg) catch |e| {
            try err.print(
                \\error: {s} while parsing argument `{s}`
                \\note: use `tiny help` for usage help.
                \\
            , .{ @errorName(e), arg });
            std.process.exit(1);
        };

        switch (Option.at(option_name).kind) {
            .option => {
                const value: ?[]const u8 =
                    args.next() orelse {
                    try err.print(
                        "error: `{s}` requires a(n) {s}\n",
                        .{ arg, Option.at(option_name).argument_name },
                    );
                    std.process.exit(1);
                };
                Option.set(&options, option_name, value);
            },
            .flag => {
                Option.set(&options, option_name, true);
            },
            .no_flag => {
                const value: ?bool = !mem.startsWith(u8, arg, "--no-");
                Option.set(&options, option_name, value);
            },
        }
    }

    const positional_list = try positional.toOwnedSlice();
    return .{ positional_list, options };
}

const OptionName = std.meta.DeclEnum(Option.values);
const Option = struct {
    short: ?u8 = null,
    kind: enum { option, flag, no_flag },
    argument_name: []const u8 = "FILE", // only used for options

    const values = struct {
        pub const out = Option{ .kind = .option, .short = 'o' };
        pub const @"strip-comments" = Option{ .kind = .no_flag };
        pub const color = Option{ .kind = .no_flag };
        pub const prepend = Option{ .kind = .option, .short = 'p' };
        pub const help = Option{ .kind = .flag, .short = 'h' };
        pub const stdin = Option{ .kind = .flag };
        pub const stdout = Option{ .kind = .flag };
    };

    fn printHelpLine(name: OptionName, out: std.fs.File.Writer) std.fs.File.WriteError!void {
        const width: usize = 15;
        const ws = std.fmt.comptimePrint("{d}", .{width});
        const wl5s = std.fmt.comptimePrint("{d}", .{width - 5});
        const data = Option.at(name);

        if (data.short) |c| try out.print("  -{c}, ", .{c}) else try out.writeAll(" " ** 6);

        switch (data.kind) {
            .option => {
                try out.print("--{s} {s}", .{ @tagName(name), data.argument_name });
                try out.writeByteNTimes(
                    ' ',
                    width -| (@tagName(name).len + data.argument_name.len + 1) + 1,
                );
            },
            .flag => try out.print("--{s: <" ++ ws ++ "} ", .{@tagName(name)}),
            .no_flag => try out.print("--(no-){s: <" ++ wl5s ++ "} ", .{@tagName(name)}),
        }

        try out.writeAll(description(OptionName, name));
        try out.writeByte('\n');
    }

    fn at(name: OptionName) Option {
        return switch (name) {
            inline else => |n| @field(values, @tagName(n)),
        };
    }

    fn set(options: *Struct(), name: OptionName, value: anytype) void {
        switch (name) {
            inline else => |n| {
                // TODO this is so janky. type has to be exact match at call site
                // without this check it will look at _every_ field of options
                // idk why it would do that though. It should only analyze
                if (@TypeOf(value) == @TypeOf(@field(options, @tagName(n))))
                    @field(options, @tagName(n)) = value;
            },
        }
    }

    fn Struct() type {
        comptime var fields: [meta.tags(OptionName).len]Type.StructField = undefined;
        inline for (meta.tags(OptionName), &fields) |name, *field| {
            const T = switch (Option.at(name).kind) {
                .option => ?[]const u8,
                .flag => bool,
                .no_flag => ?bool,
            };
            const default: T = switch (Option.at(name).kind) {
                .option => null,
                .flag => false,
                .no_flag => null,
            };

            field.* = .{
                .name = @tagName(name),
                .type = T,
                .default_value = &default,
                .alignment = @alignOf(T),
                .is_comptime = false,
            };
        }

        return @Type(.{ .@"struct" = .{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }

    const ParseNameError = error{
        is_null,
        is_positional,
        is_malformed,
        short_has_trailing_data,
        invalid_short,
        invalid_option_name,
        invalid_no_flag,
    };

    fn parseNameFromArgument(arg: []const u8) ParseNameError!OptionName {
        if (arg.len == 0) return error.is_null;
        if (arg[0] != '-') return error.is_positional;
        if (arg.len == 1) return error.is_malformed;
        if (arg[1] != '-') {
            if (arg.len > 2) return error.short_has_trailing_data;
            inline for (std.meta.tags(OptionName)) |name|
                if (Option.at(name).short == arg[1]) return name;
            return error.invalid_short;
        }

        const is_no_flag = std.mem.startsWith(u8, arg, "--no-");
        const string = if (is_no_flag) arg[5..] else arg[2..];
        const name = std.meta.stringToEnum(OptionName, string) orelse
            return error.invalid_option_name;
        if (is_no_flag and Option.at(name).kind != .no_flag)
            return error.invalid_no_flag;
        return name;
    }
};

fn fatalHelp() noreturn {
    std.debug.print("Usage: tiny COMMAND [OPTIONS]\n\nCommands:\n", .{});

    inline for (std.meta.fields(Subcommand)) |field| {
        std.debug.print("  {s: <11} {s}\n", .{
            field.name,
            description(Subcommand, @enumFromInt(field.value)),
        });
    }

    std.debug.print("\nGeneral Options:\n", .{});

    for (std.meta.tags(OptionName)) |name| {
        Option.printHelpLine(name, std.io.getStdErr().writer()) catch unreachable;
    }

    std.debug.print("\n", .{});
    std.process.exit(0); // TODO should this be 0 or 1? or a parameter?
}

fn description(comptime Enum: type, v: Enum) []const u8 {
    if (Enum == Subcommand) return switch (v) {
        .run => "Interpret a tiny program",
        .fmt => "Format a tiny program",
        .check => "Check tiny program for syntax errors",
        .flow => "Print and colorize control flow in a Tiny program",
        .lsp => "Start the LSP",
        .help => "Show this menu and exit",
    };

    if (Enum == OptionName) return switch (v) {
        .out => "File to send output to",
        .@"strip-comments" => "Whether or not to remove comments while formatting",
        .color => "Whether to emit color codes",
        .prepend => "File to optionally prepend to the program before interpreting",
        .help => "Print this help menu",
        .stdin => "Take Tiny program from stdin instead of specifying a file",
        .stdout => "write formatted program to stdout",
    };

    @compileError("no descriptions exist for enum " ++ @typeName(Enum));
}

const meta = std.meta;
const mem = std.mem;
const File = std.fs.File;
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;
