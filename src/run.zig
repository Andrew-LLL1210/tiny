const std = @import("std");

/// A Word is in the range [-10000, 10000];
pub const Word = i32;

pub const Machine = struct {
    stdin: File.Reader,
    stdout: File.Writer,
    reporter: *const Reporter,

    memory: [900]?Word = .{null} ** 900,
    ip: usize = 0,
    acc: ?Word = null,
    sp: usize = 899,
    bp: usize = 899,

    pub fn init(
        listing: Listing,
        stdin: File.Reader,
        stdout: File.Writer,
        reporter: *const Reporter,
    ) Machine {
        var machine = Machine{ .stdin = stdin, .stdout = stdout, .reporter = reporter };
        for (listing) |entry| machine.memory[entry.ip] = entry.word;
        return machine;
    }

    pub fn run(self: Machine) error{ReportedError}!void {
        return self.reporter.reportErrorLine(0, "Machine.run() is not implemented", .{});
    }
};

const File = std.fs.File;
const Listing = @import("parse.zig").Listing;
const Reporter = @import("report.zig").Reporter;
