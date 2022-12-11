//! This file contains functions for turning source code into a Listing

const std = @import("std");
const lib = @import("lib.zig");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Listing = @import("listing.zig").Listing;
const Token = @import("listing.zig").Token;
const Operation = @import("Operation.zig");
const Word = u24;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

// re-exports
pub const readListing = @import("listing.zig").read;
pub const writeListing = @import("listing.zig").write;

const LabelData = struct {
    addr: u16,
    references: ArrayList(*Word),

    fn init(addr: u16, alloc: Allocator) LabelData {
        return .{
            .addr = addr,
            .references = ArrayList(*Word).init(alloc),
        };
    }
};

const HashMap = std.HashMap([]const u8, LabelData, struct {
    pub fn hash(ctx: @This(), key: []const u8) u64 {
        // case insensitive hashing
        _ = ctx;
        var wh = std.hash.Wyhash.init(0);
        for (key) |char| {
            if (ascii.isLower(char)) {
                const e = char - ('a' - 'A');
                wh.update(mem.asBytes(&e));
            } else {
                wh.update(mem.asBytes(&char));
            }
        }
        return wh.final();
    }

    pub fn eql(ctx: @This(), a: []const u8, b: []const u8) bool {
        _ = ctx;
        return eqlIgnoreCase(a, b);
    }
}, 80);

/// read tiny source code and produce a listing
pub fn readSource(in: Reader, alloc: Allocator) !Listing {
    // eventual return value
    var listing = ArrayList(Token).init(alloc);
    errdefer listing.deinit();

    // TODO: use a custom ctx that performs case-insensitive comparisons
    var label_table = HashMap.init(alloc);
    defer label_table.deinit();
    defer {
        var it = label_table.valueIterator();
        while (it.next()) |label_data|
            label_data.references.deinit();
    }

    // put the builtins in the label_table
    try label_table.putNoClobber("printInteger", LabelData.init(900, alloc));
    try label_table.putNoClobber("printString", LabelData.init(925, alloc));
    try label_table.putNoClobber("inputInteger", LabelData.init(950, alloc));
    try label_table.putNoClobber("inputString", LabelData.init(975, alloc));

    var cur_addr: u16 = 0;

    // holds the lines because we need them to last
    var arena = std.heap.ArenaAllocator.init(alloc);
    const line_alloc = arena.allocator();
    defer arena.deinit();

    // get a line
    while (try in.readUntilDelimiterOrEofAlloc(line_alloc, '\n', 200)) |rline| {
        const line = mem.trimRight(u8, rline, "\r\n");

        // remove comment
        const noncomment = if (mem.indexOf(u8, line, ";")) |ix|
            line[0..ix]
        else
            line;

        // separate label if exists
        const src = if (mem.indexOf(u8, noncomment, ":")) |ix| lbl: {
            const label_name = mem.trim(u8, noncomment[0..ix], " \t");
            // TODO: check if label name is valid

            // put label address in label_table
            // TODO: detect duplicate labels
            if (label_table.getPtr(label_name)) |label_data| {
                label_data.addr = cur_addr;
            } else {
                try label_table.putNoClobber(label_name, LabelData.init(cur_addr, alloc));
            }

            break :lbl mem.trim(u8, noncomment[ix + 1 ..], " \t");
        } else mem.trim(u8, noncomment, " \t");

        if (src.len == 0) continue;
        cur_addr += 1;

        if (parseInstruction(src)) |inst| switch (inst) {
            .op_noarg => |op| try listing.append(Token{
                .value = (Operation{ .op = op, .arg = 0 }).encode(),
            }),
            .op_imm => |operation| try listing.append(Token{ .value = operation.encode() }),
            .op_label => |data| {
                const token = try listing.addOne();
                token.* = Token{
                    .value = (Operation{ .op = data.op, .arg = 0 }).encode(),
                };

                // add to references list
                if (label_table.getPtr(data.label)) |label_data| {
                    try label_data.references.append(&token.*.value);
                } else {
                    try label_table.putNoClobber(data.label, LabelData{
                        .addr = 909,
                        .references = ArrayList(*Word).init(alloc),
                    });
                    if (label_table.getPtr(data.label)) |label_data| {
                        try label_data.references.append(&token.*.value);
                    } else unreachable;
                }
            },
            .define_characters => |string| {
                cur_addr += @truncate(u16, string.len);
                for (string) |char| try listing.append(.{ .value = char });
                try listing.append(.{ .value = 0 });
            },
            .define_byte => |word| try listing.append(.{ .value = word }),
            .define_storage => |size| {
                cur_addr += size - 1;
                try listing.append(.{ .addr = cur_addr + size - 1 });
            },
        } else {
            std.debug.print("invalid instruction: \"{s}\"\n", .{src});
            return error.InvalidSourceInstruction;
        }
    }

    // reify labels
    var it = label_table.iterator();
    while (it.next()) |entry| {
        const label_data = entry.value_ptr.*;
        std.debug.print("label '{s}' has {d} references\n", .{
            @ptrCast([*:0]const u8, entry.key_ptr),
            label_data.references.items.len,
        });
        for (label_data.references.items) |word_ptr|
            word_ptr.* += label_data.addr;
    }

    return listing.toOwnedSlice();
}

