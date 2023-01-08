//! This is not a test file. This module contains code for parsing .test files into test cases

pub const TestCase = struct {
    name: ?[]const u8,
    input: []const u8,
    output: []const u8,
};
