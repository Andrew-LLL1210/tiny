const std = @import("std");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const tiny = @import("src/tiny.zig");

fn expectFailureFromFile(
    comptime filepath: []const u8,
    expected_error: anyerror,
    expected_message: []const u8,
) !void {
    const buf_in = @embedFile(filepath);
    var buf_in_stream = std.io.fixedBufferStream(buf_in);
    const in = buf_in_stream.reader();

    var buf_err = std.ArrayList(u8).init(testing.allocator);
    const err = buf_err.writer();
    defer buf_err.deinit();

    var reporter = tiny.Reporter(@TypeOf(err)) {
        .filepath = "file",
        .writer = err,
    };

    try expectError(expected_error, tiny.readSource(
        in, testing.allocator, &reporter
    ));

    try expectEqualStrings(expected_message, buf_err.items);
}

test "fail to assemble" {
    try expectFailureFromFile(
        "test/duplicate-label.tny",
        error.DuplicateLabel,
        "\x1b[97mfile:2: \x1b[91merror:\x1b[97m duplicate label 'SAMElabel'\x1b[0m\n" ++
        "\x1b[97mfile:1: \x1b[96mnote:\x1b[97m original label here\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/inputInteger.tny",
        error.DuplicateLabel,
        "\x1b[97mfile:3: \x1b[91merror:\x1b[97m duplicate label 'INPUTINTEGER'\x1b[0m\n" ++
        "\x1b[97mfile:3: \x1b[96mnote:\x1b[97m 'inputInteger' is reserved\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/unknown-label.tny",
        error.UnknownLabel,
        "\x1b[97mfile:1: \x1b[91merror:\x1b[97m unknown label 'cat'\x1b[0m\n",
    );
}
