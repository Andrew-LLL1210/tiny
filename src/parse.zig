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
    var deferred_operations = std.ArrayList(struct {
        index: usize,
        label_name: []const u8,
    }).init(alloc);
    defer deferred_operations.deinit();

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
            .db_directive => |value| {
                try listing.append(.{ .ip = ip, .word = value, .line_no = line_no });
                ip += 1;
            },
            .dc_directive => |string| {
                const length = try encodeString(&listing, string, reporter, ip, line_no);
                ip += length;
            },
            .operation => |operation| {
                try listing.append(.{
                    .ip = ip,
                    .word = operation.opcode.encode(operation.argument),
                    .line_no = line_no,
                });

                if (operation.argument == .label) try deferred_operations.append(.{
                    .index = listing.items.len - 1,
                    .label_name = operation.argument.label,
                });
                ip += 1;
            },
        };
    }

    for (deferred_operations.items) |operation| {
        const label_line_no = listing.items[operation.index].line_no;
        const label_address = label_table.get(operation.label_name) orelse
            return reporter.reportErrorLine(label_line_no, "Label {s} does not exist", .{operation.label_name});
        listing.items[operation.index].word += @intCast(label_address);
    }

    return listing.toOwnedSlice();
}

fn parseLine(
    line: []const u8,
    line_no: usize,
    reporter: *const Reporter,
) ReportedError!ProcessedLine {
    var tokens = Tokenizer{ .line = line, .reporter = reporter, .line_no = line_no };
    const token1 = try tokens.next() orelse return .{};
    if (token1 != .identifier) return reporter.reportErrorLineCol(
        line_no,
        tokens.index - token1.length(),
        tokens.index,
        "Expected label or instruction, found {s}",
        .{@tagName(token1)},
    );

    var label: ?[]const u8 = null;
    var mnemonic: []const u8 = token1.identifier;
    var m_argument: ?Token = try tokens.next();

    if (m_argument) |token2| if (token2 == .colon) {
        label = token1.identifier;
        mnemonic = switch (try tokens.next() orelse return .{ .label = label }) {
            .identifier => |source| source,
            else => |token| return reporter.reportErrorLineCol(
                line_no,
                tokens.index - token.length(),
                tokens.index,
                "Expected instruction or end of line, found {s}",
                .{@tagName(token)},
            ),
        };
        m_argument = try tokens.next();
        if (m_argument) |token4| if (token4 == .colon) {
            const i = @intFromPtr(line.ptr) - @intFromPtr(mnemonic.ptr);
            return reporter.reportErrorLineCol(line_no, i, tokens.index, "Only one label is allowed per line", .{});
        };
    };

    if (try tokens.next()) |token| return reporter.reportErrorLineCol(
        line_no,
        tokens.index - token.length(),
        tokens.index,
        "Expected newline, found {s}",
        .{@tagName(token)},
    );

    const mnemonic_ix = @intFromPtr(mnemonic.ptr) - @intFromPtr(line.ptr);
    const opcode = mnemonic_map.get(mnemonic) orelse return reporter.reportErrorLineCol(
        line_no,
        mnemonic_ix + 1,
        mnemonic_ix + mnemonic.len,
        "Invalid operation mnemonic: {s}",
        .{mnemonic},
    );

    @constCast(reporter).setLineCol(line_no, mnemonic_ix + 1, tokens.index);
    return .{
        .label = label,
        .instruction = try Instruction.fromOpcode(opcode, m_argument, reporter),
    };
}

