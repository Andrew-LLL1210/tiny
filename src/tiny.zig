const std = @import("std");
pub const parse = @import("tiny/parse.zig");

//pub const sema = @import("tiny/sema.zig");
pub const run = @import("tiny/run.zig");

pub const max_read_size = std.math.maxInt(usize);
pub const Word = run.Word;
pub const Air = parse.Air;
pub const Error = parse.Error;
pub const Machine = run.Machine;
pub const Span = @import("tiny/span.zig").Span;

pub fn assemble(air: Air) Machine {
    _ = air;
    @panic("TODO");
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
