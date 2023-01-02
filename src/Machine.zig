const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Operation = @import("Operation.zig");
const Reporter = @import("reporter.zig").Reporter;

pub const Word = i24;
pub const Ptr = u16;
pub const Listing = []const ?Word;

pub fn writeListing(listing: Listing, out: Writer) !void {
    for (listing) |word| if (word) |data| {
        try out.print("{d:0>5}\n", .{data});
    } else {
        try out.print("?????\n", .{});
    };
}

pub const Machine = struct {
    const print_integer = 900;
    const print_string = 925;
    const input_integer = 950;
    const input_string = 975;

    memory: [900]Word,
    ip: Ptr,
    acc: Word,
    sp: Ptr,
    bp: Ptr,

    in: Reader,
    out: Writer,
    err: Writer,
    reporter: *Reporter(Writer),

    pub fn init(
        in: Reader,
        out: Writer,
        err: Writer,
        reporter: *Reporter(Writer),
    ) Machine {
        return .{
            .memory = undefined,
            .ip = 0,
            .acc = undefined,
            .sp = 900,
            .bp = 900,
            .in = in,
            .out = out,
            .err = err,
            .reporter = reporter,
        };
    }

    pub fn loadListing(self: *Machine, listing: Listing) void {
        for (listing) |m_word, i| if (m_word) |word| {
            self.memory[i] = word;
        };
    }

    const Exit = error{ Stop, SegFault };

    pub fn run(self: *Machine) !void {
        while (self.cycle()) |_| {} else |err| switch (err) {
            Machine.Exit.Stop => {},
            else => return err,
        }
    }

    pub fn cycle(self: *Machine) !void {
        const instruction = Operation.decode(self.memory[self.ip]);
        self.ip += 1;
        return self.executeOperation(instruction);
    }

    pub fn executeOperation(self: *Machine, operation: Operation) !void {
        const arg = operation.arg;
        switch (operation.op) {
            .stop => return Exit.Stop,
            .ld_from => self.acc = (try self.at(arg)).*,
            .ld_imm, .lda_of => self.acc = arg,
            .st_to => (try self.at(arg)).* = self.acc,
            .sti_to => (try self.at((try self.at(arg)).*)).* = self.acc,
            .add_by => self.acc = self.wrap(self.acc +% (try self.at(arg)).*),
            .sub_by => self.acc = self.wrap(self.acc -% (try self.at(arg)).*),
            .mul_by => self.acc = self.wrap(self.acc *% (try self.at(arg)).*),
            .div_by => self.acc = try self.div(self.acc, (try self.at(arg)).*),
            .add_imm => self.acc = self.wrap(self.acc +% arg),
            .sub_imm => self.acc = self.wrap(self.acc -% arg),
            .mul_imm => self.acc = self.wrap(self.acc *% arg),
            .div_imm => self.acc = try self.div(self.acc, arg),
            .ldi_from => self.acc = (try self.at((try self.at(arg)).*)).*,
            .in => self.acc = try self.in.readByte(),
            .out => try self.out.writeByte(@intCast(u8, self.acc)),
            .jmp_to => self.ip = arg,
            .je_to => self.conditionalJump(.eq, arg),
            .jne_to => self.conditionalJump(.neq, arg),
            .jl_to => self.conditionalJump(.lt, arg),
            .jle_to => self.conditionalJump(.lte, arg),
            .jg_to => self.conditionalJump(.gt, arg),
            .jge_to => self.conditionalJump(.gte, arg),
            .call => switch (arg) {
                input_integer => try self.inputInteger(),
                print_integer => try self.printInteger(),
                input_string => try self.inputString(),
                print_string => try self.printString(),
                else => {
                    if (arg >= 900) return Exit.SegFault;

                    self.sp -= 1;
                    self.memory[self.sp] = self.ip;
                    self.sp -= 1;
                    self.memory[self.sp] = self.bp;
                    self.bp = self.sp;
                    self.ip = arg;
                },
            },
            .ret => {
                self.sp = self.bp;
                self.bp = @intCast(Ptr, (try self.at(self.sp)).*);
                self.sp += 1;
                self.ip = @intCast(Ptr, (try self.at(self.sp)).*);
                self.sp += 1;
            },
            .push => try self.push(self.acc),
            .pop => {
                self.acc = self.memory[@intCast(Ptr, self.sp)];
                self.sp += 1;
            },
            .ldparam_no => self.acc = (try self.at(self.bp + arg + 1)).*,
            .push_from => try self.push((try self.at(arg)).*),
            .pop_to => {
                self.memory[arg] = self.memory[@intCast(Ptr, self.sp)];
                self.sp += 1;
            },
            .pusha_of => try self.push(arg),
        }
    }

    fn conditionalJump(self: *Machine, op: std.math.CompareOperator, dst: u16) void {
        if (std.math.compare(self.acc, op, 0)) self.ip = dst;
    }

    fn push(self: *Machine, operand: Word) !void {
        // TODO add stackoverflow check?
        self.sp -= 1;
        (try self.at(self.sp)).* = operand;
    }

    fn wrap(self: *Machine, n: Word) Word {
        const res = @mod(n + 99999, 199999) - 99999;
        if (res != n)
            self.reporter.report(.bare, .warning, "overflow: {d} -> {d}", .{ n, res }) catch {};
        return res;
    }

    fn at(self: *Machine, i: Word) !*Word {
        if (i < 0 or i >= 900) {
            try self.reporter.report(.bare, .err, "invalid memory access at address {d}", .{i});
            return error.ReportedError;
        }
        return &self.memory[@intCast(Ptr, i)];
    }

    fn div(self: *Machine, num: Word, den: Word) !Word {
        if (den == 0) {
            try self.reporter.report(.bare, .err, "division by zero", .{});
            return error.ReportedError;
        }
        return @divTrunc(num, den);
    }

    /// consumes a WHOLE line of input from self.in and parses it as an integer
    /// throws an error if the line cannot be parsed as a (decimal) integer
    fn inputInteger(self: *Machine) !void {
        var buf: [100]u8 = undefined;
        const rline = try self.in.readUntilDelimiterOrEof(&buf, '\n') orelse {
            try self.reporter.report(.bare, .err, "eof found while reading integer", .{});
            return error.ReportedError;
        };
        const line = std.mem.trim(u8, rline, " \t\r\n");
        self.acc = self.wrap(std.fmt.parseInt(Word, line, 10) catch |err| switch (err) {
            error.InvalidCharacter => if (line.len == 0) {
                try self.reporter.report(.bare, .err, "blank line found while reading integer", .{});
                return error.ReportedError;
            } else {
                try self.reporter.report(.bare, .err, "invalid character found while reading integer", .{});
                return error.ReportedError;
            },
            error.Overflow => if (line[0] == '-') blk: {
                try self.reporter.report(.bare, .warning, "input too large to parse, using -99999", .{});
                break :blk -99999;
            } else blk: {
                try self.reporter.report(.bare, .warning, "input too large to parse, using 99999", .{});
                break :blk 99999;
            },
        });
    }

    fn printInteger(self: *Machine) !void {
        try self.out.print("{d}", .{self.acc});
    }

    /// read a line from self.in to memory starting at address self.acc
    /// string is null-terminated and does not contain a line ending
    /// leaves address of null-terminator in acc
    fn inputString(self: *Machine) !void {
        while (self.in.readByte()) |char| switch (char) {
            '\r' => {},
            '\n' => {
                self.memory[@intCast(Ptr, self.acc)] = 0;
                return;
            },
            else => {
                self.memory[@intCast(Ptr, self.acc)] = char;
                self.acc += 1;
            },
        } else |err| return err;
    }

    fn printString(self: *Machine) !void {
        var it = std.mem.split(Word, self.memory[@intCast(Ptr, self.acc)..], &.{'\x00'});
        for (it.first()) |char|
            try self.out.writeByte(@intCast(u8, char));
    }
};
