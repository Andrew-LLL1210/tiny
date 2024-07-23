const std = @import("std");
pub const parse = @import("tiny/parse.zig");

pub const run = @import("tiny/run.zig");

pub const max_read_size = std.math.maxInt(usize);
pub const Word = run.Word;
pub const Node = parse.Node;
pub const Air = parse.Air;
pub const Error = parse.Error;
pub const Machine = run.Machine;
pub const Span = @import("tiny/span.zig").Span;
pub const Mnemonic = parse.Mnemonic;

const printInteger = 900;
const printString = 925;
const inputInteger = 950;
const inputString = 975;

pub fn assemble(air: Air) struct { Machine, [900]?usize } {
    var machine_impl: Machine = .{};
    var machine = std.ArrayListUnmanaged(?Word).initBuffer(&machine_impl.memory);
    var label_positions: [900]Word = undefined;
    @memcpy(label_positions[0..4], &[4]Word{ printInteger, printString, inputInteger, inputString });
    var deferred_labels_impl: [900][2]usize = undefined;
    var deferred_labels = std.ArrayListUnmanaged([2]usize).initBuffer(&deferred_labels_impl);
    var index_map_impl: [900]?usize = .{null} ** 900;
    var index_map = std.ArrayListUnmanaged(?usize).initBuffer(&index_map_impl);

    for (air.statements, 0..) |statement, statement_idx| switch (statement) {
        .comment => {},
        .mark_label => |label_idx| {
            label_positions[label_idx] = @intCast(machine.items.len);
        },
        .operation => |operation| {
            var opcode: Word = @intFromEnum(operation[0]);
            if (std.EnumSet(Mnemonic).initMany(&.{ .ld, .add, .sub, .mul, .div })
                .contains(operation[0]) and
                operation[1] == .number)
                opcode += 90;
            if (std.EnumSet(Mnemonic).initMany(&.{ .push, .pop })
                .contains(operation[0]) and
                operation[1] == .label)
                opcode += 6;

            const arg: Word = switch (operation[1]) {
                .label => |label_idx| blk: {
                    deferred_labels.appendAssumeCapacity(.{ machine.items.len, label_idx });
                    break :blk 0;
                },
                .number => |number| number,
                .none => 0,
            };

            machine.appendAssumeCapacity(opcode * 1000 + arg);
            index_map.appendAssumeCapacity(statement_idx);
        },
        .directive => |directive| switch (directive) {
            .dc => |string_idx| {
                for (air.strings[string_idx]) |char|
                    machine.appendAssumeCapacity(char);
                machine.appendAssumeCapacity(0);
                index_map.appendNTimesAssumeCapacity(statement_idx, air.strings[string_idx].len + 1);
            },
            .db => |number| {
                machine.appendAssumeCapacity(number);
                index_map.appendAssumeCapacity(statement_idx);
            },
            .ds => |length| {
                machine.appendNTimesAssumeCapacity(null, length);
                index_map.appendAssumeCapacity(statement_idx);
            },
        },
    };

    for (deferred_labels.items) |mach_labl| {
        machine_impl.memory[mach_labl[0]] =
            machine_impl.memory[mach_labl[0]].? +
            label_positions[mach_labl[1]];
    }

    return .{ machine_impl, index_map_impl };
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
