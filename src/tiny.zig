//! This file contains functions for turning source code into a Listing

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Operation = @import("Operation.zig");
const Machine = @import("Machine.zig");
const Word = Machine.Word;
const Ptr = Machine.Ptr;
const Listing = Machine.Listing;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

pub fn Reporter(comptime WriterT: type) type {
    return struct {
        const Self = @This();

        line_no: usize = 0,
        filepath: []const u8,
        writer: WriterT,

        const ReportType = enum {
            err,
            note,
        };

        const ReportOptions = struct {
            const Enum = enum { auto, given };
            path: ?Enum = .auto,
            line: ?Enum = .auto,
            col: ?enum { given } = null,
        };

        pub fn report(
            self: Self,
            comptime severity: ReportType,
            comptime message: []const u8,
            args: anytype,
            comptime opts: ReportOptions,
        ) !void {
            comptime var loc_tag: []const u8 = "\x1b[97m";
            if (opts.path) |_| loc_tag = loc_tag ++ "{s}:";
            if (opts.line) |_| loc_tag = loc_tag ++ "{d}:";
            if (opts.col) |_| loc_tag = loc_tag ++ "{d}:";
            loc_tag = loc_tag ++ " ";

            const Autos = comptime blk: {
                var types: []const type = &.{};
                if (opts.path == ReportOptions.Enum.auto) types = types ++ [1]type{[]const u8};
                if (opts.line == ReportOptions.Enum.auto) types = types ++ [1]type{usize};
                break :blk std.meta.Tuple(types);
            };

            var autos: Autos = undefined;
            if (opts.path == ReportOptions.Enum.auto) autos[0] = self.filepath;
            if (opts.line == ReportOptions.Enum.auto) autos[autos.len - 1] = self.line_no;

            const sev_tag: []const u8 = switch (severity) {
                .err => "\x1b[91merror:",
                .note => "\x1b[96mnote:",
            } ++ "\x1b[97m ";

            try self.writer.print(loc_tag ++ sev_tag ++ message ++ "\x1b[0m\n", autos ++ args);
        }

        pub fn reportDuplicateLabel(
            self: Self,
            label_name: []const u8,
            line_no: usize,
            is_rom: bool,
        ) !void {
            try self.report(.err, "duplicate label '{s}'", .{label_name}, .{});
            if (is_rom)
                try self.report(.note, "'{s}' is reserved", .{canonicalName(label_name).?}, .{})
            else
                try self.report(.note, "original label here", .{line_no}, .{ .line = .given });
        }

        pub fn canonicalName(label_name: []const u8) ?[]const u8 {
            inline for (.{
                "printInteger",
                "printString",
                "inputInteger",
                "inputString",
            }) |name|
                if (eqlIgnoreCase(label_name, name)) return name;
            return null;
        }
    };
}

const AssemblyError = error{
    DuplicateLabel,
    UnknownLabel,
    InvalidSourceInstruction,
};

const LabelTable = HashMap([]const u8, LabelData, CaseInsensitiveContext, 80);

