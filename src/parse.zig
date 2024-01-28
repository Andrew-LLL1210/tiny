const std = @import("std");

pub const Listing = []const ListingEntry;
pub const ListingEntry = struct { ip: usize, word: Word, line_no: usize };

pub fn parse(
    source: []const u8,
    reporter: *const Reporter,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, ReportedError }!Listing {
    var listing = std.ArrayList(ListingEntry).init(alloc);
    errdefer listing.deinit();
    var label_table = LabelTable.init(alloc);
    defer label_table.deinit();

    try label_table.putNoClobber("printInteger", 900);
    try label_table.putNoClobber("printString", 925);
    try label_table.putNoClobber("inputInteger", 950);
    try label_table.putNoClobber("inputString", 975);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    var ip: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const parsed_line = try parseLine(line, line_no, reporter);

        if (parsed_line.label) |label_name| {
            const get_or_put = try label_table.getOrPut(label_name);
            if (get_or_put.found_existing)
                return reporter.reportErrorLine(line_no, "Duplicate Label \"{s}\"", .{label_name});
            get_or_put.value_ptr.* = ip;
        }

        if (parsed_line.instruction) |instruction| switch (instruction) {
            .ds_directive => |length| ip += length,
            .dd_directive => |value| {
                try listing.append(.{ .ip = ip, .word = value, .line_no = line_no });
                ip += 1;
            },
            .dc_directive => |string| {
                const length = try encodeString(&listing, string);
                _ = length;
            },
            else => {
                return reporter.reportErrorLine(line_no, "instruction type {any} not supported", .{instruction});
            },
        };
    }

    return reporter.reportErrorLine(0, "parse() is not implemented", .{});
}

fn parseLine(
    line: []const u8,
    line_no: usize,
    reporter: *const Reporter,
) ReportedError!ProcessedLine {
    _ = line_no;
    _ = line;
    return reporter.reportErrorLine(0, "parseLine() not implemented", .{});
}

const Tokenizer = struct {
    line: []const u8,
    index: usize,
    reporter: *const Reporter,
    line_no: usize,

    fn next(self: *Tokenizer) ReportedError!?Token {
        const read = self.line[self.index..];
        const start = std.mem.indexOfNone(u8, read, chars.whitespace) orelse return .{ null, read };
        if (read[start] == ';') return null;

        if (read[start] == ':') {
            self.index += start + 1;
            return .{ .colon = {} };
        }

        if (std.mem.indexOfScalar(u8, chars.id_begin, read[start])) |_| {
            const end = std.mem.indexOfNonePos(u8, read, start, chars.id) orelse read.len;
            self.index += end;
            return .{ .identifier = read[start..end] };
        }

        if (std.ascii.isDigit(read[start]) or read[start] == '-') {
            const end = std.mem.indexOfNonePos(u8, read, start, chars.digits) orelse read.len;
            if (end - start > 6) return self.reporter.reportErrorLineCol(
                self.line_no,
                self.index + start,
                self.index + end,
                "Number literal is too large",
                .{},
            );
            self.index += end;
            return .{ .number = read[start..end] };
        }

        if (read[start] == '"' or read[start] == '\'') {
            var escape = true;
            const len = for (read[start..], 1..) |char, _len| {
                if (escape) {
                    escape = false;
                    continue;
                }
                if (char == read[start]) break _len;
                if (char == '\\') escape = true;
            } else return self.reporter.reportErrorLineCol(
                self.line_no,
                self.index + start,
                self.line.len,
                "Unclosed string",
                .{},
            );
            self.index += start + len;
            return .{ .string = read[start..][0..len] };
        }

        return self.reporter.reportErrorLineCol(
            self.line_no,
            self.index + self.start,
            self.index + self.start,
            "Illegal character {x:02}",
            .{read[start]},
        );
    }

    const chars = struct {
        const whitespace = " \t\r";
        const id = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_&[]0123456789";
        const id_begin = id[0 .. 26 * 2 + 2];
        const digits = "0123456789";
    };
};

const Token = union(enum) {
    identifier: []const u8,
    number: []const u8,
    string: []const u8,
    colon,
};

const ProcessedLine = struct {
    label: ?[]const u8 = null,
    instruction: ?Instruction = null,
};

const Instruction = union(enum) {
    ds_directive: usize,
    dd_directive: Word,
    dc_directive: []const u8,
    operation: struct { argument: Argument, opcode: Opcode },
};

fn encodeString(listing: *std.ArrayList(ListingEntry), string: []const u8) !void {
    _ = string;
    _ = listing;
    return;
}

const Word = @import("run.zig").Word;
const Reporter = @import("report.zig").Reporter;
const ReportedError = Reporter.ReportedError;

const LabelTable = std.HashMap([]const u8, usize, CaseInsensitiveContext, 80);
const CaseInsensitiveContext = struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        var wh = std.hash.Wyhash.init(0);
        for (key) |char| {
            if (std.ascii.isLower(char)) {
                const e = char - ('a' - 'A');
                wh.update(std.mem.asBytes(&e));
            } else {
                wh.update(std.mem.asBytes(&char));
            }
        }
        return wh.final();
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

const CharClass = enum {
    identifier_start,
    identifier_contain,
    number,
    colon,
    whitespace,
    semicolon,
    quote,
    illegal,
    fn of(char: u8) CharClass {
        return switch (char) {
            'a'...'z', 'A'...'Z', '_', '&' => .identifier_start,
            '[', ']' => .identifier_contain,
            '0'...'9' => .number,
            ':' => .colon,
            ';' => .semicolon,
            ' ', '\r', '\t' => .whitespace,
            '\'', '\"' => .quote,
            else => .illegal,
        };
    }
};

const Argument = union(enum) {
    none,
    immediate: u32,
    label: []const u8,
};

const Opcode = enum(u32) {
    stop,
    ld,
    ldi,
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
    pusha,

    fn hasArgument(opcode: Opcode) Ternary {
        return switch (opcode) {
            .stop, .in, .out, .ret => .no,
            .push, .pop => .maybe,
            .ld, .ldi, .st, .sti, .add, .sub, .mul, .div, .jmp, .jg, .jl, .je, .call, .ldparam, .jge, .jle, .jne, .pusha => .yes,
        };
    }

    /// only defined when hasArgument(opcode) != .no
    fn isArgumentNumerical(opcode: Opcode) Ternary {
        return switch (opcode) {
            .ldi, .lda, .st, .sti, .jmp, .jg, .jl, .je, .call, .push, .pop, .jge, .jle, .jne, .pusha => .no,
            .ld, .add, .sub, .mul, .div => .maybe,
            .ldparam => .yes,
            .stop, .in, .out, .ret => unreachable,
        };
    }
};

const Ternary = enum { yes, no, maybe };
