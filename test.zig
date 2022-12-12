const std = @import("std");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const tiny = @import("src/tiny.zig");


test "duplicate label" {
    const folder = comptime @src().file[0..@src().file.len - 8];
    const filepath = comptime folder ++ "test/duplicate-label.tny";
    const buf_in = comptime @embedFile(filepath);
    var buf_in_stream = std.io.fixedBufferStream(buf_in);
    const in = buf_in_stream.reader();

    const expected_error = comptime
        "\x1b[97m" ++ filepath ++ ":2: \x1b[91merror:\x1b[97m duplicate label 'SAMElabel'\x1b[0m\n" ++
        "\x1b[97m" ++ filepath ++ ":1: \x1b[96mnote:\x1b[97m original label here\x1b[0m\n";
    
    var buf_err = std.ArrayList(u8).init(testing.allocator);
    const err = buf_err.writer();
    defer buf_err.deinit();

    var reporter = tiny.Reporter(@TypeOf(err)) {
        .filepath = filepath,
        .writer = err,
    };

    try expectError(error.DuplicateLabel, tiny.readSource(
        in, testing.allocator, &reporter
    ));

    try expectEqualStrings(expected_error, buf_err.items);
}
