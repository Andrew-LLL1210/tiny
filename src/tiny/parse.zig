const std = @import("std");
const lib = @import("span.zig");
const Tokenizer = @import("Tokenizer.zig");
const run = @import("run.zig");

const Span = lib.Span;
const Token = Tokenizer.Token;
const Machine = run.Machine;
const Word = run.Word;
const Arg = Word;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = @import("insensitive.zig").HashMap;

pub const Air = struct {
    statements: []const Statement,
    labels: []const LabelData,
    strings: []const []const u8,
    spans: []const Span,

    pub fn deinit(air: Air, gpa: Allocator) void {
        gpa.free(air.statements);
        gpa.free(air.labels);
        for (air.strings) |string| gpa.free(string);
        gpa.free(air.strings);
        gpa.free(air.spans);
    }
};

pub const Statement = union(enum) {
    comment: Span,
    mark_label: usize,
    operation: struct { Mnemonic, union(enum) { label: usize, number: Arg, none: void } },
    directive: union(enum) { dc: usize, db: Word, ds: usize },
};

pub const LabelData = union(enum) {
    canonical_name: Span,
    builtin_name: []const u8,
    temporary_name: Span,

    pub fn name(label_data: LabelData, source: []const u8) []const u8 {
        return switch (label_data) {
            .canonical_name => |span| span.slice(source),
            .builtin_name => |slice| slice,
            .temporary_name => |span| span.slice(source),
        };
    }
};

