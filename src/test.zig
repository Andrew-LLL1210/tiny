//! This is not a test file. This module contains code for parsing .test files into test cases
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const FixedBufferStream = std.io.FixedBufferStream;

pub const TestCase = struct {
    name: ?[]const u8,
    input: []const u8,
    output: []const u8,
};

pub fn parseTests(src: []const u8, alloc: Allocator) ![]const TestCase {
    var test_cases = ArrayList(TestCase).init(alloc);
    errdefer test_cases.deinit();
    var offset: usize = 0;
    while (try parseTestCase(src[offset], alloc)) |data| {
        try test_cases.append(data.test_case);
        offset += data.size;
    }
    return test_cases.toOwnedSlice();
}

fn parseTestCase(src: []const u8, alloc: Allocator) !TestCase {
    _ = src;
    _ = alloc;
    return error.NotImplemented;
}
