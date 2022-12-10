const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;

const Word = u24;

const Operation = @This();

pub const Op = enum(u8) {
    stop = 0,
    ld_from = 1,
    ldi_from = 2,
    lda_of = 3,
    st_to = 4,
    sti_to = 5,
    add_by = 6,
    sub_by = 7,
    mul_by = 8,
    div_by = 9,
    in = 10,
    out = 11,
    jmp_to = 12,
    jg_to = 13,
    jl_to = 14,
    je_to = 15,
    call = 16,
    ret = 17,
    push = 18,
    pop = 19,
    ldparam_no = 20,
    jge_to = 21,
    jle_to = 22,
    jne_to = 23,
    push_from = 24,
    pop_to = 25,
    pusha_of = 26,
    ld_imm = 91,
    add_imm = 96,
    sub_imm = 97,
    mul_imm = 98,
    div_imm = 99,
};

op: Op,
arg: u16,

pub fn decodeSlice(input: []const Word, alloc: Allocator) ![]const Operation {
    var list = ArrayList(Operation).init(alloc);
    for (input) |instruction| {
        const op = @intToEnum(Op, instruction / 1000);
        const arg = @truncate(u16, instruction % 1000);
        try list.append(.{ .op = op, .arg = arg });
    }
    return list.toOwnedSlice();
}

pub fn decode(instruction: Word) Operation {
    const op = @intToEnum(Op, instruction / 1000);
    const arg = @truncate(u16, instruction % 1000);
    return .{ .op = op, .arg = arg };
}

pub fn encode(input: Operation) Word {
    return 1000 * @intCast(Word, @enumToInt(input.op)) + input.arg;
}

test "decode" {
    const input = [_]Word{ 91003, 98003 };
    const decoded = try Operation.decodeSlice(&input, std.testing.allocator);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Operation, &[_]Operation{
        .{ .op = .ld_imm, .arg = 3 },
        .{ .op = .mul_imm, .arg = 3 },
    }, decoded);
}
