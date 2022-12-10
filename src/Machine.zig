const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;
const Listing = @import("listing.zig").Listing;

const Machine = @This();

const Word = u24;


const Operation = @import("Operation.zig");

const print_integer = 900;
const print_string = 925;
const input_string = 975;
const input_integer = 950;

memory: [1000]Word,
ip: u16,
acc: Word,
sp: u16,
bp: u16,

in: Reader,
out: Writer,
err: Writer,

pub fn init(in: Reader, out: Writer, err: Writer) Machine {
    return .{
        .memory = undefined,
        .ip = 0,
        .acc = undefined,
        .sp = 900,
        .bp = 900,
        .in = in,
        .out = out,
        .err = err,
    };
}

pub fn loadListing(self: *Machine, listing: Listing) void {
    var i: u16 = 0;
    for (listing) |instruction| switch (instruction) {
        .addr => |x| i = x,
        .value => |word| {
            self.memory[i] = word;
            i += 1;
        },
    };
}

const Exit = error{ Stop, SegFault };

pub fn run(self: *Machine) !void {
    while (self.cycle()) |_| {} else |err| switch (err) {
        Machine.Exit.Stop => {},
        else => return err,
    }
}

fn cycle(self: *Machine) !void {
    const instruction = Operation.decode(self.memory[self.ip]);
    self.ip += 1;
    return self.executeOperation(instruction);
}

fn executeOperation(self: *Machine, operation: Operation) !void {
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
        .in => self.acc = try self.in.readByte(),
        .out => try self.out.writeByte(@truncate(u8, self.acc)),
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
            self.bp = @truncate(u16, self.memory[self.sp]);
            self.sp += 1;
            self.ip = @truncate(u16, self.memory[self.sp]);
            self.sp += 1;
        },
        else => @panic("operation not implemented"),
    }
}

fn conditionalJump(self: *Machine, op: std.math.CompareOperator, dst: u16) void {
    if (std.math.compare(self.acc, op, 0)) self.ip = dst;
}

fn inputInteger(self: *Machine) !void {
    _ = self;
}

fn printInteger(self: *Machine) !void {
    try self.out.print("{d}", .{self.acc});
}

fn inputString(self: *Machine) !void {
    _ = self;
}

fn printString(self: *Machine) !void {
    var it = std.mem.split(Word, self.memory[self.acc..], &.{'\x00'});
    for (it.first()) |char|
        try self.out.writeByte(@truncate(u8, char));
}
