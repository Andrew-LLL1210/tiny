const std = @import("std");
const root = @import("../tiny.zig");

/// A Word is in the range [-10000, 10000];
pub const Word = i32;

pub const Machine = struct {
    memory: [900]?Word = .{null} ** 900,
    ip: u16 = 0,
    acc: ?Word = null,
    sp: u16 = 900,
    bp: u16 = 900,

    pub fn load(listing: []const ?Word) Machine {
        var machine = Machine{};
        for (listing, 0..) |word, i| machine.memory[i] = word;
        return machine;
    }

    pub fn run(
        machine: *Machine,
        stdin: anytype,
        stdout: anytype,
        max_cycles: u32,
    ) Error!void {
        runMachine(machine, stdin, stdout, max_cycles) catch |err| switch (err) {
            Error.stop => {},
            else => return err,
        };
    }
};

fn runMachine(
    machine: *Machine,
    stdin: anytype,
    stdout: anytype,
    max_cycles: u32,
) Error!void {
    for (0..max_cycles) |_| {
        if (machine.ip < 0 or machine.ip >= 900)
            return Error.ip_out_of_bounds;
        const operation_encoded = machine.memory[machine.ip] orelse
            return Error.null_operation;
        if (operation_encoded < 0 or operation_encoded > 99999)
            return Error.invalid_instruction;

        const prev_ip = machine.ip;
        errdefer machine.ip = prev_ip;
        machine.ip += 1;

        const instruction: u32 = @intCast(operation_encoded);
        const op = opFromCode(instruction / 1000) orelse
            return Error.invalid_instruction;

        const operation = op.operation();

        var values: [2]Word = undefined;
        for (operation.inputs, 0..) |location, i|
            values[i] = try location.get(machine, stdin);

        switch (op) {
            .call => try functions.call(&values, machine, stdin, stdout),
            else => try operation.action(&values, machine),
        }

        for (operation.outputs, 0..) |location, i|
            try location.set(machine, stdout, values[i]);
    }

    return Error.halt;
}

const printInteger = 900;
const printString = 925;
const inputInteger = 950;
const inputString = 975;

fn opFromCode(code: u32) ?Op {
    return switch (code) {
        0...26, 91, 96...99 => @enumFromInt(code),
        else => null,
    };
}

pub const Op = enum(u32) {
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
    call,
    ret,
    push,
    pop,
    ldparam,
    jge,
    jle,
    jne,
    push_addr,
    pop_addr,
    pusha,
    ld_imm = 91,
    add_imm = 96,
    sub_imm = 97,
    mul_imm = 98,
    div_imm = 99,

    const Operation = struct {
        inputs: []const Location,
        outputs: []const Location,
        action: *const fn ([]Word, *Machine) Error!void,
    };

    fn init(inputs: anytype, outputs: anytype, action: *const fn ([]Word, *Machine) Error!void) Operation {
        return .{ .inputs = &inputs, .outputs = &outputs, .action = action };
    }

    fn initMove(input: anytype, output: anytype) Operation {
        return init(.{input}, .{output}, functions.move);
    }

    fn operation(op: Op) Operation {
        return switch (op) {
            .stop => init(.{}, .{}, functions.stop),
            .ld => initMove(.arg_d, .acc),
            .ldi => initMove(.arg_d_d, .acc),
            .lda => initMove(.arg, .acc),
            .st => initMove(.acc, .arg_d),
            .sti => initMove(.acc, .arg_d_d),
            .add => init(.{ .acc, .arg_d }, .{.acc}, functions.add),
            .sub => init(.{ .acc, .arg_d }, .{.acc}, functions.sub),
            .mul => init(.{ .acc, .arg_d }, .{.acc}, functions.mul),
            .div => init(.{ .acc, .arg_d }, .{.acc}, functions.div),
            .in => initMove(.io, .acc),
            .out => initMove(.acc, .io),
            .jmp => initMove(.arg, .ip),
            .jg, .jl, .je, .jge, .jle, .jne => init(.{ .acc, .arg }, .{.ip}, functions.jump),

            .call => init(.{.arg}, .{}, functions.move),
            .ret => init(.{}, .{}, functions.ret),
            .push => initMove(.acc, .stack),
            .pop => initMove(.stack, .acc),
            .ldparam => initMove(.param, .acc),
            .push_addr => initMove(.arg_d, .stack),
            .pop_addr => initMove(.stack, .arg_d),
            .pusha => initMove(.arg, .stack),

            .ld_imm => initMove(.arg, .acc),
            .add_imm => init(.{ .acc, .arg }, .{.acc}, functions.add),
            .sub_imm => init(.{ .acc, .arg }, .{.acc}, functions.sub),
            .mul_imm => init(.{ .acc, .arg }, .{.acc}, functions.mul),
            .div_imm => init(.{ .acc, .arg }, .{.acc}, functions.div),
        };
    }
};

