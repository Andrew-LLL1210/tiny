const Tokenizer = @This();
const std = @import("std");
const root = @import("../root.zig");
const parse = @import("parse.zig");

const AstError = parse.AstError;
const Span = root.Span;

want_comments: bool,
idx: usize = 0,

pub const Token = union(enum) {
    comment: Span,

    identifier: Span,
    number: struct { span: Span, value: i32 },
    string: Span,
    colon: usize,
    newline: usize,

    parse_error: parse.Ast.Error,

    pub fn span(token: Token) Span {
        return switch (token) {
            .comment, .identifier, .string => |res| return res,
            .colon, .newline => |idx| return .{ .start = idx, .end = idx + 1 },
            inline .number, .parse_error => |obj| return obj.span,
        };
    }
};

/// returns a pseudo-newline element at the tokenizer's current position.
/// for use in hacky logic
pub fn newline(self: *const Tokenizer) Token {
    return .{ .newline = self.idx };
}

pub fn next(self: *Tokenizer, src: []const u8) ?Token {
    var start = self.idx;

    while (start < src.len and
        src[start] != '\n' and
        std.ascii.isWhitespace(src[start]))
        start += 1;

    if (start >= src.len) return null;

    var end = start + 1;
    var skip = false;
    defer {
        if (skip) {
            self.idx = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
        } else self.idx = end;
    }

    switch (src[start]) {
        '\n' => {
            return .{ .newline = start };
        },
        ':' => {
            return .{ .colon = start };
        },
        ';' => {
            var token_end: usize = 0;
            end = src.len;
            for (src[start..], start..) |c, i| if (c == '\n') {
                end = i;
                break;
            } else if (!std.ascii.isWhitespace(c)) {
                token_end = i;
            };

            if (!self.want_comments) {
                end += 1;
                return .{ .newline = end - 1 };
            }

            return .{ .comment = .{ .start = start, .end = token_end + 1 } };
        },
        'A'...'Z', 'a'...'z', '_', '&', '/' => {
            end = for (src[start..], start..) |c, i| switch (c) {
                'A'...'Z', 'a'...'z', '_', '&', '[', ']', '0'...'9', '/' => {},
                else => break i,
            } else src.len;

            //boundary condition
            if (end < src.len and src[end] == '-') {
                skip = true;
                return .{ .parse_error = .{
                    .span = .{ .start = start, .end = end },
                    .tag = .illegal_identifier_character,
                } };
            }

            return .{ .identifier = .{ .start = start, .end = end } };
        },
        '-', '0'...'9' => {
            end = std.mem.indexOfNonePos(u8, src, start, "0123456789") orelse src.len;
            const max_len: usize = if (src[start] == '-') 6 else 5;
            if (end - start > max_len) {
                skip = true;
                return .{ .parse_error = .{
                    .span = .{ .start = start, .end = end },
                    .tag = .number_literal_too_large,
                } };
            }

            // boundary condition
            if (end < src.len) switch (src[end]) {
                'A'...'Z', 'a'...'z', '_', '&' => {
                    skip = true;
                    return .{ .parse_error = .{
                        .span = .{ .start = start, .end = end },
                        .tag = .illegal_number_character,
                    } };
                },
                else => {},
            };

            const value = std.fmt.parseInt(i32, src[start..end], 10) catch unreachable;
            return .{ .number = .{
                .span = .{ .start = start, .end = end },
                .value = value,
            } };
        },
        '"', '\'' => {
            var escape = true;
            end = 1 + for (src[start..], start..) |c, i| (if (escape) switch (c) {
                '0', 'r', 'n', 't', '"', '\'' => escape = false,
                '\n' => {
                    skip = true;
                    return .{ .parse_error = .{
                        .span = .{ .start = start, .end = i },
                        .tag = .unclosed_string,
                    } };
                },
                else => {
                    skip = true;
                    return .{ .parse_error = .{
                        .span = .{ .start = i - 1, .end = i + 1 },
                        .tag = .unrecognized_escape_sequence,
                    } };
                },
            } else switch (c) {
                '\\' => escape = true,
                '"', '\'' => if (c == src[start]) break i,
                '\n' => {
                    skip = true;
                    return .{ .parse_error = .{
                        .span = .{ .start = start, .end = i },
                        .tag = .unclosed_string,
                    } };
                },
                else => {},
            }) else {
                skip = true;
                return .{ .parse_error = .{
                    .span = .{ .start = start, .end = src.len },
                    .tag = .unclosed_string,
                } };
            };

            return .{ .string = .{ .start = start, .end = end } };
        },
        else => {
            skip = true;
            return .{ .parse_error = .{
                .span = .{ .start = start, .end = start + 1 },
                .tag = .illegal_character,
            } };
        },
    }
}

fn expectConsistency(source: []const u8) !void {
    var t1: Tokenizer = .{ .want_comments = true };
    var t2: Tokenizer = .{ .want_comments = false };

    while (t1.next(source)) |token| {
        if (token == .comment) continue;
        try std.testing.expectEqual(token, t2.next(source));
    }
    try std.testing.expect(t2.next(source) == null);
}

test "consistency" {
    // output of comment and non-comment mode should only differ by the presence/absence of
    // comment tokens

    const cases = [_][]const u8{
        @embedFile("test/hello.tny"),
    };

    for (cases) |case| try expectConsistency(case);
}
