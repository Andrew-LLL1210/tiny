const std = @import("std");
const root = @import("../root.zig");

const Allocator = std.mem.Allocator;
const Span = root.Span;
const Ast = root.Ast;
const ArrayList = std.ArrayList;
const HashMap = @import("insensitive.zig").HashMap;
const Opcode = root.parse.Opcode;
const ArgKind = root.parse.ArgKind;
const Word = root.Word;

pub const Assembly = struct {
    listing: []const ?Word,
    index_map: []const ?usize,
    _slice: std.MultiArrayList(ListingEntry).Slice,
    label_table: HashMap(LabelData),
    errors: []const AssemblyError,

    pub fn deinit(assembly: *Assembly, gpa: Allocator) void {
        assembly._slice.deinit(gpa);
        gpa.free(assembly.errors);
        assembly.label_table.deinit();
    }
};

pub const ListingEntry = struct { word: ?Word, node_idx: ?usize };
pub const LabelData = struct { node_idx: usize, idx: usize };

pub const AssemblyError = struct {
    span: Span,
    tag: Tag,
    const Tag = enum {
        duplicate_label,
        unknown_label,
        unknown_escape_code,
    };
};

/// assumes `ast` is error-free.
/// clean up with `defer assembly.deinit(gpa)`.
pub fn assemble(gpa: Allocator, ast: Ast, source: []const u8) Allocator.Error!Assembly {
    var listing = std.MultiArrayList(ListingEntry){};
    var label_table = HashMap(LabelData).init(gpa);
    var errors = ArrayList(AssemblyError).init(gpa);
    var deferred_labels = ArrayList(struct {
        opcode: Opcode,
        label_name: []const u8,
        node: root.parse.Ast.Node,
        idx: usize,
    }).init(gpa);

    errdefer listing.deinit(gpa);
    errdefer label_table.deinit();
    errdefer errors.deinit();
    defer deferred_labels.deinit();

    try label_table.putNoClobber("printInteger", .{ .idx = 900, .node_idx = 0 });
    try label_table.putNoClobber("printString", .{ .idx = 925, .node_idx = 0 });
    try label_table.putNoClobber("inputInteger", .{ .idx = 950, .node_idx = 0 });
    try label_table.putNoClobber("inputString", .{ .idx = 975, .node_idx = 0 });

    for (ast.nodes, 0..) |node, idx| switch (node) {
        .comment => {},

        .label => |label| {
            const get_or_put = try label_table.getOrPut(label.name.slice(source));
            if (get_or_put.found_existing) {
                try errors.append(.{ .span = label.span, .tag = .duplicate_label });
                continue;
            }
            get_or_put.value_ptr.* = .{ .node_idx = idx, .idx = listing.items(.word).len };
        },

        .op_single => |span| {
            const opcode = std.meta.stringToEnum(Opcode, span.slice(source)) orelse unreachable;
            const word = @intFromEnum(opcode) * 1000;
            try listing.append(gpa, .{ .word = @intCast(word), .node_idx = idx });
        },

        .op_with_arg => |op| {
            const opcode = std.meta.stringToEnum(Opcode, op.name.slice(source)) orelse unreachable;
            if (opcode.isDirective()) switch (opcode) {
                .dc => try assembleString(
                    op.argument.string.slice(source),
                    gpa,
                    &listing,
                    &errors,
                    idx,
                    op.argument.string,
                ),
                .ds => for (0..@intCast(op.argument.number.value)) |_|
                    try listing.append(gpa, .{ .word = null, .node_idx = idx }),
                .db => try listing.append(gpa, .{
                    .word = op.argument.number.value,
                    .node_idx = idx,
                }),

                else => unreachable,
            } else if (op.argument == .identifier) {
                try deferred_labels.append(.{
                    .opcode = opcode,
                    .label_name = op.argument.span().slice(source),
                    .node = node,
                    .idx = listing.items(.word).len,
                });
                try listing.append(gpa, .{ .word = null, .node_idx = idx });

                continue;
            } else {
                const argument = op.argument.number.value;
                const word = @as(i32, @intCast(@intFromEnum(opcode))) * 1000 + argument +
                    @as(i32, switch (opcode) {
                    .ld, .add, .sub, .mul, .div => 90000,
                    else => 0,
                });
                try listing.append(gpa, .{ .word = @intCast(word), .node_idx = idx });
            }
        },
    };

    for (deferred_labels.items) |data| if (label_table.get(data.label_name)) |label_data| {
        const word = @as(i32, @intCast(@intFromEnum(data.opcode))) * 1000 +
            @as(i32, @intCast(label_data.idx)) +
            @as(i32, switch (data.opcode) {
            .push, .pop => 6,
            else => 0,
        });
        listing.items(.word)[data.idx] = @intCast(word);
    } else {
        try errors.append(.{ .span = data.node.op_with_arg.span, .tag = .unknown_label });
    };

    const slice = listing.toOwnedSlice();

    return .{
        .listing = slice.items(.word),
        .index_map = slice.items(.node_idx),
        .errors = try errors.toOwnedSlice(),
        .label_table = label_table,
        ._slice = slice,
    };
}

fn assembleString(
    slice: []const u8,
    gpa: Allocator,
    listing: *std.MultiArrayList(ListingEntry),
    errors: *std.ArrayList(AssemblyError),
    node_idx: usize,
    span: Span,
) Allocator.Error!void {
    var escaped = false;
    for (slice[1 .. slice.len - 1]) |char| if (escaped) {
        escaped = false;
        try listing.append(gpa, .{ .word = switch (char) {
            'n' => '\n',
            '\\' => '\\',
            't' => '\t',
            'r' => '\r',
            else => blk: {
                try errors.append(.{
                    .span = span,
                    .tag = .unknown_escape_code,
                });
                break :blk char;
            },
        }, .node_idx = node_idx });
    } else switch (char) {
        '\\' => escaped = true,
        else => {
            try listing.append(gpa, .{ .word = char, .node_idx = node_idx });
        },
    };

    try listing.append(gpa, .{ .word = 0, .node_idx = node_idx });
}
