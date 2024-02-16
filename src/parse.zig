const std = @import("std");

pub const Parser = struct {
    source: []const u8,
    reporter: *const Reporter,
    tokens: TokenIterator,

    pub fn init(source: []const u8, reporter: *const Reporter) Parser {
        return .{
            .source = source,
            .reporter = reporter,
            .tokens = TokenIterator{ .src = source, .index = 0 },
        };
    }

    pub fn nextInstruction(self: *Parser) ReportedError!?Statement {
        const tokens = &self.tokens;

        const t1 = while (tokens.next()) |token| {
            if (token != .newline) break token;
        } else return null;

        if (t1 != .identifier) return error.IllegalToken;

        const t2 = tokens.next() orelse return checkedOperation(t1, null);
        _ = t2;
    }

    fn checkedOperation(mnemonic: []const u8, argument: ?Token) !Statement {
        _ = argument;
        _ = mnemonic;
    }
};

pub const Statement = struct {
    src: []const u8,
    action: union(enum) {
        label: []const u8,
        dc_directive: []const u8,
        db_directive: Word,
        ds_directive: u32,
        operation: Operation,
    },
};

const TokenIterator = struct {
    index: usize = 0,
    src: []const u8,

    fn hasStatementSeparator(self: *TokenIterator) bool {
        self.index = mem.indexOfNonePos(u8, self.src, self.index, " \t\r/") orelse return true;
        return switch (self.src[self.index]) {
            ';', '\r', '\n', '/' => true,
            else => false,
        };
    }

    fn next(self: *TokenIterator) ReportedError!?Token {
        self.index = mem.indexOfNonePos(u8, self.src, self.index, " \t\r/") orelse return null;

        const src = self.src;
        const start = self.index;
        var end: usize = self.index;
        defer self.index = end;

        switch (src[start]) {
            ';', '\r', '\n' => {
                end = 1 + mem.indexOfScalarPos(u8, src, start, '\n') orelse return null;
                return Token.init(src[start..end], .newline);
            },
            '/' => {
                end = start + 1;
                return Token.init(src[start..end], .newline);
            },
            ':' => {
                end = start + 1;
                return Token.init(src[start..end], .colon);
            },
            'A'...'Z', 'a'...'z', '_', '&' => {
                end = for (src[start..], start..) |c, i| switch (c) {
                    'A'...'Z', 'a'...'z', '_', '&', '[', ']', '0'...'9' => {},
                    else => break i,
                };

                //boundary condition
                switch (src[end]) {
                    '-' => return error.IllegalIdentifierCharacter,
                    else => {},
                }

                return Token.init(src[start..end], .identifier);
            },
            '-', '0'...'9' => {
                end = std.mem.indexOfNonePos(u8, src, start, "0123456789") orelse src.len;
                const max_len = if (src[start] == '-') 6 else 5;
                if (end - start > max_len) return error.NumberLiteralTooLong;

                // boundary condition
                switch (src[end]) {
                    'A'...'Z', 'a'...'z', '_', '&' => return error.IllegalNumberCharacter,
                    else => {},
                }

                return Token.init(src[start..end], .number);
            },
            '"', '\'' => {
                var escape = true;
                end = for (src[start..], start..) |c, i| if (escape == false) switch (c) {
                    '0', 'r', 'n', 't', '"', '\'' => escape = false,
                    else => return error.IllegalEscapeCode,
                } else switch (c) {
                    '\\' => escape = true,
                    '"', '\'' => if (c == src[start]) break i,
                    else => {},
                };
                // TODO maybe enforce boundary condition? caller should be ok anyway

                return Token.init(src[start..end], .string);
            },
            else => return error.IllegalCharacter,
        }
    }
};

const Token = struct {
    src: []const u8,
    kind: Kind,

    const Kind = enum {
        identifier,
        number,
        string,
        colon,
        newline,
    };

    fn init(src: []const u8, kind: Kind) Token {
        return .{ .src = src, .kind = kind };
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

const Operation = struct {
    opcode: Opcode,
    argument: u32,
};

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
const mem = std.mem;
