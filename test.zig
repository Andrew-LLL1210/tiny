const std = @import("std");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;
const tiny = @import("src/tiny.zig");
const Word = @import("src/Machine.zig").Word;
const Listing = @import("src/Machine.zig").Listing;
const Reporter = @import("src/reporter.zig").Reporter;

fn expectFailureFromFile(
    comptime filepath: []const u8,
    expected_message: []const u8,
) !void {
    const buf_in = @embedFile(filepath);
    var buf_in_stream = std.io.fixedBufferStream(buf_in);
    const in = buf_in_stream.reader();

    var buf_err = std.ArrayList(u8).init(testing.allocator);
    const err = buf_err.writer();
    defer buf_err.deinit();

    var reporter = Reporter(@TypeOf(err)){
        .path = "file",
        .writer = err,
    };

    const error_union = tiny.readSource(in, testing.allocator, &reporter);
    defer if (error_union) |listing| testing.allocator.free(listing) else |_| {};
    try expectError(error.ReportedError, error_union);
    try expectEqualStrings(expected_message, buf_err.items);
}

fn expectListingFromFile(
    comptime filepath: []const u8,
    expected_len: usize,
    expected_listing_m: ?Listing,
) !void {
    const buf_in = @embedFile(filepath);
    var buf_in_stream = std.io.fixedBufferStream(buf_in);
    const in = buf_in_stream.reader();

    var buf_err = std.ArrayList(u8).init(testing.allocator);
    const err = buf_err.writer();
    defer buf_err.deinit();

    var reporter = Reporter(@TypeOf(err)){
        .path = "file",
        .writer = err,
    };

    const listing = try tiny.readSource(in, testing.allocator, &reporter);
    defer testing.allocator.free(listing);

    try expectEqual(expected_len, listing.len);
    if (expected_listing_m) |expected_listing|
        try expectEqualSlices(?Word, expected_listing, listing);
}

test "fail to assemble" {
    try expectFailureFromFile(
        "test/duplicate-label.tny",
        "\x1b[97mfile:2: \x1b[91merror:\x1b[97m duplicate label 'SAMElabel'\x1b[0m\n" ++
            "\x1b[97mfile:1: \x1b[96mnote:\x1b[97m original label here\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/inputInteger.tny",
        "\x1b[97mfile:3: \x1b[91merror:\x1b[97m duplicate label 'INPUTINTEGER'\x1b[0m\n" ++
            "\x1b[97mfile:3: \x1b[96mnote:\x1b[97m 'inputInteger' is reserved\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/unknown-label.tny",
        "\x1b[97mfile:1: \x1b[91merror:\x1b[97m unknown label 'cat'\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/badbyte.tny",
        "\x1b[97mfile:1:5: \x1b[91merror:\x1b[97m bad byte EF\x1b[0m\n",
    );

    try expectFailureFromFile(
        "test/parse1.tny",
        "\x1b[97mfile:1:9: \x1b[91merror:\x1b[97m unexpected character 'a'\x1b[0m\n",
    );
}

test "produce listing" {
    try expectListingFromFile("examples/avg.tny", 156, null);
    try expectListingFromFile("examples/hello.tny", 15, null);
    try expectListingFromFile("examples/answer.tny", 5, &.{
        12002,
        42,
        1001,
        16900,
        0,
    });
    try expectListingFromFile("examples/cat.tny", 5, &.{
        3005,
        16975,
        3005,
        16925,
        0,
    });
    try expectListingFromFile("examples/labels.tny", 6, &.{
        12003,
        16900,
        12005,
        91006,
        12001,
        0,
    });
}
