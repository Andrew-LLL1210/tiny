//! This file contains functions for turning source code into a Listing

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Tuple = std.meta.Tuple;
const operation = @import("operation.zig");
const Operation = operation.Operation;
const machine = @import("machine.zig");
const Machine = machine.Machine;
const Word = machine.Word;
const Ptr = machine.Ptr;
const Listing = machine.Listing;
const eql = mem.eql;
const Argument = machine.Ptr;
const Address = machine.Ptr;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const encodeOpArg = operation.encodeOpArg;
const Diagnostic = @import("Diagnostic.zig");

pub const AssemblyError = error{
    DuplicateLabel,
    ReservedLabel,
    UnknownLabel,
    UnknownInstruction,
    BadByte,
    UnexpectedCharacter,
    DislikesImmediate,
    DislikesOperand,
    NeedsImmediate,
    NeedsOperand,
    RequiresLabel,
    DirectiveExpectedAgument,
    DbOutOfRange,
    DbBadArgType,
    DsOutOfRange,
    ArgumentOutOfRange,
};
const Parts = struct {
    label: ?[]const u8,
    op: ?[]const u8,
    argument: ?[]const u8,
};
const FirstPassData = union(enum) {
    define_byte: Word,
    define_characters: []const u8,
    define_storage: usize,
    instruction_1: Word,
    instruction_2: SecondPassData,
};
const SecondPassData = struct {
    line_no: usize,
    mnemonic: Mnemonic,
    label_arg: []const u8,
    destination: usize,
};
const LabelData = struct {
    name: []const u8,
    line_no: usize,
    addr: u16,

    fn init(
        name: []const u8,
        line_no: usize,
        addr: u16,
    ) LabelData {
        return .{
            .name = name,
            .line_no = line_no,
            .addr = addr,
        };
    }

    fn initRom(name: []const u8, i: usize) LabelData {
        return init(name, 0, @truncate(Ptr, 900 + 25 * i));
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
const OpData = union(enum) {
    nil,
    imm: Argument,
    adr: Address,
};

const LabelTable = HashMap([]const u8, LabelData, CaseInsensitiveContext, 80);

const ReadSourceError = Allocator.Error || AssemblyError;

/// read tiny source code and produce a listing or failure diagnostic
/// Errors on faults unrelated to program, i.e. OutOfMemory
/// diagnostic is an out parameter
pub fn parseListing(src: []const u8, alloc: Allocator, diagnostic: *Diagnostic) ReadSourceError!Listing {
    // eventual return value
    var listing = ArrayList(?Word).init(alloc);
    errdefer listing.deinit();

    var label_table = LabelTable.init(alloc);
    defer label_table.deinit();

    // put the builtins in the label_table
    inline for (.{
        "printInteger",
        "printString",
        "inputInteger",
        "inputString",
    }) |name, i|
        try label_table.putNoClobber(name, LabelData.initRom(name, i));

    var postponed = ArrayList(SecondPassData).init(alloc);
    defer postponed.deinit();

    // get all labels and directives
    var it = mem.split(u8, src, "\n");
    var line_no: usize = 1;
    while (it.next()) |line| : (line_no += 1) {
        diagnostic.line = line_no;
        const parts = try separateParts(line, diagnostic);

        if (parts.label) |label_name| {
            // TODO check if label is valid

            // put label address in label_table if not duplicate
            const addr = @truncate(Address, listing.items.len);
            const kv = try label_table.getOrPut(label_name);
            if (kv.found_existing) {
                diagnostic.label_name = kv.value_ptr.name;
                diagnostic.label_prior_line = kv.value_ptr.line_no;
                return if (kv.value_ptr.addr >= 900) error.ReservedLabel else error.DuplicateLabel;
            }
            kv.value_ptr.* = LabelData.init(label_name, line_no, addr);
        }

        if (parts.op) |op| switch (try firstPass(op, parts.argument, diagnostic)) {
            .define_characters => |string| {
                for (string) |char| try listing.append(char);
                try listing.append(0);
            },
            .define_byte, .instruction_1 => |word| try listing.append(word),
            .define_storage => |size| try listing.appendNTimes(null, size),
            .instruction_2 => |data| {
                var snd_pass_data = data;
                snd_pass_data.destination = listing.items.len;
                snd_pass_data.line_no = line_no;
                _ = try listing.addOne();
                try postponed.append(snd_pass_data);
            },
        };
    }

    // second pass
    for (postponed.items) |data| {
        const label = label_table.get(data.label_arg) orelse {
            diagnostic.label_name = data.label_arg;
            diagnostic.line = data.line_no;
            return error.UnknownLabel;
        };
        diagnostic.op = data.mnemonic.toString();
        listing.items[data.destination] = try encodeInstruction(data.mnemonic, .{ .adr = label.addr });
    }

    return listing.toOwnedSlice();
}

pub fn firstPass(
    op: []const u8,
    argument: ?[]const u8,
    diagnostic: *Diagnostic,
) AssemblyError!FirstPassData {
    diagnostic.op = op;
    if (argument) |arg| diagnostic.argument = arg;

    if (eqlIgnoreCase(op, "db")) {
        // argument must be an integer from -99999 to 99999
        const arg = argument orelse return error.DirectiveExpectedAgument;
        const word = std.fmt.parseInt(Word, arg, 10) catch |err| switch (err) {
            error.InvalidCharacter => return error.DbBadArgType,
            error.Overflow => return error.DbOutOfRange,
        };
        if (word > 99999 or word < -99999) return error.DbOutOfRange;
        return .{ .define_byte = word };
    }

    if (eqlIgnoreCase(op, "ds")) {
        // argument must be an integer in range [0, 999]
        const arg = argument orelse return error.DirectiveExpectedAgument;
        const n = std.fmt.parseInt(usize, arg, 10) catch return error.DsOutOfRange;
        if (n > 900) return error.DsOutOfRange;
        return .{ .define_storage = n };
    }

    if (eqlIgnoreCase(op, "dc")) {
        const arg = argument orelse return error.DirectiveExpectedAgument;
        return .{ .define_characters = arg[0..] };
    }

    // not a directive
    const mnemonic = Mnemonic.fromString(op) orelse return error.UnknownInstruction;

    const arg = argument orelse return .{
        .instruction_1 = try encodeInstruction(mnemonic, .{ .nil = {} }),
    };

    // determine whether argument is a number or label
    if (std.fmt.parseInt(Argument, arg, 10)) |number| {
        if (number < 0 or number > 999) return error.ArgumentOutOfRange;
        return .{
            .instruction_1 = try encodeInstruction(mnemonic, .{ .imm = number }),
        };
    } else |err| switch (err) {
        error.Overflow => return error.ArgumentOutOfRange,
        error.InvalidCharacter => return .{
            // TODO for now assume argument is a label
            .instruction_2 = .{
                .mnemonic = mnemonic,
                .label_arg = arg,
                .destination = undefined,
                .line_no = undefined,
            },
        },
    }
}

pub const ParserState = enum(usize) { s0, lb, s1, s2, op, s3, ar, st, es, s4, xx, oo };

const IxPair = struct {
    start: usize = 0,
    end: usize = 0,

    fn slice(self: IxPair, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }

    fn extend(self: IxPair) IxPair {
        return .{ .start = self.start, .end = self.end + 1 };
    }

    fn init(i: usize, len: usize) IxPair {
        return .{ .start = i, .end = i + len };
    }

    fn extendOrInit(x: ?IxPair, i: usize, len: usize) IxPair {
        return if (x) |self| self.extend() else IxPair.init(i, len);
    }
};

pub fn separateParts(line: []const u8, diagnostic: *Diagnostic) AssemblyError!Parts {
    var label_or_op: ?IxPair = null;
    var op: ?IxPair = null;
    var arg: ?IxPair = null;
    var is_label: bool = false;

    var state: ParserState = .s0;

    for (line) |char, i| {
        if (char == '\r') break;
        if (state == .st and char != '\\') arg = IxPair.extendOrInit(arg, i, 1);
        if (state == .es) arg = IxPair.extendOrInit(arg, i, 1);

        // Tabularized implementation of an FSA
        const state_transition: [10]ParserState = switch (char) {
            '\x00'...'\x08', '\x0a'...'\x1f', '\x7f'...'\xff' => {
                diagnostic.byte = char;
                return error.BadByte;
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
            diagnostic.byte = char;
            return error.UnexpectedCharacter;
        }
        if (state == .oo) break;

        if (state == .s2) is_label = true;

        if (state == .lb) label_or_op = IxPair.extendOrInit(label_or_op, i, 1);
        if (state == .op) op = IxPair.extendOrInit(op, i, 1);
        if (state == .ar) arg = IxPair.extendOrInit(arg, i, 1);
    }

    return .{
        .label = if (is_label) (if (label_or_op) |label| label.slice(line) else null) else null,
        .op = if (if (is_label) op else label_or_op) |opix| opix.slice(line) else null,
        .argument = if (arg) |argix| argix.slice(line) else null,
    };
}

fn wrapNull(src: []const u8) ?[]const u8 {
    return if (src.len > 0) src else null;
}

const activeTag = std.meta.activeTag;
pub fn encodeInstruction(mnemonic: Mnemonic, op: OpData) !Word {
    const arg: Word = switch (op) {
        .nil => 0,
        .imm, .adr => |word| word,
    };

    const opcode: Word = try switch (mnemonic) {
        .stop => if (activeTag(op) == .nil) @as(Word, 0) else error.DislikesOperand,
        .ld => opcode_val(op, 1),
        .ldi => opcode_adr(op, 2),
        .lda => opcode_adr(op, 3),
        .st => opcode_adr(op, 4),
        .sti => opcode_adr(op, 5),
        .add => opcode_val(op, 6),
        .sub => opcode_val(op, 7),
        .mul => opcode_val(op, 8),
        .div => opcode_val(op, 9),
        .in => if (activeTag(op) == .nil) @as(Word, 10) else error.DislikesOperand,
        .out => if (activeTag(op) == .nil) @as(Word, 11) else error.DislikesOperand,
        .jmp => opcode_adr(op, 12),
        .jg => opcode_adr(op, 13),
        .jl => opcode_adr(op, 14),
        .je => opcode_adr(op, 15),
        .call => opcode_adr(op, 16),
        .ret => if (activeTag(op) == .nil) @as(Word, 17) else error.DislikesOperand,
        .push => switch (op) {
            .nil => @as(Word, 18),
            .adr => @as(Word, 24),
            .imm => error.DislikesImmediate,
        },
        .pop => switch (op) {
            .nil => @as(Word, 19),
            .adr => @as(Word, 25),
            .imm => error.DislikesImmediate,
        },
        .ldparam => if (activeTag(op) == .imm) @as(Word, 20) else error.NeedsImmediate,
        .jge => opcode_adr(op, 21),
        .jle => opcode_adr(op, 22),
        .jne => opcode_adr(op, 23),
        .pusha => opcode_adr(op, 26),
    };

    return encodeOpArg(opcode, arg);
}

fn opcode_val(op: OpData, opcode_low: Word) error{NeedsOperand}!Word {
    return switch (op) {
        .nil => error.NeedsOperand,
        .imm => opcode_low + 90,
        .adr => opcode_low,
    };
}

fn opcode_adr(op: OpData, opcode: Word) error{RequiresLabel}!Word {
    return if (activeTag(op) == .adr) opcode else error.RequiresLabel;
}

const Mnemonic = enum {
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
    jge,
    jle,
    jne,
    call,
    ret,
    push,
    pop,
    ldparam,
    pusha,

    pub fn fromString(src: []const u8) ?Mnemonic {
        if (eqlIgnoreCase(src, "stop")) return .stop;
        if (eqlIgnoreCase(src, "ld")) return .ld;
        if (eqlIgnoreCase(src, "ldi")) return .ldi;
        if (eqlIgnoreCase(src, "lda")) return .lda;
        if (eqlIgnoreCase(src, "st")) return .st;
        if (eqlIgnoreCase(src, "sti")) return .sti;
        if (eqlIgnoreCase(src, "add")) return .add;
        if (eqlIgnoreCase(src, "sub")) return .sub;
        if (eqlIgnoreCase(src, "mul")) return .mul;
        if (eqlIgnoreCase(src, "div")) return .div;
        if (eqlIgnoreCase(src, "in")) return .in;
        if (eqlIgnoreCase(src, "out")) return .out;
        if (eqlIgnoreCase(src, "jmp")) return .jmp;
        if (eqlIgnoreCase(src, "jg")) return .jg;
        if (eqlIgnoreCase(src, "jl")) return .jl;
        if (eqlIgnoreCase(src, "je")) return .je;
        if (eqlIgnoreCase(src, "jge")) return .jge;
        if (eqlIgnoreCase(src, "jle")) return .jle;
        if (eqlIgnoreCase(src, "jne")) return .jne;
        if (eqlIgnoreCase(src, "call")) return .call;
        if (eqlIgnoreCase(src, "ret")) return .ret;
        if (eqlIgnoreCase(src, "push")) return .push;
        if (eqlIgnoreCase(src, "pop")) return .pop;
        if (eqlIgnoreCase(src, "ldparam")) return .ldparam;
        if (eqlIgnoreCase(src, "pusha")) return .pusha;
        return null;
    }

    pub fn toString(self: Mnemonic) []const u8 {
        return switch (self) {
            .stop => "stop",
            .ld => "ld",
            .ldi => "ldi",
            .lda => "lda",
            .st => "st",
            .sti => "sti",
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .in => "in",
            .out => "out",
            .jmp => "jmp",
            .jg => "jg",
            .jl => "jl",
            .je => "je",
            .jge => "jge",
            .jle => "jle",
            .jne => "jne",
            .call => "call",
            .ret => "ret",
            .push => "push",
            .pop => "pop",
            .ldparam => "ldparam",
            .pusha => "pusha",
        };
    }
};

test "everything compiles" {
    std.testing.refAllDecls(@This());
}