const functions = struct {
    fn stop(_: []Word, _: *Machine) Error!void {
        return Error.stop;
    }
    fn move(_: []Word, _: *Machine) Error!void {}
    fn add(xs: []Word, _: *Machine) Error!void {
        xs[0] += xs[1];
    }
    fn sub(xs: []Word, _: *Machine) Error!void {
        xs[0] -= xs[1];
    }
    fn mul(xs: []Word, _: *Machine) Error!void {
        xs[0] *= xs[1];
    }
    fn div(xs: []Word, _: *Machine) Error!void {
        xs[0] = @rem(xs[0], xs[1]);
    }

    fn ret(_: []Word, machine: *Machine) Error!void {
        if (machine.bp + 2 >= 900) return Error.stack_underflow;
        const base_pointer = machine.memory[machine.bp] orelse
            return Error.dereference_is_null;
        const instruction_pointer = machine.memory[machine.bp + 1] orelse
            return Error.dereference_is_null;
        if (base_pointer < 0 or base_pointer >= 900 or
            instruction_pointer < 0 or instruction_pointer >= 900)
            return Error.dereference_out_of_bounds;

        machine.sp = machine.bp + 2;
        machine.bp = @intCast(base_pointer);
        machine.ip = @intCast(instruction_pointer);
    }

    fn jump(xs: []Word, machine: *Machine) Error!void {
        const op: Op = @enumFromInt(@abs(machine.memory[machine.ip - 1].?) / 1000);
        const comp_op: std.math.CompareOperator = switch (op) {
            .jg => .gt,
            .jl => .lt,
            .je => .eq,
            .jge => .gte,
            .jle => .lte,
            .jne => .neq,
            else => unreachable,
        };

        xs[0] = if (std.math.compare(xs[0], comp_op, 0)) xs[1] else machine.ip;
    }

    fn call(xs: []Word, machine: *Machine, stdin: anytype, stdout: anytype) Error!void {
        switch (xs[0]) {
            printInteger => stdout.print("{d}", .{
                machine.acc orelse return Error.acc_is_null,
            }) catch return Error.io_error,

            printString => {
                const addr = machine.acc orelse return Error.acc_is_null;
                if (addr < 0 or addr >= 900) return Error.dereference_out_of_bounds;
                var ix: u16 = @intCast(addr);
                defer machine.acc = ix;

                while (machine.memory[ix]) |word| : (ix += 1) {
                    if (word == 0) break;
                    if (word < 0 or word > 128) return Error.character_out_of_bounds;
                    stdout.writeByte(@intCast(word)) catch return Error.io_error;
                } else return Error.dereference_is_null;
                // TODO am I supposed to increment acc once more for continued printing?
            },

            inputInteger => {
                var buf: [100]u8 = undefined;
                const rline = stdin.readUntilDelimiter(&buf, '\n') catch return Error.io_error;
                const line = std.mem.trim(u8, rline, &std.ascii.whitespace);
                machine.acc = std.fmt.parseInt(Word, line, 10) catch return Error.number_parse_fail;
            },

            inputString => {
                const addr = machine.acc orelse return Error.acc_is_null;
                if (addr < 0 or addr >= 900) return Error.dereference_out_of_bounds;

                var buf = std.BoundedArray(u8, 101).init(0) catch unreachable;
                stdin.streamUntilDelimiter(buf.writer(), '\n', 100) catch return Error.read_too_long;
                buf.append(0) catch return Error.io_error;

                for (buf.slice(), @abs(addr)..) |byte, index| {
                    if (index >= 900) return Error.read_too_long;
                    machine.memory[index] = byte;
                }
            },

            else => |addr| {
                if (addr < 0 or addr >= 900) return Error.dereference_out_of_bounds;
                if (machine.sp < 2) return Error.stack_overflow;

                machine.sp -= 2;
                machine.memory[machine.sp + 1] = @intCast(machine.ip);
                machine.memory[machine.sp] = @intCast(machine.bp);
                machine.bp = machine.sp;
                machine.ip = @intCast(addr);
            },
        }
    }
};

