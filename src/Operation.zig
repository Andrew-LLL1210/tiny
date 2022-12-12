const std = @import("std");
const Word = @import("Machine.zig").Word;

const Operation = @This();

op: Op,
arg: u16,

pub fn decode(instruction: Word) Operation {
    const op = @intToEnum(Op, instruction / 1000);
    const arg = @truncate(u16, instruction % 1000);
    return .{ .op = op, .arg = arg };
}

pub fn encode(input: Operation) Word {
    return 1000 * @intCast(Word, @enumToInt(input.op)) + input.arg;
}

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