/// read tiny source code and produce a listing
pub fn readSource(in: anytype, alloc: Allocator, reporter: anytype) !Listing {
    // eventual return value
    var listing = ArrayList(?Word).init(alloc);
    errdefer listing.deinit();

    var label_table = LabelTable.init(alloc);
    defer label_table.deinit();
    defer {
        var it = label_table.valueIterator();
        while (it.next()) |label_data|
            label_data.references.deinit();
    }

    // put the builtins in the label_table
    inline for (.{
        "printInteger",
        "printString",
        "inputInteger",
        "inputString",
    }) |name, i|
        try label_table.putNoClobber(name, LabelData.initRom(name, i, alloc));

    // holds the lines because we need them to last
    var arena = std.heap.ArenaAllocator.init(alloc);
    const line_alloc = arena.allocator();
    defer arena.deinit();

    // get a line
    while (try in.readUntilDelimiterOrEofAlloc(alloc, '\n', 200)) |rline| {
        defer alloc.free(rline);
        reporter.line_no += 1;
        const parts = try separateParts(rline, line_alloc, reporter);

        if (parts.label) |label_name| {
            // TODO check if label is valid

            // put label address in label_table if not duplicate
            const addr = @truncate(u16, listing.items.len);
            const kv = try label_table.getOrPut(label_name);
            if (kv.found_existing and kv.value_ptr.addr != null) {
                try reporter.reportDuplicateLabel(label_name, kv.value_ptr.line_no, kv.value_ptr.addr orelse 0 >= 900);
                return error.ReportedError;
            }
            if (!kv.found_existing)
                kv.value_ptr.* = LabelData.init(label_name, reporter.line_no, addr, alloc)
            else {
                kv.value_ptr.addr = addr;
                kv.value_ptr.line_no = reporter.line_no;
            }
        }

        if (parts.op) |op| switch (try parseInstruction(op, parts.argument)) {
            .op_noarg => |op_| try listing.append((Operation{ .op = op_, .arg = 0 }).encode()),
            .op_imm => |operation| try listing.append(operation.encode()),
            .op_label => |data| {
                const token = try listing.addOne();
                token.* = (Operation{ .op = data.op, .arg = 0 }).encode();

                // add to references list
                const kv = try label_table.getOrPut(data.label);
                if (!kv.found_existing)
                    kv.value_ptr.* = LabelData.initNull(data.label, reporter.line_no, alloc);
                try kv.value_ptr.references.append(&token.*.?);
            },
            .define_characters => |string| {
                for (string) |char| try listing.append(char);
                try listing.append(0);
            },
            .define_byte => |word| try listing.append(word),
            .define_storage => |size| try listing.appendNTimes(null, size),
        };
    }

    // reify labels
    var it = label_table.valueIterator();
    while (it.next()) |value_ptr| {
        if (value_ptr.addr == null) {
            try reporter.report(
                .err,
                "unknown label '{s}'",
                .{ value_ptr.line_no, value_ptr.name },
                .{ .line = .given },
            );
            return error.ReportedError;
        }

        const label_data = value_ptr.*;
        for (label_data.references.items) |word_ptr|
            word_ptr.* += label_data.addr.?;
    }

    return listing.toOwnedSlice();
}

pub const Parts = struct {
    label: ?[]const u8,
    op: ?[]const u8,
    argument: ?[]const u8,
};

pub const ParserState = enum(usize) { s0, lb, s1, s2, op, s3, ar, st, es, s4, xx, oo };

pub fn separateParts(line: []const u8, alloc: Allocator, reporter: anytype) !Parts {
    var label_or_op = ArrayList(u8).init(alloc);
    var op = ArrayList(u8).init(alloc);
    var arg = ArrayList(u8).init(alloc);
    var is_label: bool = false;

    var state: ParserState = .s0;

    for (line) |char, i| {
        if (char == '\r') break;
        if (state == .st and char != '\\') try arg.append(char);
        if (state == .es) try arg.append(switch (char) {
            'n' => '\n',
            else => char,
        });

        // Tabularized implementation of an FSA
        const state_transition: [10]ParserState = switch (char) {
            '\x00'...'\x08', '\x0a'...'\x1f', '\x7f'...'\xff' => {
                try reporter.report(.err, "bad byte {X:0>2}", .{ i + 1, char }, .{ .col = .given });
                return error.ReportedError;
            },
            ' ', '\t' => .{ .s0, .s1, .s1, .s2, .s3, .s3, .s4, .st, .st, .s4 },
            ':' => .{ .xx, .s2, .s2, .xx, .xx, .xx, .xx, .st, .st, .xx },
            '"' => .{ .xx, .st, .st, .xx, .st, .st, .xx, .s4, .st, .xx },
            ';' => .{ .oo, .oo, .oo, .oo, .oo, .oo, .oo, .st, .st, .oo },
            '\\' => .{ .xx, .xx, .xx, .xx, .xx, .xx, .xx, .es, .st, .xx },
            else => .{ .lb, .lb, .ar, .op, .op, .ar, .ar, .st, .st, .xx },
        };

        state = state_transition[@enumToInt(state)];
        if (state == .xx) {
            try reporter.report(.err, "unexpected character '{c}'", .{ i + 1, char }, .{ .col = .given });
            return error.ReportedError;
        }
        if (state == .oo) break;

        if (state == .s2) is_label = true;

        if (state == .lb) try label_or_op.append(char);
        if (state == .op) try op.append(char);
        if (state == .ar) try arg.append(char);
    }

    return .{
        .label = if (is_label) wrapNull(label_or_op.toOwnedSlice()) else null,
        .op = wrapNull(if (is_label) op.toOwnedSlice() else label_or_op.toOwnedSlice()),
        .argument = wrapNull(arg.toOwnedSlice()),
    };
}

fn wrapNull(src: []const u8) ?[]const u8 {
    return if (src.len > 0) src else null;
}

