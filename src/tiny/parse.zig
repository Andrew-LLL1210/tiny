const std = @import("std");
const tiny = @import("../tiny.zig");
const Tokenizer = @import("tokenizer.zig");
const run = @import("run.zig");

const Ast = @This();
const Span = tiny.Span;
const Token = Tokenizer.Token;
const Machine = run.Machine;
const Word = run.Word;
const Arg = Word;
const Opcode = run.Op;
const Allocator = std.mem.Allocator;

statements: []const Statement,
labels: []const LabelData,
strings: []const Span,
errors: []const Error,

pub const LabelData = struct {};

pub const Error = struct {
    span: Span,
    tag: Tag,

    pub const Tag = enum {
        // thrown by the tokenizer
        illegal_character,
        illegal_identifier_character,
        illegal_number_character,
        unrecognized_escape_sequence,
        number_literal_too_large,
        unclosed_string,

        // thrown by the ast generator
        blank_label,
        argument_without_op,
        invalid_mnemonic,
        invalid_argument,
        expected_argument,
        invalid_number_range,
        expected_eol,
    };
};

pub const Node = union(enum) {
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

    pub fn jointSpan(node: Node) Span {
        return switch (node) {
            .comment, .op_single => |x| x,
            else => |xs| .{ .start = xs[0].start, .end = xs[1].end },
        };
    }
};

pub const Statement = union(enum) {
    comment: Span,
    operation: struct { Opcode, union(enum) { label: usize, number: Arg } },
    directive: union(enum) { dc: usize, db: Word, ds: usize },
};

pub fn deinit(ast: Ast, gpa: Allocator) void {}

const AllocError = std.mem.Allocator.Error;
pub fn init(gpa: std.mem.Allocator, source: []const u8, want_comments: bool) AllocError!Ast {
    var tokenizer: Tokenizer = .{ .want_comments = want_comments };

    var nodes = std.ArrayList(Node).init(gpa);
    var errors = std.ArrayList(Error).init(gpa);
    errdefer nodes.deinit();
    errdefer errors.deinit();

    while (tokenizer.next(source)) |token| switch (token) {
        .newline => {},
        .parse_error => |err| try errors.append(err),
        .comment => try nodes.append(.{ .comment = token.span() }),
        .number, .string => try errors.append(.{
            .span = token.span(),
            .tag = .argument_without_op,
        }),
        .colon => try errors.append(.{
            .span = token.span(),
            .tag = .blank_label,
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
                .colon => try nodes.append(.{ .label = .{ token.span(), token2.span() } }),
            }
        },
    };

    const nodes_slice = try nodes.toOwnedSlice();

    analyze(gpa, nodes_slice, errors);

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

pub fn analyze(gpa: Allocator, nodes: []const Node, errors: ArrayList(Error)) Air {}

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