const Instruction = union(enum) {
    op_noarg: Operation.Op,
    op_imm: Operation,
    op_label: struct {
        op: Operation.Op,
        label: []const u8,
    },
    define_characters: []const u8,
    define_byte: Word,
    define_storage: u16,
};

fn parseInstruction(line: []const u8) ?Instruction {
    inline for (ops_noarg) |data| {
        if (eqlIgnoreCase(line, data.mnemonic))
            return .{ .op_noarg = data.op };
    }

    var it = mem.tokenize(u8, line, " ");
    const mnemonic = it.next() orelse unreachable;

    if (eqlIgnoreCase(mnemonic, "dc")) {
        // elegant string parsing**
        // make sure it's wrapped in ""
        const str = mem.trim(u8, it.rest(), " \t");
        if (str[0] != '"') return null;
        if (str[str.len - 1] != '"') return null;

        const innerstr = str[1 .. str.len - 1];
        // assume this is okay for now
        return .{ .define_characters = innerstr };
    }

    const arg = it.next() orelse return null;
    if (it.next()) |_| return null;

    if (std.ascii.isDigit(arg[0])) {
        inline for (ops_imm) |data| {
            if (eqlIgnoreCase(mnemonic, data.mnemonic))
                return .{ .op_imm = .{
                    .op = data.op,
                    .arg = lib.parseInt(u16, arg) catch return null,
                } };
        }
    } else {
        inline for (ops_label) |data| {
            if (eqlIgnoreCase(mnemonic, data.mnemonic))
                return .{ .op_label = .{
                    .op = data.op,
                    .label = arg,
                } };
        }
    }

    if (eqlIgnoreCase(mnemonic, "db")) {
        return .{ .define_byte = lib.parseInt(Word, arg) catch return null };
    }

    if (eqlIgnoreCase(mnemonic, "ds")) {
        return .{ .define_storage = lib.parseInt(u16, arg) catch return null };
    }

    return null;
}

const ops_noarg = [_]struct { op: Operation.Op, mnemonic: []const u8 }{
    .{ .op = .stop, .mnemonic = "stop" },
    .{ .op = .in, .mnemonic = "in" },
    .{ .op = .out, .mnemonic = "out" },
    .{ .op = .ret, .mnemonic = "ret" },
    .{ .op = .push, .mnemonic = "push" },
    .{ .op = .pop, .mnemonic = "pop" },
};

const ops_imm = [_]struct { op: Operation.Op, mnemonic: []const u8 }{
    .{ .op = .ld_imm, .mnemonic = "ld" },
    .{ .op = .add_imm, .mnemonic = "add" },
    .{ .op = .sub_imm, .mnemonic = "sub" },
    .{ .op = .mul_imm, .mnemonic = "mul" },
    .{ .op = .div_imm, .mnemonic = "div" },
    .{ .op = .ldparam_no, .mnemonic = "ldparam" },
};

const ops_label = [_]struct { op: Operation.Op, mnemonic: []const u8 }{
    .{ .op = .ld_from, .mnemonic = "ld" },
    .{ .op = .ldi_from, .mnemonic = "ldi" },
    .{ .op = .lda_of, .mnemonic = "lda" },
    .{ .op = .st_to, .mnemonic = "st" },
    .{ .op = .sti_to, .mnemonic = "sti" },
    .{ .op = .add_by, .mnemonic = "add" },
    .{ .op = .sub_by, .mnemonic = "sub" },
    .{ .op = .mul_by, .mnemonic = "mul" },
    .{ .op = .div_by, .mnemonic = "div" },
    .{ .op = .jmp_to, .mnemonic = "jmp" },
    .{ .op = .je_to, .mnemonic = "je" },
    .{ .op = .jne_to, .mnemonic = "jne" },
    .{ .op = .jg_to, .mnemonic = "jg" },
    .{ .op = .jge_to, .mnemonic = "jge" },
    .{ .op = .jl_to, .mnemonic = "jl" },
    .{ .op = .jle_to, .mnemonic = "jle" },
    .{ .op = .call, .mnemonic = "call" },
    .{ .op = .push_from, .mnemonic = "push" },
    .{ .op = .pop_to, .mnemonic = "pop" },
    .{ .op = .pusha_of, .mnemonic = "pusha" },
};
