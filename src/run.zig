const std = @import("std");

/// A Word is in the range [-10000, 10000];
pub const Word = i32;

pub fn runMachine(
    listing: Listing,
    stdin: File.Reader,
    stdout: File.Writer,
    reporter: *const Reporter,
) ReportedError!void {
    var memory: [900]?Word = .{null} ** 900;
    var ip: u32 = 0;
    var acc: ?Word = null;
    var sp: u32 = 899;
    _ = sp;
    var bp: u32 = 899;
    _ = bp;

    for (listing) |entry| memory[entry.ip] = entry.word;

    while (true) {
        const m_ = memory[ip];
        if (m_ == null or m_.? < 0 or m_.? > 99999)
            return reporter.reportIp(ip, non_exe_instruction_msg, .{ip});

        const cur_ip = ip;
        const instruction: u32 = @intCast(m_.?);
        ip += 1;

        const op = opFromCode(instruction / 1000);
        const arg = instruction % 1000;

        // if acc need be nonnull for semantic reasons, let's assert that now
        switch (op) {
            .ld, .ldi, .stop, .lda, .ld_imm, .in, .ret, .jmp, .pop, .push_addr, .pop_addr, .pusha, .ldparam => {},
            .call => {
                if (arg == 925 or arg == 950) if (acc == null)
                    return Reporter.reportIp(cur_ip, "Acc is null", .{});
            },
            // zig fmt: off
            .st, .sti, .add, .sub, .mul, .div, .add_imm, .sub_imm,
            .mul_imm, .div_imm, .jg, .jl, .je, .jge, .jle, .jne, .push => {
                if (acc == null) return reporter.reportIp(cur_ip, "ACC is null", .{});
            },
            // zig fmt: on
        }

        // for any operations where arg refers to a label,
        // we can assume that arg is within bounds, since it was parsed successfully.
        switch (op) {
            .stop => return,
            .ld => acc = memory[arg] orelse return reporter.reportIp(cur_ip, "Load of null value", .{}),
            .st => memory[arg] = acc,
            .lda, .ld_imm => acc = arg,

            // we won't worry about overflow until after the switch
            .add => acc.? += memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg),
            .sub => acc.? -= memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg),
            .mul => acc.? *= memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg),
            .div => acc.? /= memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg),
            .add_imm => acc.? += arg,
            .sub_imm => acc.? -= arg,
            .mul_imm => acc.? *= arg,
            .div_imm => acc.? /= arg,

            .ldi => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                acc = memory(word);
            } else return reporter.reportIp(cur_ip, "Attempt to read non-existant address {?d}", .{memory[arg]}),
            .sti => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                memory[word] = acc;
            } else return reporter.reportIp(cur_ip, "Attempt to write non-existant address {?d}", .{memory[arg]}),

            .in => acc = stdin.readByte() catch |err|
                return reporter.reportIp(cur_ip, "Failed to get input byte: {s}", .{@errorName(err)}),
            .out => if (acc) |byte| if (byte >= 0 and byte < 128) {
                stdout.writeByte(@intCast(acc.?)) catch |err|
                    return reporter.reportIp(cur_ip, "Failed to output byte: {s}", .{@errorName(err)});
            } else return reporter.reportIp(cur_ip, "Cannot output: ACC is not ASCII", .{}),

            // zig fmt: off
            .jmp => ip = arg,
            .jg => if (acc) |word| if (word > 0) { ip = arg; },
            .jl => if (acc) |word| if (word < 0) { ip = arg; },
            .je => if (acc) |word| if (word == 0) { ip = arg; },
            .jge => if (acc) |word| if (word >= 0) { ip = arg; },
            .jle => if (acc) |word| if (word <= 0) { ip = arg; },
            .jne => if (acc) |word| if (word != 0) { ip = arg; },
            // zig fmt: on

            .call => switch (arg) {
                900 => stdout.print("{d}", .{acc}) catch |err|
                    return reporter.reportIp(cur_ip, "Failed to output: {s}", .{@errorName(err)}),

                // TODO convert the rest of it
                925 => {
                    // printString
                    if (self.acc < 0 or self.acc >= 900) return RuntimeError.IndexOutOfBounds;
                    var ix: u16 = @intCast(self.acc);
                    defer self.acc = ix;

                    while (self.memory[ix] > 0 and self.memory[ix] < 128) : (ix += 1) {
                        try out.writeByte(@intCast(self.memory[ix]));
                    }
                },
                950 => {
                    // inputIntegeri TODO implement negatives
                    var number: Word = 0;

                    while (in.readByte()) |byte| {
                        const digit = switch (byte) {
                            '0'...'9' => byte - '0',
                            ' ', '\t', '\n', '\r' => break,
                            else => return RuntimeError.IllegalByte,
                        };
                        number = number * 10 + digit;
                    } else |err| return err;

                    self.acc = number;
                },
                975 => {
                    // inputString
                    if (self.acc < 0 or self.acc >= 900) return RuntimeError.IndexOutOfBounds;
                    var ix: u16 = @intCast(self.acc);
                    defer self.acc = ix;

                    while (in.readByte()) |byte| {
                        if (byte == '\r') continue;
                        if (byte == '\n') {
                            self.memory[ix] = 0;
                            break;
                        }
                        self.memory[ix] = byte;
                        ix += 1;
                    } else |err| return err;
                },
                else => {
                    if (arg >= 900) return error.IndexOutOfBounds;

                    self.sp -= 2;
                    self.memory[self.sp + 1] = self.ip;
                    self.memory[self.sp] = self.bp;
                    self.bp = self.sp;
                    self.ip = @intCast(arg);
                },
            },
            17 => {
                self.sp = self.bp;
                self.bp = @intCast(self.memory[self.sp]);
                self.ip = @intCast(self.memory[self.sp + 1]);
                self.sp += 2;
            },
            18, 24, 26 => {
                const value = switch (opcode) {
                    18 => self.acc,
                    24 => try get(&self.memory, arg),
                    26 => arg,
                    else => unreachable,
                };

                self.sp -= 1;
                try put(&self.memory, self.sp, value);
            },
            19, 25 => {
                const value = try get(&self.memory, self.sp);
                self.sp += 1;

                switch (opcode) {
                    19 => self.acc = value,
                    25 => try put(&self.memory, arg, value),
                    else => unreachable,
                }
            },
            20 => {
                self.acc = self.memory[self.bp + @as(Ptr, @intCast(arg)) + 1];
            },
            else => return InstructionError.InvalidOpcode,
        }
    }
}

const File = std.fs.File;
const Listing = @import("parse.zig").Listing;
const Reporter = @import("report.zig").Reporter;
const ReportedError = Reporter.ReportedError;

const overflow_msg = "Overflow";
const non_exe_instruction_msg = "Reached a non-executable instruction at address {d}";

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
