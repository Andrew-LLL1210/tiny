//! where miscellaneous functions needed by multiple files go

pub const ParseIntError = error { NotAnInteger };
pub fn parseInt(comptime T: type, src: []const u8) ParseIntError!T {
    var acc: T = 0;
    for (src) |char| switch (char) {
        '0'...'9' => |digit| acc = acc * 10 + digit - '0',
        else => return ParseIntError.NotAnInteger,
    };
    return acc;
}
