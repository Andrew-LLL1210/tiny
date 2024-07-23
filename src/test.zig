const std = @import("std");
const root = @import("tiny.zig");

test {
    std.testing.refAllDeclsRecursive(root);
}
