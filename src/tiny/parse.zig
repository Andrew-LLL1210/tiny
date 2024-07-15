const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");

const root = @import("../root.zig");
const Span = root.Span;
const Token = Tokenizer.Token;

pub const AstError = enum {
    // thrown by the tokenizer
    illegal_character,
    illegal_identifier_character,
    illegal_number_character,
    unrecognized_escape_sequence,
    number_literal_too_large,

    // thrown by the ast generator
    blank_label,
    argument_without_op,
    invalid_mnemonic,
    invalid_argument,
    expected_argument,
    invalid_number_range,
    expected_eol,
};

pub const Ast = struct {
    nodes: []const Node,
    errors: []const Error,

    pub const Error = struct {
        span: Span,
        tag: AstError,
    };
    pub const Node = union(enum) {
        comment: Span,
        label: struct {
            span: Span,
            name: Span,
        },
        op_single: Span,
        op_with_arg: struct {
            span: Span,
            name: Span,
            argument: Token,
        },

        fn render(node: Node, src: []const u8, w: anytype) !void {
            switch (node) {
                .comment => |c| try w.writeAll(c.slice(src)),
                .label => |l| try w.print("{s}:", .{l.name.slice(src)}),
                .op_single => |o| try w.writeAll(o.slice(src)),
                .op_with_arg => |o| try w.print("{s} {s}", .{ o.name.slice(src), o.argument.span().slice(src) }),
            }
        }

        pub fn span(node: Node) Span {
            return switch (node) {
                .comment, .op_single => |x| x,
                inline .label, .op_with_arg => |x| x.span,
            };
        }
    };

    const AllocError = std.mem.Allocator.Error;
    pub fn init(gpa: std.mem.Allocator, source: []const u8, want_comments: bool) AllocError!Ast {
        var tokenizer: Tokenizer = .{ .want_comments = want_comments };

        var nodes = std.ArrayList(Node).init(gpa);
        var errors = std.ArrayList(Error).init(gpa);
        errdefer nodes.deinit();
        errdefer errors.deinit();

        while (tokenizer.next(source)) |token| switch (token) {
            .newline => {},
            .comment, .parse_error => {
                try nodes.append(.{ .comment = token.span() });
                if (token == .parse_error) try errors.append(.{
                    .span = token.span(),
                    .tag = token.parse_error.tag,
                });
            },
            .number, .string => {
                try nodes.append(.{ .op_with_arg = .{
                    .span = token.span(),
                    .name = .{ .start = token.span().start, .end = token.span().start },
                    .argument = token,
                } });
                try errors.append(.{
                    .span = token.span(),
                    .tag = .argument_without_op,
                });
            },
            .colon => {
                try nodes.append(.{ .label = .{
                    .span = token.span(),
                    .name = .{ .start = token.span().start, .end = token.span().start },
                } });
                try errors.append(.{
                    .span = token.span(),
                    .tag = .blank_label,
                });
            },

            .identifier => {
                const token2 = tokenizer.next(source) orelse tokenizer.newline();
                switch (token2) {
                    .parse_error => {
                        try nodes.append(.{ .op_with_arg = .{
                            .span = joinSpans(token.span(), token2.span()),
                            .name = token.span(),
                            .argument = token2,
                        } });
                        try errors.append(.{
                            .span = token2.span(),
                            .tag = token2.parse_error.tag,
                        });
                    },
                    .newline, .comment => {
                        try nodes.append(.{ .op_single = token.span() });

                        const opcode = std.meta.stringToEnum(
                            Opcode,
                            token.span().slice(source),
                        ) orelse {
                            try errors.append(.{
                                .span = token.span(),
                                .tag = .invalid_mnemonic,
                            });
                            continue;
                        };
                        if (!opcode.acceptsArgKind(.none)) {
                            try errors.append(.{
                                .span = token.span(),
                                .tag = .expected_argument,
                            });
                        }

                        if (token2 == .comment) try nodes.append(.{ .comment = token2.span() });
                    },
                    .number, .string, .identifier => {
                        try nodes.append(.{ .op_with_arg = .{
                            .span = joinSpans(token.span(), token2.span()),
                            .name = token.span(),
                            .argument = token2,
                        } });

                        const opcode = std.meta.stringToEnum(
                            Opcode,
                            token.span().slice(source),
                        ) orelse {
                            try errors.append(.{
                                .span = token.span(),
                                .tag = .invalid_mnemonic,
                            });
                            continue;
                        };

                        const argument_error: Error = .{ .span = token2.span(), .tag = .invalid_argument };
                        const range_error: Error = .{ .span = token2.span(), .tag = .invalid_number_range };
                        if (opcode.isDirective()) switch (opcode) {
                            .dc => if (token2 != .string) try errors.append(argument_error),
                            .ds => {
                                if (token2 != .number) {
                                    try errors.append(argument_error);
                                    continue;
                                }

                                const num = token2.number.value;
                                if (0 <= num and num <= 999) continue;
                                try errors.append(range_error);
                            },
                            .db => {
                                if (token2 != .number) {
                                    try errors.append(argument_error);
                                    continue;
                                }

                                const num = token2.number.value;
                                if (-99999 <= num and num <= 99999) continue;
                                try errors.append(range_error);
                            },
                            else => unreachable,
                        } else if (token2 == .string or !opcode.acceptsArgKind(kind(token2))) {
                            try errors.append(argument_error);
                        }

                        const backup = tokenizer;
                        defer tokenizer = backup;
                        if (tokenizer.next(source)) |token3| switch (token3) {
                            .comment, .newline => {},
                            else => try errors.append(.{
                                .span = token3.span(),
                                .tag = .expected_eol,
                            }),
                        };
                    },
                    .colon => {
                        try nodes.append(.{ .label = .{
                            .span = joinSpans(token.span(), token2.span()),
                            .name = token.span(),
                        } });
                    },
                }
            },
        };

        return .{
            .nodes = try nodes.toOwnedSlice(),
            .errors = try errors.toOwnedSlice(),
        };
    }

    pub fn render(ast: Ast, src: []const u8, w: anytype) !void {
        var spacing: Spacing = .next_line;
        for (ast.nodes, 0..) |node, i| {
            const indent: bool =
                (i == 0 or spacing != .same_line) and
                for (ast.nodes[i..]) |scan| switch (scan) {
                .comment => {},
                .label => break false,
                else => break true,
            } else false;

            if (indent) try w.writeAll("    ");

            const next = if (i + 1 < ast.nodes.len) ast.nodes[i + 1] else {
                try w.print("{}\n", .{renderNode(node, src)});
                break;
            };

            spacing = spaceBetween(node.span(), next.span(), src);
            switch (spaceBetween(node.span(), next.span(), src)) {
                .same_line => {
                    try w.print("{} ", .{renderNode(node, src)});
                },
                .next_line => {
                    try w.print("{}\n", .{renderNode(node, src)});
                },
                .line_between => {
                    try w.print("{}\n\n", .{renderNode(node, src)});
                },
            }
        }
    }

    pub const NodeRenderer = struct {
        source: []const u8,
        node: Node,

        pub fn format(
            x: NodeRenderer,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try x.node.render(x.source, writer);
        }
    };

    fn renderNode(node: Node, src: []const u8) NodeRenderer {
        return .{ .source = src, .node = node };
    }
};