const LabelData = struct {
    name: []const u8,
    line_no: usize,
    addr: ?u16,
    references: ArrayList(*Word),

    fn init(
        name: []const u8,
        line_no: usize,
        addr: ?u16,
        alloc: Allocator,
    ) LabelData {
        return .{
            .name = name,
            .line_no = line_no,
            .addr = addr,
            .references = ArrayList(*Word).init(alloc),
        };
    }

    fn initNull(name: []const u8, line_no: usize, alloc: Allocator) LabelData {
        return init(name, line_no, null, alloc);
    }

    fn initRom(name: []const u8, i: usize, alloc: Allocator) LabelData {
        return init(name, 0, @truncate(Ptr, 900 + 25 * i), alloc);
    }
};

const CaseInsensitiveContext = struct {
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
};

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

fn parseInstruction(op: []const u8, arg_m: ?[]const u8) !Instruction {
    if (arg_m) |arg| {
        if (eqlIgnoreCase(op, "db")) {
            return .{ .define_byte = try std.fmt.parseInt(Word, arg, 10) };
        }

        if (eqlIgnoreCase(op, "ds")) {
            return .{ .define_storage = try std.fmt.parseInt(u16, arg, 10) };
        }

        if (eqlIgnoreCase(op, "dc")) {
            if (arg[arg.len - 1] != '"') return error.NeedsString;
            return .{ .define_characters = arg[0 .. arg.len - 1] };
        }
    }

    inline for (op_list) |op_data| if (eqlIgnoreCase(op, op_data.mnemonic)) {
        if (arg_m) |arg| {
            return if (ascii.isDigit(arg[0])) .{ .op_imm = .{
                .op = op_data.variants[1] orelse return error.DislikesImmediate,
                .arg = try std.fmt.parseInt(Ptr, arg, 10),
            } } else .{
                .op_label = .{
                    .op = op_data.variants[2] orelse return error.DislikesLabel,
                    .label = arg,
                },
            };
        } else return .{
            .op_noarg = op_data.variants[0] orelse return error.NeedsOperand,
        };
    };
    return error.NotAnOperation;
}

const OpData = struct {
    mnemonic: []const u8,
    variants: [3]?Operation.Op,
};

const op_list = [_]OpData{
    .{ .mnemonic = "stop", .variants = .{ .stop, null, null } },
    .{ .mnemonic = "ld", .variants = .{ null, .ld_imm, .ld_from } },
    .{ .mnemonic = "ldi", .variants = .{ null, null, .ldi_from } },
    .{ .mnemonic = "lda", .variants = .{ null, null, .lda_of } },
    .{ .mnemonic = "st", .variants = .{ null, null, .st_to } },
    .{ .mnemonic = "sti", .variants = .{ null, null, .sti_to } },
    .{ .mnemonic = "add", .variants = .{ null, .add_imm, .add_by } },
    .{ .mnemonic = "sub", .variants = .{ null, .sub_imm, .sub_by } },
    .{ .mnemonic = "mul", .variants = .{ null, .mul_imm, .mul_by } },
    .{ .mnemonic = "div", .variants = .{ null, .div_imm, .div_by } },
    .{ .mnemonic = "in", .variants = .{ .in, null, null } },
    .{ .mnemonic = "out", .variants = .{ .out, null, null } },
    .{ .mnemonic = "jmp", .variants = .{ null, null, .jmp_to } },
    .{ .mnemonic = "je", .variants = .{ null, null, .je_to } },
    .{ .mnemonic = "jne", .variants = .{ null, null, .jne_to } },
    .{ .mnemonic = "jg", .variants = .{ null, null, .jg_to } },
    .{ .mnemonic = "jge", .variants = .{ null, null, .jge_to } },
    .{ .mnemonic = "jl", .variants = .{ null, null, .jl_to } },
    .{ .mnemonic = "jle", .variants = .{ null, null, .jle_to } },
    .{ .mnemonic = "call", .variants = .{ null, null, .call } },
    .{ .mnemonic = "ret", .variants = .{ .ret, null, null } },
    .{ .mnemonic = "push", .variants = .{ .push, null, .push_from } },
    .{ .mnemonic = "pop", .variants = .{ .pop, null, .pop_to } },
    .{ .mnemonic = "ldparam", .variants = .{ null, .ldparam_no, null } },
    .{ .mnemonic = "pusha", .variants = .{ null, null, .pusha_of } },
};