pub fn analyze(
    gpa: Allocator,
    nodes: []const Node,
    source: []const u8,
    errors: *ArrayList(Error),
) Allocator.Error!Air {
    var statements = ArrayList(Statement).init(gpa);
    var labels = ArrayList(LabelData).init(gpa);
    var label_indices = HashMap(usize).init(gpa);
    var strings = ArrayList([]const u8).init(gpa);
    var spans_list = ArrayList(Span).init(gpa);
    defer label_indices.deinit();

    errdefer {
        statements.deinit();
        labels.deinit();
        strings.deinit();
        spans_list.deinit();
    }

    inline for (.{ "printInteger", "inputInteger", "printString", "inputString" }, 0..) |name, idx| {
        try labels.append(.{ .builtin_name = name });
        try label_indices.putNoClobber(name, idx);
    }

    for (nodes) |node| {
        switch (node) {
            .comment => |span| try statements.append(.{ .comment = span }),
            .label => |spans| {
                const gop = try label_indices.getOrPut(spans[0].slice(source));
                if (!gop.found_existing) {
                    gop.value_ptr.* = labels.items.len;
                    try labels.append(.{ .canonical_name = spans[0] });
                    try statements.append(.{ .mark_label = gop.value_ptr.* });
                } else switch (labels.items[gop.value_ptr.*]) {
                    .canonical_name => |canon| try errors.append(.{
                        .duplicate_label = .{ spans[0], canon },
                    }),
                    .builtin_name => |builtin| try errors.append(.{
                        .builtin_label_redefinition = .{ spans[0], builtin },
                    }),
                    .temporary_name => {
                        labels.items[gop.value_ptr.*] = .{ .canonical_name = spans[0] };
                        try statements.append(.{ .mark_label = gop.value_ptr.* });
                    },
                }
            },
            .op_label => |spans| blk: {
                const mnemonic = mnemonic_map.get(spans[0].slice(source)) orelse {
                    try errors.append(.{ .invalid_mnemonic = spans[0] });
                    break :blk;
                };

                switch (mnemonic) {
                    .stop, .in, .out, .ret, .ldparam => {
                        try errors.append(.{ .invalid_argument = node.jointSpan() });
                        break :blk;
                    },
                    else => {},
                }

                const gop = try label_indices.getOrPut(spans[1].slice(source));
                if (!gop.found_existing) {
                    gop.value_ptr.* = labels.items.len;
                    try labels.append(.{ .temporary_name = spans[1] });
                }

                try statements.append(.{ .operation = .{ mnemonic, .{ .label = gop.value_ptr.* } } });
            },
            .op_single => |span| blk: {
                const mnemonic = mnemonic_map.get(span.slice(source)) orelse {
                    try errors.append(.{ .invalid_mnemonic = span });
                    break :blk;
                };

                switch (mnemonic) {
                    .stop, .in, .out, .ret, .push, .pop => {},
                    else => {
                        try errors.append(.{ .invalid_argument = node.jointSpan() });
                        break :blk;
                    },
                }

                try statements.append(.{ .operation = .{ mnemonic, .none } });
            },
            .op_number => |spans| blk: {
                const number = std.fmt.parseInt(i32, (spans[1].slice(source)), 10) catch unreachable;
                if (std.ascii.eqlIgnoreCase(spans[0].slice(source), "ds")) {
                    if (number <= 0) {
                        try errors.append(.{ .invalid_number_range = spans[1] });
                    } else {
                        try statements.append(.{ .directive = .{ .ds = @intCast(number) } });
                    }
                    break :blk;
                } else if (std.ascii.eqlIgnoreCase(spans[0].slice(source), "db")) {
                    if (number < -99999 or number > 99999) {
                        try errors.append(.{ .invalid_number_range = spans[1] });
                    } else {
                        try statements.append(.{ .directive = .{ .db = number } });
                    }
                    break :blk;
                }

                const mnemonic = mnemonic_map.get(spans[0].slice(source)) orelse {
                    try errors.append(.{ .invalid_mnemonic = spans[0] });
                    break :blk;
                };

                switch (mnemonic) {
                    .ld, .add, .sub, .mul, .div, .ldparam => {},
                    else => {
                        try errors.append(.{ .invalid_argument = node.jointSpan() });
                        break :blk;
                    },
                }

                if (number < 0 or number > 999) {
                    try errors.append(.{ .invalid_number_range = spans[1] });
                    break :blk;
                }

                try statements.append(.{ .operation = .{ mnemonic, .{ .number = 0 } } });
            },
            .op_string => |spans| {
                if (!std.ascii.eqlIgnoreCase(spans[0].slice(source), "dc")) {
                    try errors.append(.{ .unexpected_string = spans[1] });
                }

                var string = ArrayList(u8).init(gpa);
                errdefer string.deinit();

                try statements.append(.{ .directive = .{ .dc = strings.items.len } });
                var i: usize = 1;
                const slice = spans[1].slice(source);
                while (i < slice.len - 1) : (i += 1) switch (slice[i]) {
                    '\\' => {
                        i += 1;
                        switch (slice[i]) {
                            'n' => try string.append('\n'),
                            'r' => try string.append('\r'),
                            't' => try string.append('\t'),
                            '\\', '\'', '"' => |char| try string.append(char),
                            else => |char| {
                                try string.append('\\');
                                try string.append(char);
                                try errors.append(.{
                                    .invalid_escape_code = .{ .start = i - 1, .end = i + 1 },
                                });
                            },
                        }
                    },
                    else => |char| try string.append(char),
                };

                try strings.append(try string.toOwnedSlice());
            },
        }

        if (spans_list.items.len != statements.items.len) {
            std.debug.assert(statements.items.len == 1 + spans_list.items.len);
            try spans_list.append(node.jointSpan());
        }
    }

    std.debug.assert(statements.items.len == spans_list.items.len);

    for (labels.items) |label_data| if (label_data == .temporary_name) {
        try errors.append(.{ .unknown_label = label_data.temporary_name });
    };

    return .{
        .statements = try statements.toOwnedSlice(),
        .labels = try labels.toOwnedSlice(),
        .strings = try strings.toOwnedSlice(),
        .spans = try spans_list.toOwnedSlice(),
    };
}

pub const Error = union(enum) {
    // thrown by the tokenizer
    illegal_character: Span,
    illegal_identifier_character: Span,
    illegal_number_character: Span,
    unrecognized_escape_sequence: Span,
    number_literal_too_large: Span,
    unclosed_string: Span,

    // thrown by the parser
    blank_label: Span,
    argument_without_op: Span,
    expected_eol: Span,

    // thrown by the analyzer
    duplicate_label: [2]Span,
    builtin_label_redefinition: struct { Span, []const u8 },
    invalid_mnemonic: Span,
    invalid_escape_code: Span,
    invalid_argument: Span,
    expected_argument: Span,
    invalid_number_range: Span,
    unexpected_string: Span,
    unknown_label: Span,
};

