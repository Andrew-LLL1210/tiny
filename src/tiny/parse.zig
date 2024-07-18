const std = @import("std");
const tiny = @import("../tiny.zig");
const Tokenizer = @import("Tokenizer.zig");
const run = @import("run.zig");

const Span = tiny.Span;
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

    pub fn render(air: Air, source: []const u8, writer: anytype) !void {
        _ = air;
        _ = source;
        _ = writer;
        @panic("TODO");
    }

    pub fn deinit(air: Air, gpa: Allocator) void {
        gpa.free(air.statements);
        gpa.free(air.labels);
        for (air.strings) |string| gpa.free(string);
        gpa.free(air.strings);
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
        return if (label_data.canonical_name) |canon| switch (canon) {
            .span => |span| span.slice(source),
            .slice => |slice| slice,
        } else label_data.temporary_name.slice(source);
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
    defer label_indices.deinit();

    errdefer {
        statements.deinit();
        labels.deinit();
        strings.deinit();
    }

    inline for (.{ "printInteger", "inputInteger", "printString", "inputString" }, 0..) |name, idx| {
        try labels.append(.{ .builtin_name = name });
        try label_indices.putNoClobber(name, idx);
    }

    for (nodes) |node| switch (node) {
        .comment => |span| try statements.append(.{ .comment = span }),
        .label => |spans| {
            const gop = try label_indices.getOrPut(spans[0].slice(source));
            if (!gop.found_existing) {
                gop.value_ptr.* = labels.items.len;
                try labels.append(.{ .canonical_name = spans[0] });
                try statements.append(.{ .mark_label = gop.value_ptr.* });
                continue;
            }

            switch (labels.items[gop.value_ptr.*]) {
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
        .op_label => |spans| {
            const mnemonic = mnemonic_map.get(spans[0].slice(source)) orelse {
                try errors.append(.{ .invalid_mnemonic = spans[0] });
                continue;
            };

            switch (mnemonic) {
                .stop, .in, .out, .ret, .ldparam => {
                    try errors.append(.{ .invalid_argument = node.jointSpan() });
                    continue;
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
        .op_single => |span| {
            const mnemonic = mnemonic_map.get(span.slice(source)) orelse {
                try errors.append(.{ .invalid_mnemonic = span });
                continue;
            };

            switch (mnemonic) {
                .stop, .in, .out, .ret, .push, .pop => {},
                else => {
                    try errors.append(.{ .invalid_argument = node.jointSpan() });
                    continue;
                },
            }

            try statements.append(.{ .operation = .{ mnemonic, .none } });
        },
        .op_number => |spans| {
            const number = std.fmt.parseInt(i32, (spans[1].slice(source)), 10) catch unreachable;
            if (std.ascii.eqlIgnoreCase(spans[0].slice(source), "ds")) {
                if (number <= 0) {
                    try errors.append(.{ .invalid_number_range = spans[1] });
                } else {
                    try statements.append(.{ .directive = .{ .ds = @intCast(number) } });
                }
                continue;
            } else if (std.ascii.eqlIgnoreCase(spans[0].slice(source), "db")) {
                if (number < -99999 or number > 99999) {
                    try errors.append(.{ .invalid_number_range = spans[1] });
                } else {
                    try statements.append(.{ .directive = .{ .db = number } });
                }
                continue;
            }

            const mnemonic = mnemonic_map.get(spans[0].slice(source)) orelse {
                try errors.append(.{ .invalid_mnemonic = spans[0] });
                continue;
            };

            switch (mnemonic) {
                .ld, .add, .sub, .mul, .div, .ldparam => {},
                else => {
                    try errors.append(.{ .invalid_argument = node.jointSpan() });
                    continue;
                },
            }

            if (number < 0 or number > 999) {
                try errors.append(.{ .invalid_number_range = spans[1] });
                continue;
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
    };

    for (labels.items) |label_data| if (label_data == .temporary_name) {
        try errors.append(.{ .unknown_label = label_data.temporary_name });
    };

    return .{
        .statements = try statements.toOwnedSlice(),
        .labels = try labels.toOwnedSlice(),
        .strings = try strings.toOwnedSlice(),
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
                        .comment, .newline => {},
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
            .op_single => |spans| try w.print("{s} {s}", .{
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
            if (node == .comment) for (nodes[i + 1 ..]) |next| {
                if (next == .label) break :indent;
                if (next != .comment) break;
            };

            try w.writeAll("    ");
        }

        const next = if (i + 1 < nodes.len) nodes[i + 1] else {
            try node.render(src, w);
            try w.writeByte('\n');
            break;
        };

        try node.render(src, w);
        spacing = Spacing.between(node.span(), next.span(), src);
        try w.writeAll(spacing.slice());
    }
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