const Location = union(enum) {
    acc,
    arg,
    arg_d,
    arg_d_d,
    io,
    ip,
    stack,
    param,

    fn get(loc: Location, machine: *Machine, stdin: anytype) Error!Word {
        return switch (loc) {
            .acc => machine.acc orelse return Error.acc_is_null,
            .arg => @mod(machine.memory[machine.ip - 1].?, 1000),
            .arg_d => {
                const arg = @mod(machine.memory[machine.ip - 1].?, 1000);
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                return machine.memory[@intCast(arg)] orelse Error.variable_is_null;
            },
            .arg_d_d => {
                var arg = @mod(machine.memory[machine.ip - 1].?, 1000);
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                arg = machine.memory[@intCast(arg)] orelse return Error.variable_is_null;
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                return machine.memory[@intCast(arg)] orelse Error.dereference_is_null;
            },
            .io => stdin.readByte() catch return Error.io_error,
            .ip => machine.ip,
            .stack => {
                if (machine.sp + 1 >= 900) return Error.stack_underflow;
                const res = machine.memory[machine.sp] orelse return Error.dereference_is_null;
                machine.sp += 1;
                return res;
            },
            .param => {
                const arg: u16 = @intCast(@mod(machine.memory[machine.ip - 1].?, 1000));
                if (arg + machine.bp >= 900) return Error.dereference_out_of_bounds;
                return machine.memory[arg + machine.bp] orelse return Error.variable_is_null;
            },
        };
    }

    fn set(loc: Location, machine: *Machine, stdout: anytype, x: Word) Error!void {
        switch (loc) {
            .arg, .param => unreachable,
            .acc => machine.acc = x,
            .arg_d => {
                const arg = @mod(machine.memory[machine.ip - 1].?, 1000);
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                machine.memory[@intCast(arg)] = x;
            },
            .arg_d_d => {
                var arg = @mod(machine.memory[machine.ip - 1].?, 1000);
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                arg = machine.memory[@intCast(arg)] orelse return Error.variable_is_null;
                if (arg < 0 or arg >= 900) return Error.dereference_out_of_bounds;
                machine.memory[@intCast(arg)] = x;
            },
            .io => {
                if (x < 0 or x > 255) return Error.character_out_of_bounds;
                stdout.writeByte(@intCast(x)) catch return Error.io_error;
            },
            .ip => {
                if (x < 0 or x >= 900) return Error.ip_out_of_bounds;
                machine.ip = @intCast(x);
            },
            .stack => {
                if (machine.sp == 0) return Error.stack_overflow;
                machine.sp -= 1;
                machine.memory[machine.sp] = x;
            },
        }
    }
};

const Error = error{
    stop,
    io_error,
    dereference_out_of_bounds,
    variable_is_null,
    dereference_is_null,
    stack_underflow,
    stack_overflow,
    character_out_of_bounds,
    ip_out_of_bounds,
    acc_is_null,
    read_too_long,
    number_parse_fail,
    halt,
    null_operation,
    invalid_instruction,
};

fn readStub(_: void, _: []u8) error{}!usize {
    unreachable;
}

test runMachine {
    const out = std.io.getStdErr().writer();
    const in = std.io.GenericReader(void, error{}, readStub){ .context = {} };
    // machine that STOPS
    var machine = Machine.load(&.{0});

    try runMachine(&machine, in, out);
}
