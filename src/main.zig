const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Tuple = std.meta.Tuple;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;

const usage =
    \\usage: tiny [program.state]
    \\
;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();

    var args_it = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args_it.deinit();

    _ = args_it.skip();
    const filename = args_it.next() orelse return (stderr.writeAll(usage));

    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const fin = file.reader();

    var machine = Machine.init(stdin, stdout, stderr);
    try machine.parseListing(fin);

    try machine.run();
}

pub const Token = union(enum) {
    adr: u16,
    value: u24,
};

pub fn nextToken(src: Reader) !?Token {
    while (src.readByte()) |byte| switch (byte) {
        ':' => {
            const digits: [3]u8 = .{
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
            };
            return Token{ .adr = parseInt(u16, &digits) };
        },
        '0'...'9' => |digit| {
            const digits: [5]u8 = .{
                digit,
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
                try src.readByte(),
            };
            return Token{ .value = parseInt(u24, &digits) };
        },
        ' ', '\n', '\t', '\r' => {},
        else => return error.BadByte,
    } else |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    }
}

fn parseInt(comptime T: type, src: []const u8) T {
    var acc: T = 0;
    for (src) |digit| acc = acc * 10 + digit - '0';
    return acc;
}

fn tSlice(comptime T: type, comptime n: usize, slice: []const T) Tuple(&.{T} ** n) {
    var tuple: Tuple(&.{T} ** n) = undefined;
    inline for (tuple) |*dst, i| {
        dst.* = slice[i];
    }
    return tuple;
}

pub const Machine = struct {
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

    pub fn parseListing(self: *Machine, src: Reader) !void {
        var i: u16 = 0;
        while (try nextToken(src)) |token| switch (token) {
            .adr => |adr| {
                i = adr;
            },
            .value => |value| {
                self.memory[i] = value;
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

    pub fn cycle(self: *Machine) !void {
        const instruction = Operation.decode(self.memory[self.ip]);
        self.ip += 1;
        return self.executeOperation(instruction);
    }

    pub fn executeOperation(
        self: *Machine,
        operation: Operation,
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
};

pub const Op = enum(u8) {
    stop = 0,
    ld_from = 1,
    ldi_from = 2,
    lda_of = 3,
    st_to = 4,
    sti_to = 5,
    add_by = 6,
    sub_by = 7,
    mul_by = 8,
    div_by = 9,
    in = 10,
    out = 11,
    jmp_to = 12,
    jg_to = 13,
    jl_to = 14,
    je_to = 15,
    call = 16,
    ret = 17,
    push = 18,
    pop = 19,
    ldparam_no = 20,
    jge_to = 21,
    jle_to = 22,
    jne_to = 23,
    push_from = 24,
    pop_to = 25,
    pusha_of = 26,
    ld_imm = 91,
    add_imm = 96,
    sub_imm = 97,
    mul_imm = 98,
    div_imm = 99,
};

pub const Operation = struct {
    op: Op,
    arg: u16,

    pub fn decodeSlice(input: []const Word, alloc: Allocator) ![]const Operation {
        var list = ArrayList(Operation).init(alloc);
        for (input) |instruction| {
            const op = @intToEnum(Op, instruction / 1000);
            const arg = @truncate(u16, instruction % 1000);
            try list.append(.{ .op = op, .arg = arg });
        }
        return list.toOwnedSlice();
    }

    pub fn decode(instruction: Word) Operation {
        const op = @intToEnum(Op, instruction / 1000);
        const arg = @truncate(u16, instruction % 1000);
        return .{ .op = op, .arg = arg };
    }

    pub fn encode(input: Operation) Word {
        return 1000 * @intCast(Word, @enumToInt(input.op)) + input.arg;
    }
};

test "decode" {
    const input = [_]Word{ 91003, 98003 };
    const decoded = try Operation.decodeSlice(&input, std.testing.allocator);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Operation, &[_]Operation{
        .{ .op = .ld_imm, .arg = 3 },
        .{ .op = .mul_imm, .arg = 3 },
    }, decoded);
}

const Word = u24;
const Listing = struct {
    listing: []const struct {
        begin_index: usize,
        data: []Word,
    },

    pub fn read(src: Reader, alloc: Allocator) !Listing {
        _ = src;
        _ = alloc;
        @compileError("not implemented");
    }
};