fn joinSpans(span1: Span, span2: Span) Span {
    return .{ .start = span1.start, .end = span2.end };
}

const Spacing = enum { same_line, next_line, line_between };
fn spaceBetween(span1: Span, span2: Span, src: []const u8) Spacing {
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

pub const Opcode = enum(u32) {
    stop,
    ld,
    ldi,
    lda,
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
    db,
    ds,
    dc,

    pub fn isDirective(opcode: Opcode) bool {
        return switch (opcode) {
            .db, .ds, .dc => true,
            else => false,
        };
    }

    pub fn acceptsArgKind(opcode: Opcode, arg_kind: ArgKind) bool {
        return opcode.acceptedArgKinds().contains(arg_kind);
    }

    const Set = std.EnumSet(ArgKind);
    pub fn acceptedArgKinds(opcode: Opcode) Set {
        return switch (opcode) {
            .db, .ds, .dc => Set.initEmpty(),
            .stop, .in, .out, .ret => Set.init(.{ .none = true }),
            .push, .pop => Set.init(.{ .none = true, .label = true }),
            .ldparam => Set.init(.{ .immediate = true }),
            .ldi, .lda, .st, .sti, .jmp, .jg, .jl, .je, .call, .jge, .jle, .jne, .pusha => Set.init(.{ .label = true }),
            .ld, .add, .sub, .mul, .div => Set.init(.{ .immediate = true, .label = true }),
        };
    }
};

pub const ArgKind = enum { none, immediate, label };
fn kind(token: @import("Tokenizer.zig").Token) ArgKind {
    return switch (token) {
        .identifier => .label,
        .number => .immediate,
        else => unreachable,
    };
}
