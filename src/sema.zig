/// turn a program IR into a machine listing
pub fn assemble(parser: Parser, alloc: Allocator) !Listing {}

pub fn parse(
    source: []const u8,
    reporter: *const Reporter,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, ReportedError }!Listing {
    var listing = std.ArrayList(ListingEntry).init(alloc);
    errdefer listing.deinit();
    var label_table = LabelTable.init(alloc);
    defer label_table.deinit();
    var deferred_operations = std.ArrayList(struct {
        index: usize,
        label_name: []const u8,
    }).init(alloc);
    defer deferred_operations.deinit();

    try label_table.putNoClobber("printInteger", 900);
    try label_table.putNoClobber("printString", 925);
    try label_table.putNoClobber("inputInteger", 950);
    try label_table.putNoClobber("inputString", 975);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    var ip: usize = 0;
    var ok: bool = true;
    while (lines.next()) |multiline| : (line_no += 1) {
        const noncomment = @constCast(&std.mem.splitScalar(u8, multiline, ';')).first();
        var splits = std.mem.splitScalar(u8, noncomment, '/');
        while (splits.next()) |split| {
            const parsed_line = parseLine(split, line_no, reporter) catch {
                ok = false;
                continue;
            };

            if (parsed_line.label) |label_name| {
                const get_or_put = try label_table.getOrPut(label_name);
                if (get_or_put.found_existing)
                    return reporter.reportErrorLine(line_no, "Duplicate Label \"{s}\"", .{label_name});
                get_or_put.value_ptr.* = ip;
            }

            if (parsed_line.instruction) |instruction| switch (instruction) {
                .ds_directive => |length| ip += length,
                .db_directive => |value| {
                    try listing.append(.{ .ip = ip, .word = value, .line_no = line_no });
                    ip += 1;
                },
                .dc_directive => |string| {
                    const length = encodeString(&listing, string, reporter, ip, line_no) catch {
                        ok = false;
                        continue;
                    };
                    ip += length;
                },
                .operation => |operation| {
                    try listing.append(.{
                        .ip = ip,
                        .word = operation.opcode.encode(operation.argument),
                        .line_no = line_no,
                    });

                    if (operation.argument == .label) try deferred_operations.append(.{
                        .index = listing.items.len - 1,
                        .label_name = operation.argument.label,
                    });
                    ip += 1;
                },
            };
        }
    }

    if (!ok) return ReportedError.ReportedError;

    for (deferred_operations.items) |operation| {
        const label_line_no = listing.items[operation.index].line_no;
        const label_address = label_table.get(operation.label_name) orelse {
            reporter.reportErrorLine(label_line_no, "Label {s} does not exist", .{operation.label_name}) catch {};
            ok = false;
            continue;
        };
        listing.items[operation.index].word += @intCast(label_address);
    }

    if (!ok) return ReportedError.ReportedError;

    return listing.toOwnedSlice();
}

