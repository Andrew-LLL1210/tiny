const std = @import("std");
const lsp = @import("lsp");
const tiny = @import("tiny");
const lsp_namespace = @import("../lsp.zig");
const Handler = lsp_namespace.Handler;
const getErrRange = lsp_namespace.getErrRange;
const Document = @import("Document.zig");

const log = std.log.scoped(.tiny_lsp);

pub fn loadFile(
    self: *Handler,
    arena: std.mem.Allocator,
    new_text: [:0]const u8,
    uri: []const u8,
) !void {
    var res: lsp.types.PublishDiagnosticsParams = .{
        .uri = uri,
        .diagnostics = &.{},
    };

    var doc = try Document.init(
        self.gpa,
        new_text,
    );
    errdefer doc.deinit(self.gpa);

    log.debug("document init", .{});

    const gop = try self.files.getOrPut(self.gpa, uri);
    errdefer _ = self.files.remove(uri);

    if (gop.found_existing) {
        gop.value_ptr.deinit(self.gpa);
    } else {
        gop.key_ptr.* = try self.gpa.dupe(u8, uri);
    }

    gop.value_ptr.* = doc;

    if (doc.errors.len != 0) {
        const diags = try arena.alloc(lsp.types.Diagnostic, doc.errors.len);
        for (doc.errors, diags) |err, *d| {
            const range = getErrRange(err, doc.src);
            d.* = .{
                .range = range,
                .severity = .Error,
                .message = @tagName(err),
            };
        }
        res.diagnostics = diags;
    }

    const msg = try self.server.sendToClientNotification(
        "textDocument/publishDiagnostics",
        res,
    );

    defer self.gpa.free(msg);
}