const Tokenizer = struct {
    line: []const u8,
    index: usize = 0,
    reporter: *const Reporter,
    line_no: usize,

    fn next(self: *Tokenizer) ReportedError!?Token {
        const read = self.line[self.index..];
        const start = std.mem.indexOfNone(u8, read, chars.whitespace) orelse return null;
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
            self.index + start,
            self.index + start,
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

    fn length(token: Token) usize {
        return switch (token) {
            .identifier, .number, .string => |source| source.len,
            .colon => 1,
        };
    }
};

const ProcessedLine = struct {
    label: ?[]const u8 = null,
    instruction: ?Instruction = null,
};

const Instruction = union(enum) {
    ds_directive: usize,
    db_directive: Word,
    dc_directive: []const u8,
    operation: struct { argument: Argument, opcode: Opcode },

    fn fromOpcode(
        opcode: Opcode,
        m_argument: ?Token,
        reporter: *const Reporter,
    ) ReportedError!Instruction {
        // precondition: argument is not a .colon token
        if (m_argument) |argument| switch (opcode) {
            .ds => if (argument == .number) return .{ .ds_directive = try parseAddress(argument.number, reporter) },
            .db => if (argument == .number) return .{ .db_directive = try parseWord(argument.number, reporter) },
            .dc => if (argument == .string) return .{ .dc_directive = argument.string },
            else => {},
        };
        if (m_argument) |argument| if (argument == .string)
            return reporter.reportHere("Strings are only accepted on the dc directive", .{});
        switch (opcode) {
            .ds, .db, .dc => return reporter.reportHere("Invalid use of {s}", .{@tagName(opcode)}),
            else => {},
        }

        const argument = try Argument.from(m_argument, reporter);
        if (opcode.takesArgument(argument)) return .{ .operation = .{ .argument = argument, .opcode = opcode } };
        return reporter.reportHere("{s} operation does not take a {s} argument", .{
            @tagName(opcode),
            @tagName(argument),
        });
    }
};

fn encodeString(
    listing: *std.ArrayList(ListingEntry),
    string: []const u8,
    reporter: *const Reporter,
    start: usize,
    line_no: usize,
) error{ OutOfMemory, ReportedError }!usize {
    var ip: usize = start;
    var escaped = false;
    for (string[1 .. string.len - 1]) |char| if (escaped) {
        escaped = false;
        try listing.append(.{ .ip = ip, .line_no = line_no, .word = switch (char) {
            'n' => '\n',
            '\\' => '\\',
            else => return reporter.reportErrorLine(line_no, "Illegal escape code '\\{c}' in string", .{char}),
        } });
        ip += 1;
    } else switch (char) {
        '\\' => escaped = true,
        else => {
            try listing.append(.{ .ip = ip, .line_no = line_no, .word = char });
            ip += 1;
        },
    };
    try listing.append(.{ .ip = ip, .line_no = line_no, .word = 0 });

    return ip - start + 1;
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

const Argument = union(enum) {
    none,
    immediate: u32,
    label: []const u8,

    fn from(m_token: ?Token, reporter: *const Reporter) ReportedError!Argument {
        if (m_token) |token| switch (token) {
            .identifier => |label| return .{ .label = label },
            .number => |label| return .{ .immediate = try parseAddress(label, reporter) },
            .string => unreachable,
            .colon => unreachable,
        } else return .{ .none = {} };
    }
};

fn parseAddress(source: []const u8, reporter: *const Reporter) ReportedError!u32 {
    if (source[0] == '-')
        return reporter.reportHere("Negative number cannot be used as an argument here", .{});
    const val = std.fmt.parseUnsigned(u32, source, 10) catch unreachable;
    if (val > 999)
        return reporter.reportHere("Argument value must be in range [0, 999]", .{});
    return val;
}

fn parseWord(source: []const u8, reporter: *const Reporter) ReportedError!Word {
    const val = std.fmt.parseInt(Word, source, 10) catch unreachable;
    if (val < -99999 or val > 99999)
        return reporter.reportHere("Word value must be in range [-99999, 99999]", .{});
    return val;
}

const Opcode = enum(u32) {
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
    pusha = 26,
    db,
    ds,
    dc,

    fn hasArgument(opcode: Opcode) Ternary {
        return switch (opcode) {
            .stop, .in, .out, .ret => .no,
            .push, .pop => .maybe,
            .ld, .lda, .ldi, .st, .sti, .add, .sub, .mul, .div, .jmp, .jg, .jl, .je, .call, .ldparam, .jge, .jle, .jne, .pusha => .yes,
            .dc, .db, .ds => unreachable,
        };
    }

    /// only defined when hasArgument(opcode) != .no
    fn isArgumentNumerical(opcode: Opcode) Ternary {
        return switch (opcode) {
            .ldi, .lda, .st, .sti, .jmp, .jg, .jl, .je, .call, .push, .pop, .jge, .jle, .jne, .pusha => .no,
            .ld, .add, .sub, .mul, .div => .maybe,
            .ldparam => .yes,
            .stop, .in, .out, .ret => unreachable,
            .dc, .db, .ds => unreachable,
        };
    }

    fn takesArgument(opcode: Opcode, argument: Argument) bool {
        switch (argument) {
            .none => return opcode.hasArgument() != .yes,
            .label => return opcode.hasArgument() != .no and opcode.isArgumentNumerical() != .yes,
            .immediate => return opcode.hasArgument() != .no and opcode.isArgumentNumerical() != .no,
        }
    }

    fn encode(
        opcode: Opcode,
        argument: Argument,
    ) Word {
        // precondition: opcode.takesArgument(argument)
        switch (argument) {
            .none => return @intCast(@intFromEnum(opcode) * 1000),
            .label => return @intCast(1000 * switch (opcode) {
                .push, .pop => @intFromEnum(opcode) + 6,
                else => @intFromEnum(opcode),
            }),
            .immediate => |arg| return @intCast(arg + 1000 * switch (opcode) {
                .ld, .add, .sub, .mul, .div => @intFromEnum(opcode) + 90,
                else => @intFromEnum(opcode),
            }),
        }
    }
};

const mnemonic_map: type = std.ComptimeStringMapWithEql(Opcode,
//blk: {
//    var map: []struct { []const u8, Opcode } = &.{};
//    for (std.enums.values(Opcode)) |name| {
//        map = map ++ .{ name, std.enums.nameCast(Opcode, name) };
//    }
//    break :blk map;
//},
.{
    .{ "stop", .stop },
    .{ "ld", .ld },
    .{ "lda", .lda },
    .{ "ldi", .ldi },
    .{ "st", .st },
    .{ "sti", .sti },
    .{ "add", .add },
    .{ "sub", .sub },
    .{ "mul", .mul },
    .{ "div", .div },
    .{ "in", .in },
    .{ "out", .out },
    .{ "jmp", .jmp },
    .{ "jg", .jg },
    .{ "jl", .jl },
    .{ "je", .je },
    .{ "call", .call },
    .{ "ret", .ret },
    .{ "push", .push },
    .{ "pop", .pop },
    .{ "ldparam", .ldparam },
    .{ "jge", .jge },
    .{ "jle", .jle },
    .{ "jne", .jne },
    .{ "pusha", .pusha },
    .{ "db", .db },
    .{ "ds", .ds },
    .{ "dc", .dc },
}, std.ascii.eqlIgnoreCase);

const Ternary = enum { yes, no, maybe };
