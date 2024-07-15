const std = @import("std");
const root = @import("../root.zig");

/// A Word is in the range [-10000, 10000];
pub const Word = i32;

pub const Machine = struct {
    memory: [900]?Word = .{null} ** 900,
    ip: u32 = 0,
    acc: ?Word = null,
    sp: u32 = 900,
    bp: u32 = 900,

    pub fn load(listing: []const ?Word) Machine {
        var machine = Machine{};
        std.debug.assert(listing.len <= machine.memory.len);
        for (listing, 0..) |word, i| machine.memory[i] = word;
        return machine;
    }
};

pub fn runMachine(
    machine: *Machine,
    stdin: anytype,
    stdout: anytype,
) !void {
    const m = machine;
    while (true) {
        const m_ = m.memory[m.ip];
        if (m_ == null or m_.? < 0 or m_.? > 99999)
            return error.InvalidInstruction;

        var acc = m.acc;
        defer m.acc = acc;

        const memory = &m.memory;
        const cur_ip = m.ip;
        var next_ip = cur_ip + 1;
        errdefer m.ip = cur_ip;
        defer m.ip = next_ip;

        const instruction: u32 = @intCast(m_.?);
        const op = opFromCode(instruction / 1000) orelse
            return error.InvalidInstruction;
        const arg: u32 = instruction % 1000;

        // if acc need be nonnull for semantic reasons, let's assert that now
        switch (op) {
            .ld, .ldi, .stop, .lda, .ld_imm, .in, .ret, .jmp, .pop, .push_addr, .pop_addr, .pusha, .ldparam => {},
            .call => {
                if (arg == printInteger or arg == printString or arg == inputString) if (acc == null)
                    return error.AccIsNull;
            },
            // zig fmt: off
            .st, .sti, .add, .sub, .mul, .div, .add_imm, .sub_imm, .out,
            .mul_imm, .div_imm, .jg, .jl, .je, .jge, .jle, .jne, .push => {
                if (acc == null) return error.AccIsNull;
            },
            // zig fmt: on
        }

        // for any operations where arg refers to a label,
        // we can assume that arg is within bounds, since it was parsed successfully.
        switch (op) {
            .stop => return,
            .ld => acc = memory[arg] orelse return error.OperatorNull,
            .st => memory[arg] = acc,
            .lda, .ld_imm => acc = @intCast(arg),

            // we won't worry about overflow until after the switch
            .add => acc.? += memory[arg] orelse return error.OperatorNull,
            .sub => acc.? -= memory[arg] orelse return error.OperatorNull,
            .mul => acc.? *= memory[arg] orelse return error.OperatorNull,
            .add_imm => acc.? += @intCast(arg),
            .sub_imm => acc.? -= @intCast(arg),
            .mul_imm => acc.? *= @intCast(arg),

            .div => if (memory[arg]) |word| {
                if (word == 0) return error.DivZero;
                acc = @divTrunc(acc.?, word);
            } else return error.OperatorNull,
            .div_imm => {
                if (arg == 0) return error.DivZero;
                acc = @divTrunc(acc.?, @as(i32, @intCast(arg)));
            },

            .ldi => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                acc = memory[@intCast(word)] orelse return error.LdiNull;
            } else return error.IndirectIllegal,
            .sti => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                memory[@intCast(word)] = acc;
            } else return error.IndirectIllegal,

            .in => acc = stdin.readByte() catch return error.ReadError,
            .out => if (acc) |byte| if (byte >= 0 and byte < 128) {
                stdout.writeByte(@intCast(acc.?)) catch return error.WriteError;
            } else return error.NotAscii,

            // zig fmt: off
            .jmp => next_ip = arg,
            .jg => if (acc) |word| if (word > 0) { next_ip = arg; },
            .jl => if (acc) |word| if (word < 0) { next_ip = arg; },
            .je => if (acc) |word| if (word == 0) { next_ip = arg; },
            .jge => if (acc) |word| if (word >= 0) { next_ip = arg; },
            .jle => if (acc) |word| if (word <= 0) { next_ip = arg; },
            .jne => if (acc) |word| if (word != 0) { next_ip = arg; },
            // zig fmt: on

            .call => switch (arg) {
                printInteger => stdout.print("{d}", .{acc.?}) catch return error.WriteError,

                printString => {
                    if (acc.? < 0 or acc.? >= 900) return error.BadAddress;
                    var ix: u16 = @intCast(acc.?);
                    defer acc = ix;

                    while (memory[ix]) |word| : (ix += 1) {
                        if (word == 0) break;
                        if (word < 0 or word > 128) return error.NotAscii;
                        stdout.writeByte(@intCast(word)) catch return error.WriteError;
                    }
                },

                inputInteger => {
                    var buf: [100]u8 = undefined;
                    const rline = stdin.readUntilDelimiter(&buf, '\n') catch return error.ReadError;
                    const line = std.mem.trim(u8, rline, &std.ascii.whitespace);
                    acc = std.fmt.parseInt(Word, line, 10) catch return error.ParseIntError;
                },

                inputString => {
                    var buf: [100]u8 = undefined;
                    const rline = stdin.readUntilDelimiter(&buf, '\n') catch return error.ReadError;
                    if (acc.? < 0) return error.BadAddress;
                    const addr: usize = @intCast(acc.?);
                    if (addr + rline.len + 1 > memory.len) return error.BadAddress;
                    for (rline, addr..) |byte, index| {
                        memory[index] = byte;
                    }
                    memory[addr + rline.len] = 0;
                },

                else => {
                    if (arg >= 900) return error.BadAddress;

                    m.sp -= 2;
                    memory[m.sp + 1] = @intCast(next_ip);
                    memory[m.sp] = @intCast(m.bp);
                    m.bp = m.sp;
                    next_ip = arg;
                },
            },

            .ret => {
                // TODO detect stack underflow
                m.sp = m.bp;
                m.bp = @intCast(memory[m.sp].?);
                next_ip = @intCast(memory[m.sp + 1].?);
                m.sp += 2;
            },

            .push, .push_addr, .pusha => {
                const value: Word = switch (op) {
                    .push => acc.?,
                    .push_addr => memory[arg].?,
                    .pusha => @intCast(arg),
                    else => unreachable,
                };
                m.sp -= 1;
                memory[m.sp] = value;
            },

            .pop => {
                acc = memory[m.sp];
                m.sp += 1;
            },

            .pop_addr => {
                memory[arg] = memory[m.sp];
                m.sp += 1;
            },

            .ldparam => {
                acc = memory[m.bp + arg + 1];
            },
        }

        if (acc) |value| if (value < -99999 or value > 99999) return error.IntegerOverflow;
    }
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

const Op = enum(u32) {
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
