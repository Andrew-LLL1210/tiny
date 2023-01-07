const std = @import("std");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;
const tiny = @import("src/tiny.zig");
const Word = @import("src/Machine.zig").Word;
const Listing = @import("src/Machine.zig").Listing;
const Diagnostic = @import("src/Diagnostic.zig");
const parseListing = tiny.parseListing;

test "fail to assemble" {
    var diagnostic: Diagnostic = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    try expectError(error.DuplicateLabel, parseListing(
        \\samelabel:
        \\SAMELABEL:
    , alloc, &diagnostic));
    try expectEqualSlices(u8, "samelabel", diagnostic.label_name);
    try expectEqual(@as(usize, 2), diagnostic.line);
    try expectEqual(@as(usize, 1), diagnostic.label_prior_line);

    try expectError(error.ReservedLabel, parseListing("PRINTINTEGER:", alloc, &diagnostic));
    try expectEqualSlices(u8, "printInteger", diagnostic.label_name);

    try expectError(error.UnknownLabel, parseListing("jmp main", alloc, &diagnostic));
    try expectEqualSlices(u8, "main", diagnostic.label_name);

    try expectError(error.UnknownInstruction, parseListing("do something", alloc, &diagnostic));
    try expectEqualSlices(u8, "do", diagnostic.op);

    try expectError(error.BadByte, parseListing("jmp �", alloc, &diagnostic));
    try expectEqual(@as(u8, 239), diagnostic.byte);

    try expectError(error.UnexpectedCharacter, parseListing("jmp main main", alloc, &diagnostic));
    try expectEqual(@as(u8, 'm'), diagnostic.byte);

    try expectError(error.DislikesImmediate, parseListing("push 42", alloc, &diagnostic));
    try expectError(error.DislikesOperand, parseListing("stop 42", alloc, &diagnostic));
    try expectError(error.NeedsImmediate, parseListing("ldparam", alloc, &diagnostic));
    try expectError(error.NeedsOperand, parseListing("add", alloc, &diagnostic));
    try expectError(error.RequiresLabel, parseListing("sti", alloc, &diagnostic));
    try expectError(error.DirectiveExpectedAgument, parseListing("dc", alloc, &diagnostic));
    try expectError(error.DbOutOfRange, parseListing("db 999999999999999999", alloc, &diagnostic));
    try expectError(error.DbBadArgType, parseListing("db main", alloc, &diagnostic));
    try expectError(error.DsOutOfRange, parseListing("ds 999", alloc, &diagnostic));
    try expectError(error.ArgumentOutOfRange, parseListing("add 12345", alloc, &diagnostic));
}

test "produce listing" {
    var d: Diagnostic = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const alloc = arena.allocator();
    defer arena.deinit();

    try expectEqual(
        @as(usize, 159),
        (try parseListing(@embedFile("examples/avg.tny"), alloc, &d)).len,
    );
    try expectEqual(
        @as(usize, 16),
        (try parseListing(@embedFile("examples/hello.tny"), alloc, &d)).len,
    );

    try expectEqualSlices(
        ?Word,
        &.{ 12002, 42, 1001, 16900, 0 },
        try parseListing(@embedFile("examples/answer.tny"), alloc, &d),
    );

    try expectEqualSlices(
        ?Word,
        &.{ 3005, 16975, 3005, 16925, 0 },
        try parseListing(@embedFile("examples/cat.tny"), alloc, &d),
    );

    try expectEqualSlices(
        ?Word,
        &.{ 12003, 16900, 12005, 91006, 12001, 0 },
        try parseListing(@embedFile("examples/labels.tny"), alloc, &d),
    );
}
