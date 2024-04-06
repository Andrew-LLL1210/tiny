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
