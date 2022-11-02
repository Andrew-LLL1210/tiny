const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Tuple = std.meta.Tuple;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;

pub fn main() !void {
    const program = &programs.print_integer;

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var machine = Machine.init();
    assembleTo(&machine.memory, program);
    machine.acc = 342;
    try machine.run(stdin, stdout);

    // try stdout.writeAll("\nMemory section 100..120\n");
    // for (machine.memory[100..120]) |x| try stdout.print("{d}, ", .{x});
    // try stdout.writeAll("\n");
}

pub const programs = struct {
    const nothing = 0;
    /// Reads a string from the input string into memory starting at the address indicated by the accumulator.
    /// The string will be null-terminated. The stream is read until a null or newline character;
    ///     if a newline character is found, the written string will end with a newline.
    /// After this subroutine returns, the accumulator contains the address at the end of the string;
    ///     that is, it points to the null sentinel.
    /// Calling this subroutine multiple times in a row has the effect of requesting multiple lines of input.
    ///     the string will contain newlines and have only one null sentinel, at the very end.
    pub const inputString = 975;
    pub const input_string = blk: {
        const read_loop = inputString + 1;
        const read_loop_end = inputString + 15;
        const if_1_end = inputString + 14;
        const string = inputString + 17;
        const char = inputString + 18;
        break :blk [_]Operation{
            Operation.init(.st_to, string),
            Operation.init(.in, nothing), // read_loop
            Operation.init(.st_to, char),
            Operation.init(.sti_to, string),
            Operation.init(.je_to, read_loop_end), // exit 1
            Operation.init(.ld_from, string),
            Operation.init(.add_imm, 1),
            Operation.init(.st_to, string),
            Operation.init(.ld_from, char), // if_1
            Operation.init(.sub_imm, '\n'),
            Operation.init(.jne_to, if_1_end),
            Operation.init(.ld_imm, 0),
            Operation.init(.sti_to, string),
            Operation.init(.jmp_to, read_loop_end), // exit 2
            Operation.init(.jmp_to, read_loop), // if_1_end
            Operation.init(.ld_from, string), // read_loop_end
            Operation.init(.ret, nothing),
            // string
            // char
        };
    };

    /// Prints a null-terminated string from memory starting at the address indicated in the accumulator.
    pub const printString = 925;
    pub const print_string = blk: {
        const loop = printString + 1;
        const loop_end = printString + 8;
        const string = printString + 9;
        break :blk [_]Operation{
            Operation.init(.st_to, string),
            Operation.init(.ldi_from, string), // loop
            Operation.init(.je_to, loop_end),
            Operation.init(.out, nothing),
            Operation.init(.ld_from, string),
            Operation.init(.add_imm, 1),
            Operation.init(.st_to, string),
            Operation.init(.jmp_to, loop),
            Operation.init(.ret, nothing), // loop_end
            // string
        };
    };

    /// Naive version.
    pub const printInteger = 900;
    pub const print_integer = blk: {
        const value = printInteger + 17;
        const q = printInteger + 18;
        const power_ten = printInteger + 19;
        const loop = 3;
        break :blk [_]Operation{
            Operation.init(.st_to, value),
            Operation.init(.ld_imm, 100),
            Operation.init(.mul_imm, 100),
            Operation.init(.st_to, power_ten), // loop
            Operation.init(.ld_from, value),
            Operation.init(.div_by, power_ten),
            Operation.init(.add_imm, '0'),
            Operation.init(.out, nothing),
            Operation.init(.sub_imm, '0'),
            Operation.init(.mul_by, power_ten),
            Operation.init(.st_to, q),
            Operation.init(.ld_from, value),
            Operation.init(.sub_by, q),
            Operation.init(.st_to, value),
            Operation.init(.ld_from, power_ten),
            Operation.init(.div_imm, 10),
            Operation.init(.jne_to, loop),
            Operation.init(.stop, nothing),
            // value
            // q
            // power_ten
        };
    };

    /// Naive version.
    pub const inputInteger = 950;
    pub const input_integer = blk: {
        break :blk [_]Operation{};
    };
};