pub fn parse(
    gpa: Allocator,
    source: []const u8,
    want_comments: bool,
    errors: *ArrayList(Error),
) Allocator.Error![]const Node {
    var tokenizer: Tokenizer = .{ .want_comments = want_comments };

    var nodes = std.ArrayList(Node).init(gpa);
    errdefer nodes.deinit();

    while (tokenizer.next(source)) |token| switch (token) {
        .newline => {},
        .parse_error => |err| try errors.append(err),
        .comment => try nodes.append(.{ .comment = token.span() }),
        .number, .string => try errors.append(.{
            .argument_without_op = token.span(),
        }),
        .colon => try errors.append(.{
            .blank_label = token.span(),
        }),
        .identifier => {
            const token2 = tokenizer.next(source) orelse tokenizer.newline();
            switch (token2) {
                .parse_error => |err| try errors.append(err),
                .newline, .comment => {
                    try nodes.append(.{ .op_single = token.span() });
                    if (token2 == .comment) try nodes.append(.{ .comment = token2.span() });
                },
                .number, .string, .identifier => {
                    try nodes.append(switch (token2) {
                        .number => .{ .op_number = .{ token.span(), token2.span() } },
                        .string => .{ .op_string = .{ token.span(), token2.span() } },
                        .identifier => .{ .op_label = .{ token.span(), token2.span() } },
                        else => unreachable,
                    });

                    if (tokenizer.next(source)) |token3| switch (token3) {
                        .comment,
                        => {
                            try nodes.append(.{ .comment = token3.span() });
                        },
                        .newline => {},
                        else => {
                            try errors.append(.{ .expected_eol = token3.span() });
                            while (tokenizer.next(source)) |t| {
                                if (t == .comment or t == .newline) break;
                            }
                        },
                    };
                },
                .colon => try nodes.append(.{ .label = .{ token.span(), token2.span() } }),
            }
        },
    };

    return try nodes.toOwnedSlice();
}

const Node = union(enum) {
    comment: Span,
    label: [2]Span,
    op_single: Span,
    op_number: [2]Span,
    op_string: [2]Span,
    op_label: [2]Span,

    fn render(node: Node, src: []const u8, w: anytype) !void {
        switch (node) {
            .comment, .op_single => |span| try w.writeAll(span.slice(src)),
            .label => |spans| try w.print("{s}:", .{spans[0].slice(src)}),
            .op_number, .op_string, .op_label => |spans| try w.print("{s} {s}", .{
                spans[0].slice(src),
                spans[1].slice(src),
            }),
        }
    }

    fn jointSpan(node: Node) Span {
        return switch (node) {
            .comment, .op_single => |x| x,
            inline else => |xs| .{ .start = xs[0].start, .end = xs[1].end },
        };
    }
};

pub fn renderNodes(nodes: []const Node, src: []const u8, w: anytype) !void {
    var spacing: Spacing = .next_line;
    for (nodes, 0..) |node, i| {
        indent: {
            if (spacing == .same_line) break :indent;
            if (node == .label) break :indent;
            if (node == .comment) for (nodes[i + 1 ..]) |next| {
                if (next == .label) break :indent;
                if (next != .comment) break;
            };

            try w.writeAll("    ");
        }

        try node.render(src, w);

        spacing = if (i + 1 < nodes.len)
            Spacing.between(node.jointSpan(), nodes[i + 1].jointSpan(), src)
        else
            .next_line;
        try w.writeAll(spacing.slice());
    }
}

pub fn renderAir(air: Air, src: []const u8, writer: anytype) !void {
    var spacing: Spacing = .next_line;
    for (air.statements, 0..) |statement, i| {
        indent: {
            if (spacing == .same_line) break :indent;
            if (statement == .mark_label) break :indent;
            if (statement == .comment) for (air.statements[i + 1 ..]) |next| {
                if (next == .mark_label) break :indent;
                if (next != .comment) break;
            };

            try writer.writeAll("    ");
        }

        try renderStatement(air, i, src, writer);

        spacing = if (i + 1 < air.spans.len)
            Spacing.between(air.spans[i], air.spans[i + 1], src)
        else
            .next_line;
        try writer.writeAll(spacing.slice());
    }
}

fn renderStatement(
    air: Air,
    idx: usize,
    src: []const u8,
    writer: anytype,
) !void {
    switch (air.statements[idx]) {
        .comment => |span| try writer.writeAll(span.slice(src)),
        .mark_label => |label_idx| try writer.print("{s}:", .{air.labels[label_idx].name(src)}),
        .operation => |operation| {
            try writer.writeAll(@tagName(operation[0]));
            switch (operation[1]) {
                .label => |label_idx| try writer.print(" {s}", .{air.labels[label_idx].name(src)}),
                .number => |number| try writer.print(" {d}", .{@as(u32, @intCast(number))}),
                .none => {},
            }
        },
        .directive => |directive| {
            try writer.writeAll(@tagName(directive));
            try writer.writeByte(' ');
            switch (directive) {
                .dc => |string_idx| try renderString(air.strings[string_idx], writer),
                inline .ds, .db => |number| try renderNumber(number, writer),
            }
        },
    }
}

