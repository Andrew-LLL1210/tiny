const std = @import("std");
const Word = @import("machine.zig").Word;
const Arg = @import("machine.zig").Ptr;

pub const Operation = union(enum) {
    stop,
    load: Value,
    store: VirtualAddress,
    add: Value,
    subtract: Value,
    multiply: Value,
    divide: Value,
    in,
    out,
    jump: JmpArgs,
    call: Address,
    @"return",
    push: Value,
    pop: ?Address,
    load_parameter: Arg,
};

pub const Value = union(enum) {
    accumulator,
    immediate: Arg,
    address: Arg,
    indirect: Arg,
};

pub const VirtualAddress = union(enum) {
    address: Arg,
    indirect: Arg,
    accumulator,
};

pub const Address = Arg;

pub const JmpArgs = struct {
    address: Address,
    condition: ?std.math.CompareOperator,
};

const DecodeError = error{ CannotDecode, WordOutOfRange };
pub fn decode(instruction: Word) DecodeError!Operation {
    if (instruction < 0 or instruction > 99999) return DecodeError.WordOutOfRange;
    const positive = @intCast(u24, instruction);
    const opcode = positive / 1000;
    const arg = @truncate(Arg, positive % 1000);
    const value: Value = if (opcode >= 90) .{ .immediate = arg } else .{ .address = arg };
    return switch (opcode) {
        0 => .{ .stop = {} },
        1, 91 => .{ .load = value },
        2 => .{ .load = .{ .indirect = arg } },
        3 => .{ .load = .{ .immediate = arg } },
        4 => .{ .store = .{ .address = arg } },
        5 => .{ .store = .{ .indirect = arg } },
        6, 96 => .{ .add = value },
        7, 97 => .{ .subtract = value },
        8, 98 => .{ .multiply = value },
        9, 99 => .{ .divide = value },
        10 => .{ .in = {} },
        11 => .{ .out = {} },
        12...15, 21...23 => .{ .jump = .{
            .address = arg,
            .condition = switch (opcode) {
                12 => null,
                13 => .gt,
                14 => .lt,
                15 => .eq,
                21 => .gte,
                22 => .lte,
                23 => .neq,
                else => unreachable,
            },
        } },
        16 => .{ .call = arg },
        17 => .{ .@"return" = {} },
        18 => .{ .push = .{ .accumulator = {} } },
        19 => .{ .pop = null },
        20 => .{ .load_parameter = arg },
        24 => .{ .push = .{ .address = arg } },
        25 => .{ .pop = arg },
        26 => .{ .push = .{ .immediate = arg } },
        else => DecodeError.CannotDecode,
    };
}

pub fn encodeOpArg(op: Word, arg: Word) Word {
    return 1000 * op + arg;
}

test "everything compiles" {
    std.testing.refAllDecls(@This());
}

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test decode {
    try expectEqual(Operation{ .stop = {} }, try decode(0));
    try expectEqual(Operation{ .call = 42 }, try decode(16042));
    try expectEqual(Operation{ .add = .{ .address = 200 } }, try decode(6200));
    try expectEqual(Operation{ .load = .{ .indirect = 140 } }, try decode(2140));
    try expectEqual(Operation{ .jump = .{
        .address = 300,
        .condition = .gte,
    } }, try decode(21300));
    try expectEqual(Operation{ .push = .{ .accumulator = {} } }, try decode(18000));
    try expectError(error.CannotDecode, decode(51000));
}