pub fn printSkeleton(
    out: std.fs.File.Writer,
    color_config: std.io.tty.Config,
    source: []const u8,
    reporter: *const Reporter,
    alloc: std.mem.Allocator,
) !void {
    // TODO all these local var names are bad
    const LabelRefTable = std.HashMap([]const u8, struct {
        is_referenced_before: bool = false,
        is_referenced_after: bool = false,
        is_declared: bool = false,
    }, CaseInsensitiveContext, 80);
    var label_table = LabelRefTable.init(alloc);
    defer label_table.deinit();

    const DataType = enum { stop, ret, declaration, jmp, jg, jl, je, jge, jle, jne };
    var print_data = std.ArrayList(struct { usize, []const u8, DataType }).init(alloc);
    defer print_data.deinit();

    // get every line with a jump or a label and print a cannonical representation
    {
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            const parsed_line = try parseLine(line, line_no, reporter);

            if (parsed_line.label) |label_name| {
                const res = try label_table.getOrPut(label_name);
                if (!res.found_existing) res.value_ptr.* = .{};
                if (res.value_ptr.is_declared)
                    return reporter.reportErrorLine(line_no, "Duplicate label '{s}'", .{label_name});
                res.value_ptr.is_declared = true;

                try print_data.append(.{ line_no, label_name, .declaration });
            }

            if (parsed_line.instruction) |instruction|
                if (instruction == .operation) switch (instruction.operation.opcode) {
                    .ret, .stop => |opcode| {
                        try print_data.append(.{
                            line_no,
                            "",
                            std.meta.stringToEnum(DataType, @tagName(opcode)).?,
                        });
                    },
                    .jmp, .jg, .jl, .je, .jge, .jle, .jne => |opcode| {
                        const label_name = instruction.operation.argument.label;
                        const res = try label_table.getOrPut(label_name);
                        if (!res.found_existing) res.value_ptr.* = .{};
                        if (res.value_ptr.is_declared) {
                            res.value_ptr.is_referenced_after = true;
                        } else {
                            res.value_ptr.is_referenced_before = true;
                        }

                        try print_data.append(.{
                            line_no,
                            label_name,
                            std.meta.stringToEnum(DataType, @tagName(opcode)).?,
                        });
                    },
                    else => {},
                };
        }
    }

    for (print_data.items) |item| {
        const line_no, const label_name, const opcode = .{ item[0], item[1], item[2] };

        if (opcode == .ret or opcode == .stop) {
            try out.print("{d: >3}:     {s}\n", .{ line_no, @tagName(opcode) });
            continue;
        }

        const label_data = label_table.get(label_name).?;
        var flag: u2 = 0;
        if (label_data.is_referenced_before) flag += 1;
        if (label_data.is_referenced_after) flag += 2;

        const color: std.io.tty.Color =
            if (!label_data.is_declared) .red else switch (flag) {
            0 => .dim,
            1 => .white,
            2 => .cyan,
            3 => .yellow,
        };

        try color_config.setColor(out, color);
        switch (opcode) {
            .declaration => try out.print("{d: >3}: {s}:\n", .{ line_no, label_name }),
            else => try out.print("{d: >3}:     {s} {s}\n", .{ line_no, @tagName(opcode), label_name }),
        }
        try color_config.setColor(out, .reset);
    }
}

pub const Listing = []const ListingEntry;
pub const ListingEntry = struct { ip: usize, word: Word, line_no: usize };

//fn parseLabelName(label_name: []const u8) LabelSemantics {
//    if (endsWithIgnoreCase(label_name, "begin")) return .{ .begin = {} };
//    if (endsWithIgnoreCase(label_name, "else")) return .{ ._else = {} };
//    if (endsWithIgnoreCase(label_name, "end")) return .{ .end = {} };
//    if (beginsWithIgnoreCase(label_name, "while")) return .{ ._while = {} };
//    return .{ .none = {} };
//}
//
//fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
//    if (needle.len > haystack.len) return false;
//    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
//}
//
//fn beginsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
//    if (needle.len > haystack.len) return false;
//    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
//}
//
//const LabelSemantics = union(enum) {
//    none,
//    begin,
//    end,
//    _else,
//    _while,
//};

fn encodeString(
    listing: *std.ArrayList(ListingEntry),
    string: []const u8,
    reporter: *const Reporter,
    start: usize,
    line_no: usize,
) error{ OutOfMemory, ReportedError }!usize {
    var ip: usize = start;
    var escaped = false;
    for (string[1 .. string.len - 1]) |char| if (escaped) {
        escaped = false;
        try listing.append(.{ .ip = ip, .line_no = line_no, .word = switch (char) {
            'n' => '\n',
            '\\' => '\\',
            else => return reporter.reportErrorLine(line_no, "Illegal escape code '\\{c}' in string", .{char}),
        } });
        ip += 1;
    } else switch (char) {
        '\\' => escaped = true,
        else => {
            try listing.append(.{ .ip = ip, .line_no = line_no, .word = char });
            ip += 1;
        },
    };
    try listing.append(.{ .ip = ip, .line_no = line_no, .word = 0 });

    return ip - start + 1;
}
