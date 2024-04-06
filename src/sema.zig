/// turn a program IR into a machine listing
pub fn assemble(parser: *Parser, alloc: Allocator) !Listing {
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

    while (try parser.nextInstruction()) |instruction| switch (instruction.action) {
        .label => |label_name| {
            const get_or_put = try label_table.getOrPut(label_name);
            if (get_or_put.found_existing) return error.DuplicateLabel;
            get_or_put.value_ptr.* = @truncate(listing.items.len);
        },
        .dc_directive => |string| try assembleString(string, &listing),
        .db_directive => |word| try listing.append(.{ .word = word }),
        .ds_directive => |size| try listing.appendNTimes(.{ .word = null }, size),
        .operation => |operation| {
            const word = operation.reify(label_table);
            if (word == null) try deferred_labels.append(.{
                .op = operation,
                .ix = listing.items.len,
            });
            try listing.append(.{ .word = word });
        },
    };

    for (deferred_labels.items) |entry| {
        listing.items[entry.ix].word = entry.op.reify(label_table) orelse return error.UnknownLabel;
    }

    return try listing.toOwnedSlice();
}

const DeferredLabelData = struct { op: parse.Operation, ix: usize };

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
pub const ListingEntry = struct { word: ?Word, line_no: usize = 42069 };

fn assembleString(
    string: []const u8,
    listing: *std.ArrayList(ListingEntry),
) !void {
    var ip: usize = listing.items.len;
    var escaped = false;
    for (string[1 .. string.len - 1]) |char| if (escaped) {
        escaped = false;
        // TODO line_no
        try listing.append(.{ .line_no = 42069, .word = switch (char) {
            'n' => '\n',
            '\\' => '\\',
            else => return error.IllegalEscapeCode,
        } });
        ip += 1;
    } else switch (char) {
        '\\' => escaped = true,
        else => {
            try listing.append(.{ .line_no = 42069, .word = char });
            ip += 1;
        },
    };
    try listing.append(.{ .line_no = 42069, .word = 0 });

    return;
}
