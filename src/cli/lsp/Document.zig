const Document = @This();

const std = @import("std");
const assert = std.debug.assert;
const tiny = @import("tiny");

const log = std.log.scoped(.lsp_document);

src: []const u8,
errors: []const tiny.Error,
nodes: []const tiny.Node,
air: ?tiny.Air,

pub fn deinit(doc: *Document, gpa: std.mem.Allocator) void {
    gpa.free(doc.nodes);
    gpa.free(doc.errors);
    if (doc.air) |air| air.deinit(gpa);
}

pub fn init(
    gpa: std.mem.Allocator,
    source: []const u8,
) error{OutOfMemory}!Document {
    var errors = std.ArrayList(tiny.Error).init(gpa);
    errdefer errors.deinit();

    const nodes = try tiny.parse.parse(gpa, source, true, &errors);
    errdefer gpa.free(nodes);

    if (errors.items.len > 0) {
        return .{
            .src = source,
            .errors = try errors.toOwnedSlice(),
            .nodes = nodes,
            .air = null,
        };
    } else {
        const air = try tiny.parse.analyze(gpa, nodes, source, &errors);
        errdefer air.deinit(gpa);
        return .{
            .src = source,
            .errors = try errors.toOwnedSlice(),
            .nodes = nodes,
            .air = air,
        };
    }
}

pub fn reparse(doc: *Document, gpa: std.mem.Allocator) !void {
    doc.deinit(gpa);
    doc.* = doc.init(doc.src);
}