pub const Machine = struct {
    memory: [1000]u24,
    ip: u16,
    acc: u24,
    sp: u16,
    bp: u16,

    // const rom: [100]u24 = blk: {
    //     var _rom: [100]u24 = undefined;
    //     assembleTo(_rom[programs.printString - 900 ..], &programs.print_string);
    //     assembleTo(_rom[programs.inputString - 900 ..], &programs.input_string);
    //     break :blk _rom;
    // };

    pub fn init() Machine {
        var machine: Machine = .{
            .memory = undefined,
            .ip = 0,
            .acc = undefined,
            .sp = 900,
            .bp = 900,
        };
        // build rom
        const memory: []u24 = machine.memory[0..];
        assembleTo(memory[programs.printString..], &programs.print_string);
        assembleTo(memory[programs.inputString..], &programs.input_string);
        assembleTo(memory[programs.inputInteger..], &programs.input_integer);
        assembleTo(memory[programs.inputInteger..], &programs.input_integer);
        return machine;
    }

    const Exit = error{Stop};

    pub fn run(self: *Machine, in: Reader, out: Writer) !void {
        while (self.cycle(in, out)) |_| {} else |err| switch (err) {
            Machine.Exit.Stop => {},
            else => return err,
        }
    }

    pub fn cycle(self: *Machine, in: Reader, out: Writer) !void {
        const instruction = decodeOne(self.memory[self.ip]);
        self.ip += 1;
        return self.executeOperation(instruction, in, out);
    }

    pub fn executeOperation(
        self: *Machine,
        operation: Operation,
        in: Reader,
        out: Writer,
    ) !void {
        const arg = operation.arg;
        switch (operation.op) {
            .stop => return Exit.Stop,
            .ld_from => self.acc = self.memory[arg],
            .ld_imm, .lda_of => self.acc = arg,
            .st_to => self.memory[arg] = self.acc,
            .sti_to => self.memory[self.memory[arg]] = self.acc,
            .add_by => self.acc +%= self.memory[arg],
            .sub_by => self.acc -%= self.memory[arg],
            .mul_by => self.acc *%= self.memory[arg],
            .div_by => self.acc /= self.memory[arg],
            .add_imm => self.acc +%= arg,
            .sub_imm => self.acc -%= arg,
            .mul_imm => self.acc *%= arg,
            .div_imm => self.acc /= arg,
            .ldi_from => self.acc = self.memory[self.memory[arg]],
            .in => self.acc = try in.readByte(),
            .out => try out.writeByte(@truncate(u8, self.acc)),
            .jmp_to => self.ip = arg,
            .je_to => {
                if (self.acc == 0) self.ip = arg;
            },
            .jne_to => {
                if (self.acc != 0) self.ip = arg;
            },
            .call => {
                self.sp -= 1;
                self.memory[self.sp] = self.ip;
                self.sp -= 1;
                self.memory[self.sp] = self.bp;
                self.bp = self.sp;
                self.ip = arg;
            },
            .ret => {
                self.sp = self.bp;
                self.bp = @truncate(u16, self.memory[self.sp]);
                self.sp += 1;
                self.ip = @truncate(u16, self.memory[self.sp]);
                self.sp += 1;
            },
            else => @panic("operation not implemented"),
        }
    }
};

pub const Op = enum(u8) {
    stop = 00,
    ld_from,
    ldi_from,
    lda_of,
    st_to,
    sti_to,
    add_by,
    sub_by,
    mul_by,
    div_by,
    in,
    out,
    jmp_to,
    jg_to,
    jl_to,
    je_to,
    call,
    ret,
    push,
    pop,
    ldparam_no,
    jge_to,
    jle_to,
    jne_to,
    push_from,
    pop_to,
    pusha_of,
    ld_imm = 91,
    add_imm = 96,
    sub_imm,
    mul_imm,
    div_imm,
};

pub const Operation = struct {
    op: Op,
    arg: u16,
    pub fn init(op: Op, arg: u16) Operation {
        return .{ .op = op, .arg = arg };
    }
};

pub fn decode(input: []const u24, alloc: Allocator) ![]const Operation {
    var list = ArrayList(Operation).init(alloc);
    for (input) |instruction| {
        const op = @intToEnum(Op, instruction / 1000);
        const arg = @truncate(u16, instruction % 1000);
        try list.append(.{ .op = op, .arg = arg });
    }
    return list.toOwnedSlice();
}

pub fn decodeOne(instruction: u24) Operation {
    const op = @intToEnum(Op, instruction / 1000);
    const arg = @truncate(u16, instruction % 1000);
    return .{ .op = op, .arg = arg };
}

pub fn assembleOne(input: Operation) u24 {
    return 1000 * @intCast(u24, @enumToInt(input.op)) + input.arg;
}

pub fn assembleTo(dst: []u24, input: []const Operation) void {
    for (input) |op, i| dst[i] = assembleOne(op);
    // const instructions = try assemble(input, alloc);
    // defer alloc.free(instructions);
    // std.mem.copy(u24, dst, instructions);
}

test "decode" {
    const input = [_]u24{ 91003, 98003 };
    const decoded = try decode(&input, std.testing.allocator);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Operation, &[_]Operation{
        .{ .op = .ld_imm, .arg = 3 },
        .{ .op = .mul_imm, .arg = 3 },
    }, decoded);
}
