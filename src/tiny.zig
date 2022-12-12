//! This file contains functions for turning source code into a Listing

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Operation = @import("Operation.zig");
const Machine = @import("Machine.zig");
const Word = Machine.Word;
const Ptr = Machine.Ptr;
const Listing = Machine.Listing;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

pub const TinyErrorReporter = struct {
    line_no: usize = 0,
    filepath: []const u8,
    writer: Writer,

    pub fn report(
        self: TinyErrorReporter,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.writer.print(
            "\x1b[1m{s}:{d}: \x1b[31merror:\x1b[39m " ++ fmt ++ "\x1b[0m\n",
            .{ self.filepath, self.line_no } ++ args,
        );
    }
};

const LabelData = struct {
    addr: ?u16,
    references: ArrayList(*Word),

    fn init(addr: ?u16, alloc: Allocator) LabelData {
        return .{
            .addr = addr,
            .references = ArrayList(*Word).init(alloc),
        };
    }

    fn initNull(alloc: Allocator) LabelData {
        return init(null, alloc);
    }
};

const HashMap = std.HashMap([]const u8, LabelData, struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        // case insensitive hashing
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

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return eqlIgnoreCase(a, b);
    }
}, 80);

/// read tiny source code and produce a listing
pub fn readSource(in: Reader, alloc: Allocator, reporter: *TinyErrorReporter) !Listing {
    // eventual return value
    var listing = ArrayList(?Word).init(alloc);
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

    // holds the lines because we need them to last
    var arena = std.heap.ArenaAllocator.init(alloc);
    const line_alloc = arena.allocator();
    defer arena.deinit();

    // get a line
    while (try in.readUntilDelimiterOrEofAlloc(line_alloc, '\n', 200)) |rline| {
        reporter.line_no += 1;
        const line = mem.trimRight(u8, rline, "\r\n");

        // remove comment
        const noncomment = if (mem.indexOf(u8, line, ";")) |ix| line[0..ix] else line;

        // separate label if exists
        const src = if (mem.indexOf(u8, noncomment, ":")) |ix| lbl: {
            const label_name = mem.trim(u8, noncomment[0..ix], " \t");
            // TODO: check if label name is valid

            // put label address in label_table if not duplicate
            const addr = @truncate(u16, listing.items.len);
            const kv = try label_table.getOrPut(label_name);
            if (kv.found_existing and kv.value_ptr.addr != null) {
                try reporter.report("duplicate label '{s}'", .{label_name});
                return error.DuplicateLabel;
            }
            if (!kv.found_existing) kv.value_ptr.* = LabelData.init(addr, alloc) else kv.value_ptr.addr = addr;

            break :lbl mem.trim(u8, noncomment[ix + 1 ..], " \t");
        } else mem.trim(u8, noncomment, " \t");

        if (src.len == 0) continue;

        if (parseInstruction(src)) |inst| switch (inst) {
            .op_noarg => |op| try listing.append((Operation{ .op = op, .arg = 0 }).encode()),
            .op_imm => |operation| try listing.append(operation.encode()),
            .op_label => |data| {
                const token = try listing.addOne();
                token.* = (Operation{ .op = data.op, .arg = 0 }).encode();

                // add to references list
                const kv = try label_table.getOrPut(data.label);
                if (!kv.found_existing) kv.value_ptr.* = LabelData.initNull(alloc);
                try kv.value_ptr.references.append(&token.*.?);
            },
            .define_characters => |string| {
                for (string) |char| try listing.append(char);
                try listing.append(0);
            },
            .define_byte => |word| try listing.append(word),
            .define_storage => |size| try listing.appendNTimes(null, size),
        } else {
            try reporter.report("invalid instruction: \'{s}\'", .{src});
            return error.InvalidSourceInstruction;
        }
    }

    // reify labels
    var it = label_table.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.addr == null) return error.UnknownLabel;

        const label_data = entry.value_ptr.*;
        for (label_data.references.items) |word_ptr|
            word_ptr.* += label_data.addr.?;
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
                    .arg = std.fmt.parseInt(u16, arg, 10) catch return null,
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
        return .{ .define_byte = std.fmt.parseInt(Word, arg, 10) catch return null };
    }

    if (eqlIgnoreCase(mnemonic, "ds")) {
        return .{ .define_storage = std.fmt.parseInt(u16, arg, 10) catch return null };
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
