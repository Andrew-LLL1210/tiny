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

        const op = opFromCode(instruction / 1000) orelse
            return reporter.reportIp(cur_ip, "Invalid opcode {d}", .{instruction / 1000});
        const arg = instruction % 1000;

        // if acc need be nonnull for semantic reasons, let's assert that now
        switch (op) {
            .ld, .ldi, .stop, .lda, .ld_imm, .in, .ret, .jmp, .pop, .push_addr, .pop_addr, .pusha, .ldparam => {},
            .call => {
                if (arg == 925 or arg == 950 or arg == inputString) if (acc == null)
                    return reporter.reportIp(cur_ip, "Acc is null", .{});
            },
            // zig fmt: off
            .st, .sti, .add, .sub, .mul, .div, .add_imm, .sub_imm, .out,
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
            .lda, .ld_imm => acc = @intCast(arg),

            // we won't worry about overflow until after the switch
            .add => acc.? += memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg, .{}),
            .sub => acc.? -= memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg, .{}),
            .mul => acc.? *= memory[arg] orelse return reporter.reportIp(cur_ip, overflow_msg, .{}),
            .add_imm => acc.? += @intCast(arg),
            .sub_imm => acc.? -= @intCast(arg),
            .mul_imm => acc.? *= @intCast(arg),

            .div => if (memory[arg]) |word| {
                if (word == 0) return reporter.reportIp(cur_ip, "Division by zero", .{});
                acc = @divTrunc(acc.?, word);
            } else return reporter.reportIp(cur_ip, overflow_msg, .{}),
            .div_imm => if (memory[arg]) |word| {
                acc = @divTrunc(acc.?, word);
            } else return reporter.reportIp(cur_ip, "Division by zero", .{}),

            .ldi => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                acc = memory[@intCast(word)];
            } else return reporter.reportIp(cur_ip, "Attempt to read non-existant address {?d}", .{memory[arg]}),
            .sti => if (memory[arg]) |word| if (word >= 0 and word < memory.len) {
                memory[@intCast(word)] = acc;
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
                900 => stdout.print("{d}", .{acc.?}) catch |err|
                    return reporter.reportIp(cur_ip, "Failed to output: {s}", .{@errorName(err)}),

                // TODO convert the rest of it
                925 => {

                    // printString
                    if (acc.? < 0 or acc.? >= 900) return reporter.reportIp(cur_ip, "Bad address to string", .{});
                    var ix: u16 = @intCast(acc.?);
                    defer acc = ix;

                    while (memory[ix]) |word| : (ix += 1) {
                        if (word == 0) break;
                        if (word < 0 or word > 128) return reporter.reportIp(cur_ip, "Bad ASCII value", .{});
                        stdout.writeByte(@intCast(word)) catch |err|
                            return reporter.reportIp(cur_ip, "Failed to output: {s}", .{@errorName(err)});
                    }
                },
                inputInteger => {
                    var buf: [100]u8 = undefined;
                    const rline = stdin.readUntilDelimiter(&buf, '\n') catch |err|
                        return reporter.reportIp(cur_ip, "Failed to read input: {s}", .{@errorName(err)});
                    const line = std.mem.trim(u8, rline, &std.ascii.whitespace);
                    acc = std.fmt.parseInt(Word, line, 10) catch |err|
                        return reporter.reportIp(cur_ip, "Failed to get integer: {s}", .{@errorName(err)});
                },
                inputString => {
                    var buf: [100]u8 = undefined;
                    const rline = stdin.readUntilDelimiter(&buf, '\n') catch |err|
                        return reporter.reportIp(cur_ip, "Failed to read input: {s}", .{@errorName(err)});
                    if (acc.? < 0) return reporter.reportIp(cur_ip, "ACC negative", .{});
                    const addr: usize = @intCast(acc.?);
                    if (addr + rline.len + 1 > memory.len)
                        return reporter.reportIp(cur_ip, "Input string is too long", .{});
                    for (rline, addr..) |byte, index| {
                        memory[index] = byte;
                    }
                    memory[addr + rline.len] = 0;
                },
                else => {
                    return reporter.reportIp(cur_ip, "Call not implemented", .{});
                },
            },
            else => return reporter.reportIp(cur_ip, "{s} not implemented", .{@tagName(op)}),
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
