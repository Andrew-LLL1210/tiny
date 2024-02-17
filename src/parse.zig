const std = @import("std");

pub const Parser = struct {
    source: []const u8,
    tokens: TokenIterator,

    pub fn init(source: []const u8) Parser {
        return .{
            .source = source,
            .tokens = TokenIterator{ .src = source, .index = 0 },
        };
    }

    pub fn nextInstruction(self: *Parser) !?Statement {
        const tokens = &self.tokens;

        const identifier_token = while (try tokens.next()) |token| {
            if (token.kind != .newline) break token;
        } else return null;

        if (identifier_token.kind != .identifier) return error.IllegalToken;
        const identifier = identifier_token.src;

        const t2 = try tokens.next() orelse Token{ .src = identifier, .kind = .newline };

        const action: Statement.Action = switch (t2.kind) {
            .colon => .{ .label = identifier },
            else => action: {
                const opcode = mnemonic_map.get(identifier) orelse
                    return error.InvalidMnemonic;

                break :action switch (opcode) {
                    .dc => if (t2.kind == .string)
                        .{ .dc_directive = t2.src }
                    else
                        return error.ExpectedString,
                    .db => if (t2.kind == .number)
                        .{ .db_directive = try parseWord(t2.src) }
                    else
                        return error.ExpectedNumber,
                    .ds => if (t2.kind == .number)
                        .{ .db_directive = try parseWord(t2.src) }
                    else
                        return error.ExpectedNumber,
                    else => op: {
                        const argument = try Argument.from(t2);
                        if (!opcode.takesArgument(argument)) return error.InvalidArgument;
                        break :op .{ .operation = .{ .opcode = opcode, .argument = argument } };
                    },
                };
            },
        };

        if (!tokens.hasNewlineOrEnd()) {
            _ = try tokens.next(); // for reporting correct token
            return error.TrailingToken;
        }

        return .{
            .src = joinSlices(identifier, t2.src),
            .action = action,
        };
    }
};

pub const Listing = []const ListingEntry;
pub const ListingEntry = struct { ip: usize, word: Word, line_no: usize };

pub const Statement = struct {
    src: []const u8,
    action: Action,
    const Action = union(enum) {
        label: []const u8,
        dc_directive: []const u8,
        db_directive: Word,
        ds_directive: u32,
        operation: Operation,
    };
};

pub const Operation = struct {
    opcode: Opcode,
    argument: Argument,
};

const ArgumentKind = enum { none, number, label };

const Argument = union(ArgumentKind) {
    none,
    number: u32,
    label: []const u8,

    fn from(token: Token) !Argument {
        return switch (token.kind) {
            .identifier => .{ .label = token.src },
            .number => .{ .number = try parseAddress(token.src) },
            .newline => .{ .none = {} },
            .string, .colon => unreachable,
        };
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

pub const Opcode = enum(u32) {
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
            .number => return opcode.hasArgument() != .no and opcode.isArgumentNumerical() != .no,
        }
    }

    // TODO why on earth was I doing this; it isn't broken I just don't like it
    //    fn arguments(opcode: Opcode) ArgumentData {
    //        var argument_data : ArgumentData  = undefined;
    //        argument_data.none = switch(opcode) {
    //            .stop, .in, .out, .ret, .push, .pop => true,
    //            else => false,
    //        };
    //        argument_data.label = switch(opcode) {
    //            .stop
    //        }
    //    }

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

const TokenIterator = struct {
    index: usize = 0,
    src: []const u8,

    fn hasNewlineOrEnd(self: *TokenIterator) bool {
        self.index = mem.indexOfNonePos(u8, self.src, self.index, " \t\r/") orelse return true;
        return switch (self.src[self.index]) {
            ';', '\r', '\n', '/' => true,
            else => false,
        };
    }

    fn next(self: *TokenIterator) !?Token {
        self.index = mem.indexOfNonePos(u8, self.src, self.index, " \t\r/") orelse return null;

        const src = self.src;
        const start = self.index;
        var end: usize = self.index;
        defer self.index = end;

        switch (src[start]) {
            ';', '\r', '\n' => {
                end = 1 + (mem.indexOfScalarPos(u8, src, start, '\n') orelse return null);
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
                } else src.len;

                //boundary condition
                if (end < src.len) switch (src[end]) {
                    '-' => return error.IllegalIdentifierCharacter,
                    else => {},
                };

                return Token.init(src[start..end], .identifier);
            },
            '-', '0'...'9' => {
                end = std.mem.indexOfNonePos(u8, src, start, "0123456789") orelse src.len;
                const max_len: usize = if (src[start] == '-') 6 else 5;
                if (end - start > max_len) return error.NumberLiteralTooLong;

                // boundary condition
                if (end < src.len) switch (src[end]) {
                    'A'...'Z', 'a'...'z', '_', '&' => return error.IllegalNumberCharacter,
                    else => {},
                };

                return Token.init(src[start..end], .number);
            },
            '"', '\'' => {
                var escape = true;
                end = for (src[start..], start..) |c, i| (if (escape == false) switch (c) {
                    '0', 'r', 'n', 't', '"', '\'' => escape = false,
                    else => return error.IllegalEscapeCode,
                } else switch (c) {
                    '\\' => escape = true,
                    '"', '\'' => if (c == src[start]) break i,
                    else => {},
                }) else src.len;
                // TODO maybe enforce boundary condition? caller should be ok anyway

                return Token.init(src[start..end], .string);
            },
            else => return error.IllegalCharacter,
        }
    }
};

const Word = @import("run.zig").Word;
const Reporter = @import("report.zig").Reporter;
const ReportedError = Reporter.ReportedError;

fn parseAddress(source: []const u8) !u32 {
    if (source[0] == '-')
        return error.NegativeAddress;
    const val = std.fmt.parseUnsigned(u32, source, 10) catch unreachable;
    if (val > 999)
        return error.AddressOutOfRange;
    return val;
}

fn parseWord(source: []const u8) !Word {
    const val = std.fmt.parseInt(Word, source, 10) catch unreachable;
    if (val < -99999 or val > 99999)
        return error.WordOutOfRange;
    return val;
}

/// Returns the slice beginning at `a[0]` and ending at `b[b.len]`.
/// Assumes slices are in the same string and nonoverlapping.
fn joinSlices(a: []const u8, b: []const u8) []const u8 {
    const a_unsafe: [*]const u8 = @ptrCast(a);
    const size: usize = @intFromPtr(b.ptr) - @intFromPtr(a.ptr) + b.len;
    return a_unsafe[0..size];
}

// const ArgumentData = struct { none: bool, label: bool, number: bool };

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

test {
    std.testing.refAllDeclsRecursive(@This());
}

test {
    const src =
        \\jmp main
        \\main:
        \\    call 3
    ;

    var parser = Parser.init(src);
    try expect(.operation == (try parser.nextInstruction()).?.action);
    try expect(.label == (try parser.nextInstruction()).?.action);
    try expectError(error.InvalidArgument, parser.nextInstruction());
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
