/// turn a program IR into a machine listing
pub fn assemble(parser: *Parser, alloc: Allocator, src: *[]const u8) !Listing {
    var listing = ArrayList(ListingEntry).init(alloc);
    errdefer listing.deinit();
    var label_table = HashMap(u32).init(alloc);
    defer label_table.deinit();
    var deferred_labels = ArrayList(DeferredLabelData).init(alloc);
    defer deferred_labels.deinit();

    try label_table.putNoClobber("printInteger", 900);
    try label_table.putNoClobber("printString", 925);
    try label_table.putNoClobber("inputInteger", 950);
    try label_table.putNoClobber("inputString", 975);

    while (try parser.nextInstruction(src)) |instruction| switch (instruction.action) {
        .label => |label_name| {
            const get_or_put = try label_table.getOrPut(label_name);
            if (get_or_put.found_existing) return error.DuplicateLabel;
            get_or_put.value_ptr.* = @truncate(listing.items.len);
        },
        .dc_directive => |string| try assembleString(string, &listing, src),
        .db_directive => |word| try listing.append(.{ .word = word, .src = src.* }),
        .ds_directive => |size| try listing.appendNTimes(.{ .word = null, .src = src.* }, size),
        .operation => |operation| {
            const word = operation.reify(label_table);
            if (word == null) try deferred_labels.append(.{
                .op = operation,
                .ix = listing.items.len,
                .src = src.*,
            });

            try listing.append(.{ .word = word, .src = src.* });
        },
    };

    for (deferred_labels.items) |entry| {
        src.* = entry.src;
        listing.items[entry.ix].word = entry.op.reify(label_table) orelse return error.UnknownLabel;
    }

    return try listing.toOwnedSlice();
}

const DeferredLabelData = struct { op: parse.Operation, ix: usize, src: []const u8 };

pub fn printSkeleton(
    parser: *Parser,
    out: anytype,
    out_color: std.io.tty.Config,
    alloc: Allocator,
    r: *[]const u8,
) !void {
    var label_table = HashMap(SemaLabelData).init(alloc);
    defer label_table.deinit();

    var statements_to_print = ArrayList(Statement).init(alloc);
    defer statements_to_print.deinit();

    while (try parser.nextInstruction(r)) |statement| switch (statement.action) {
        .label => {
            try statements_to_print.append(statement);
            const entry = try label_table.getOrPutValue(statement.action.label, .{});
            if (entry.value_ptr.is_declared) return error.DuplicateLabel;
            entry.value_ptr.is_declared = true;
        },
        .operation => |op| if (op.opcode.isControlFlow()) {
            try statements_to_print.append(statement);
            if (op.argument == .label) {
                const entry = try label_table.getOrPutValue(op.argument.label, .{});
                if (entry.value_ptr.is_declared) {
                    entry.value_ptr.is_referenced_after = true;
                } else entry.value_ptr.is_referenced_before = true;
            }
        },
        else => {},
    };

    for (statements_to_print.items) |statement| switch (statement.action) {
        .label => |name| {
            defer out_color.setColor(out, .reset) catch {};
            try out_color.setColor(out, colorLabel(label_table.get(name).?));
            try out.print("{s}:\n", .{name});
        },
        .operation => |operation| switch (operation.argument) {
            .none => {
                try out.print("    {s}\n", .{@tagName(operation.opcode)});
            },
            .label => |name| {
                defer out_color.setColor(out, .reset) catch {};
                try out_color.setColor(out, colorLabel(label_table.get(name).?));
                try out.print("    {s} {s}\n", .{ @tagName(operation.opcode), name });
            },
            .number => |number| {
                try out.print("    {s} {d}\n", .{ @tagName(operation.opcode), number });
            },
        },
        else => unreachable,
    };
}

const SemaLabelData = struct {
    is_referenced_before: bool = false,
    is_referenced_after: bool = false,
    is_declared: bool = false,
};

fn colorLabel(data: SemaLabelData) std.io.tty.Color {
    if (!data.is_declared) return .red;
    if (data.is_referenced_before and data.is_referenced_after) return .yellow;
    if (data.is_referenced_before) return .white;
    if (data.is_referenced_after) return .cyan;
    return std.io.tty.Color.dim;
}

pub fn printFmt(parser: *Parser, out: anytype, r: *[]const u8) !void {
    var instruction = try parser.nextInstruction(r) orelse return;
    while (true) switch (instruction.action) {
        .comment => |mode| {
            std.debug.assert(mode == .full_line);

            const next = try parser.nextInstruction(r) orelse {
                try out.print("{}\n", .{instruction});
                return;
            };

            if (next.action == .label) {
                try out.print("{}\n", .{instruction});
            } else {
                try out.print("    {}\n", .{instruction});
            }

            instruction = next;
        },
        .label => {
            const next = try parser.nextInstruction(r);
            if (next != null and next.?.action == .comment and next.?.action.comment == .end_of_line) {
                try out.print("{} {}\n", .{ instruction, next.? });
                instruction = try parser.nextInstruction(r) orelse return;
            } else {
                try out.print("{}\n", .{instruction});
                instruction = next orelse return;
            }
        },
        else => {
            const next = try parser.nextInstruction(r);
            if (next != null and next.?.action == .comment and next.?.action.comment == .end_of_line) {
                try out.print("{} {}\n", .{ instruction, next.? });
                instruction = try parser.nextInstruction(r) orelse return;
            } else {
                try out.print("{}\n", .{instruction});
                instruction = next orelse return;
            }
        },
    };
}

const std = @import("std");
const parse = @import("parse.zig");
const run = @import("run.zig");
const Parser = parse.Parser;
const Statement = parse.Statement;
const ArrayList = std.ArrayList;
const HashMap = @import("insensitive.zig").HashMap;
const Allocator = std.mem.Allocator;
const Word = run.Word;

pub const Listing = []const ListingEntry;
pub const ListingEntry = struct { word: ?Word, src: []const u8 };

fn assembleString(
    string: []const u8,
    listing: *std.ArrayList(ListingEntry),
    r: *[]const u8,
) !void {
    var ip: usize = listing.items.len;
    var escaped = false;
    for (string[1 .. string.len - 1]) |char| if (escaped) {
        escaped = false;
        // TODO line_no
        try listing.append(.{ .word = switch (char) {
            'n' => '\n',
            '\\' => '\\',
            else => return error.IllegalEscapeCode,
        }, .src = r.* });
        ip += 1;
    } else switch (char) {
        '\\' => escaped = true,
        else => {
            try listing.append(.{ .word = char, .src = r.* });
            ip += 1;
        },
    };
    try listing.append(.{ .word = 0, .src = r.* });

    return;
}
