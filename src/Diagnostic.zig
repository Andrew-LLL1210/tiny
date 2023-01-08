const Diagnostic = @This();
const AssemblyError = @import("tiny.zig").AssemblyError;
const RuntimeError = @import("machine.zig").RuntimeError;
const Writer = @import("std").fs.File.Writer;
const msg = @import("main.zig").msg;
const Word = @import("machine.zig").Word;
const Ptr = @import("machine.zig").Ptr;
const Machine = @import("machine.zig").Machine;

stderr: Writer,
filepath: []const u8,

label_name: []const u8,
label_prior_line: usize,
instruction: []const u8,
line: usize,
byte: u8,
op: []const u8,
argument: []const u8,

large_int: Word,
overflowed_int: Word,
address: Word,

pub fn printAssemblyErrorMessage(self: *const Diagnostic, err: AssemblyError) !void {
    switch (err) {
        error.DuplicateLabel => {
            try self.writeError(msg.duplicate_label, .{self.label_name});
            try self.writeNote(msg.duplicate_label_note, .{}, self.label_prior_line);
        },
        error.ReservedLabel => try self.writeError(msg.reserved_label, .{self.label_name}),
        error.UnknownLabel => try self.writeError(msg.unknown_label, .{self.label_name}),
        error.UnknownInstruction => try self.writeError(msg.unknown_instruction, .{self.op}),
        error.BadByte => try self.writeError(msg.bad_byte, .{self.byte}),
        error.UnexpectedCharacter => try self.writeError(msg.unexpected_character, .{self.byte}),
        error.DislikesImmediate => try self.writeError(msg.dislikes_immediate, .{self.op}),
        error.DislikesOperand => try self.writeError(msg.dislikes_operand, .{self.op}),
        error.NeedsImmediate => {
            try self.writeError("'{s}' instruction requires an immediate value as its argument", .{self.op});
            try self.writeNote(msg.argument_range_note, .{}, null);
        },
        error.NeedsOperand => try self.writeError("'{s}' instruction requires an operand", .{self.op}),
        error.RequiresLabel => try self.writeError(msg.requires_label, .{self.op}),
        error.DirectiveExpectedAgument => try self.writeError(msg.directive_expected_agument, .{self.op}),
        error.ArgumentOutOfRange => try self.writeError(msg.out_of_range, .{self.argument}),
        error.DbOutOfRange => {
            try self.writeError(msg.out_of_range, .{self.argument});
            try self.writeNote(msg.db_range_note, .{}, null);
        },
        error.DbBadArgType => try self.writeError(msg.db_range_note, .{}),
        error.DsOutOfRange => {
            try self.writeError(msg.out_of_range, .{self.argument});
            try self.writeNote(msg.ds_range_note, .{}, null);
            try self.writeNote(msg.ds_range_note2, .{}, null);
        },
    }
}

pub fn printRuntimeErrorMessage(self: *const Diagnostic, err: RuntimeError, m: *const Machine) !void {
    switch (err) {
        error.Overflow => try self.writeWarning("overflow: {d} -> {d}", .{ self.large_int, self.overflowed_int }),
        error.CannotDecode => try self.writeCrash(msg.cannot_decode, .{
            m.memory[m.ip],
            m.ip,
        }),
        error.DivideByZero => try self.writeCrash(msg.divide_by_zero, .{}),
        error.EndOfStream => try self.writeCrash(msg.end_of_stream, .{}),
        error.InputIntegerTooLarge => try self.writeWarning(msg.input_integer_too_large, .{}),
        error.InputIntegerTooSmall => try self.writeWarning(msg.input_integer_too_small, .{}),
        error.InvalidCharacter => try self.writeCrash(msg.invalid_character, .{}),
        error.InvalidAdress => try self.writeCrash(msg.invalid_adress, .{self.address}),
        error.SegFault => unreachable,
        error.WordOutOfRange => unreachable,
    }
}

fn writeError(self: *const Diagnostic, comptime message: []const u8, args: anytype) !void {
    try self.stderr.print("\x1b[97m{s}:{d}: ", .{ self.filepath, self.line });
    try self.stderr.print(msg.err ++ message, args);
    try self.stderr.writeAll(msg.endl);
}

fn writeNote(self: *const Diagnostic, comptime message: []const u8, args: anytype, alt_line: ?usize) !void {
    try self.stderr.print("\x1b[97m{s}:{d}: ", .{ self.filepath, alt_line orelse self.line });
    try self.stderr.print(msg.note ++ message, args);
    try self.stderr.writeAll(msg.endl);
}

fn writeCrash(self: *const Diagnostic, comptime message: []const u8, args: anytype) !void {
    try self.stderr.print(msg.err ++ message, args);
    try self.stderr.writeAll(msg.endl);
}

fn writeWarning(self: *const Diagnostic, comptime message: []const u8, args: anytype) !void {
    try self.stderr.print(msg.warning ++ message, args);
    try self.stderr.writeAll(msg.endl);
}
