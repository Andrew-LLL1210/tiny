const std = @import("std");
const Word = @import("Machine.zig").Word;
const Arg = @import("Machine.zig").Ptr;

const Operation = union(enum) {
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

const Value = union(enum) {
    accumulator,
    immediate: Arg,
    address: Arg,
    indirect: Arg,
};

const VirtualAddress = union(enum) {
    address: Arg,
    indirect: Arg,
};

const Address = Arg;

const JmpArgs = struct {
    address: Address,
    condition: ?std.math.CompareOperator,
};

pub fn decode(instruction: Word) ?Operation {
    if (instruction < 0 or instruction > 99999) return null;
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
        else => null,
    };
}

fn encode(input: Operation) ?Word {
    return switch (input) {
        .stop => encodeOpArg(10, 0),
        .load => |load| switch (load) {
            .address => |address| encodeOpArg(1, address),
            .immediate => |value| encodeOpArg(2, value),
            .indirect => |address| encodeOpArg(3, address),
            .accumulator => null,
        },
        .store => |store| switch (store) {
            .address => |address| encodeOpArg(4, address),
            .indirect => |address| encodeOpArg(5, address),
        },
        .add, .subtract, .multiply, .divide => |op| {
            const opcode = switch (input) {
                .add => 6,
                .subtract => 7,
                .multiply => 8,
                .divide => 9,
            };
            return switch (op) {
                .immediate => |value| encodeOpArg(90 + opcode, value),
                .address => |address| encodeOpArg(opcode, address),
                else => null,
            };
        },
        .in => encodeOpArg(10, 0),
        .out => encodeOpArg(11, 0),
        .jump => |jump| switch (jump.condition) {
            .always => encodeOpArg(12, jump.address),
            .greater => encodeOpArg(13, jump.address),
            .less => encodeOpArg(14, jump.address),
            .equal => encodeOpArg(15, jump.address),
            .greater_or_equal => encodeOpArg(21, jump.address),
            .less_or_equal => encodeOpArg(22, jump.address),
            .not_equal => encodeOpArg(23, jump.address),
        },
        .call => |address| encodeOpArg(16, address),
        .@"return" => encodeOpArg(17, 0),
        .push => |push| switch (push) {
            .accumulator => encodeOpArg(18, 0),
            .address => encodeOpArg(24, 0),
            else => null,
        },
        .pop => |pop| if (pop) |address| encodeOpArg(25, address) else encodeOpArg(19, 0),
        .load_parameter => |parameter| encodeOpArg(26, parameter),
    };
}

fn encodeOpArg(op: Word, arg: Word) Word {
    return 1000 * op + arg;
}

test "everything compiles" {
    std.testing.refAllDecls(@This());
}

const expectEqual = std.testing.expectEqual;

test decode {
    try expectEqual(Operation{ .stop = {} }, decode(0).?);
    try expectEqual(Operation{ .call = 42 }, decode(16042).?);
    try expectEqual(Operation{ .add = .{ .address = 200 } }, decode(6200).?);
    try expectEqual(Operation{ .load = .{ .indirect = 140 } }, decode(2140).?);
    try expectEqual(Operation{ .jump = .{
        .address = 300,
        .condition = .gte,
    } }, decode(21300).?);
    try expectEqual(Operation{ .push = .{ .accumulator = {} } }, decode(18000).?);
    try expectEqual(@as(?Operation, null), decode(51000));
}

test encode {}