fn renderString(string: []const u8, writer: anytype) !void {
    const quote: u8 = blk: {
        var dblqn: usize = 0;
        var sglqn: usize = 0;
        for (string) |char| switch (char) {
            '"' => dblqn += 1,
            '\'' => sglqn += 1,
            else => {},
        };
        break :blk if (dblqn > sglqn) '\'' else '"';
    };

    try writer.writeByte(quote);

    for (string) |char| switch (char) {
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        '\n' => try writer.writeAll("\\n"),
        '\'', '"' => if (char == quote)
            try writer.print("\\{c}", .{char})
        else
            try writer.writeByte(char),
        else => try writer.writeByte(char),
    };

    try writer.writeByte(quote);
}

fn renderNumber(number: anytype, writer: anytype) !void {
    if (number > 0)
        try writer.print("{d}", .{@abs(number)})
    else
        try writer.print("{d}", .{number});
}

const Spacing = enum {
    same_line,
    next_line,
    line_between,
    fn slice(spacing: Spacing) []const u8 {
        return switch (spacing) {
            .same_line => " ",
            .next_line => "\n",
            .line_between => "\n\n",
        };
    }
    fn between(span1: Span, span2: Span, src: []const u8) Spacing {
        var count: usize = 0;
        for (src[span1.end..span2.start]) |char| if (char == '\n') {
            count += 1;
            if (count == 2) break;
        };
        return switch (count) {
            0 => .same_line,
            1 => .next_line,
            2 => .line_between,
            else => unreachable,
        };
    }
};

const MnemonicMap = std.StaticStringMapWithEql(Mnemonic, std.static_string_map.eqlAsciiIgnoreCase);
const mnemonic_map = MnemonicMap.initComptime(&.{
    .{ "stop", .stop },
    .{ "ld", .ld },
    .{ "lda", .lda },
    .{ "ldi", .ldi },
    .{ "st", .st },
    .{ "sti", .sti },
    .{ "add", .add },
    .{ "sub", .sub },
    .{ "mul", .mul },
    .{ "div", .div },
    .{ "in", .in },
    .{ "out", .out },
    .{ "jmp", .jmp },
    .{ "jg", .jg },
    .{ "jl", .jl },
    .{ "je", .je },
    .{ "call", .call },
    .{ "ret", .ret },
    .{ "push", .push },
    .{ "pop", .pop },
    .{ "ldparam", .ldparam },
    .{ "jge", .jge },
    .{ "jle", .jle },
    .{ "jne", .jne },
    .{ "pusha", .pusha },
});

const Mnemonic = enum(Word) {
    stop = 0,
    ld,
    lda,
    ldi,
    st,
    sti,
    add,
    sub,
    mul,
    div,
    in,
    out,
    jmp,
    jg,
    jl,
    je,
    call,
    ret,
    push,
    pop,
    ldparam,
    jge,
    jle,
    jne,
    pusha = 26,
};

const log = std.log.scoped(.parse);

test "format blank line" {
    try testIdempotence(
        \\    stop
        \\
        \\    stop
        \\
    );
}

test "format endline comment" {
    try testIdempotence("    stop ; do the stopping\n");
}

test "format label with directive" {
    try testIdempotence("label: ds 1\n");
}

test "format label with directive and comment" {
    try testIdempotence("label: dc \"words\" ; comment\n");
}

test "format comment before label/operation" {
    try testIdempotence(
        \\    ; comment
        \\    ; comment
        \\    stop
        \\; comment
        \\; comment
        \\label:
        \\
    );
}

fn testIdempotence(src: []const u8) !void {
    const alloc = std.testing.allocator;
    var errors = ArrayList(Error).init(alloc);
    defer errors.deinit();

    const nodes = try parse(alloc, src, true, &errors);
    defer alloc.free(nodes);

    var buf = ArrayList(u8).init(alloc);
    defer buf.deinit();
    try renderNodes(nodes, src, buf.writer());

    try std.testing.expectEqualStrings(src, buf.items);

    const air = try analyze(alloc, nodes, src, &errors);
    defer air.deinit(alloc);

    try std.testing.expectEqualSlices(Error, &.{}, errors.items);

    buf.clearAndFree();
    try renderAir(air, src, buf.writer());

    try std.testing.expectEqualStrings(src, buf.items);
}
