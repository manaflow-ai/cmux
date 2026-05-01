const std = @import("std");

const json_rpc = @import("json_rpc.zig");
const session_service = @import("session_service.zig");

const ConnectionAttachment = struct {
    session_id: []u8,
    attachment_id: []u8,
};

pub const Tracker = struct {
    alloc: std.mem.Allocator,
    items: std.ArrayList(ConnectionAttachment) = .empty,

    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Tracker) void {
        for (self.items.items) |item| {
            self.alloc.free(item.session_id);
            self.alloc.free(item.attachment_id);
        }
        self.items.deinit(self.alloc);
    }

    pub fn detachAll(self: *Tracker, service: *session_service.Service) void {
        for (self.items.items) |item| {
            service.detachSessionIfPresent(item.session_id, item.attachment_id);
        }
    }

    pub fn recordResponse(self: *Tracker, req: *const json_rpc.Request, response: []const u8) void {
        if (!responseOK(response)) return;
        if (std.mem.eql(u8, req.method, "session.attach")) {
            self.recordAttach(req) catch {};
        } else if (std.mem.eql(u8, req.method, "session.detach")) {
            self.recordDetach(req);
        }
    }

    fn recordAttach(self: *Tracker, req: *const json_rpc.Request) !void {
        const parsed = parseTrackedAttachment(req) orelse return;
        self.recordDetachValues(parsed.session_id, parsed.attachment_id);
        const session_id = try self.alloc.dupe(u8, parsed.session_id);
        errdefer self.alloc.free(session_id);
        const attachment_id = try self.alloc.dupe(u8, parsed.attachment_id);
        errdefer self.alloc.free(attachment_id);
        try self.items.append(self.alloc, .{
            .session_id = session_id,
            .attachment_id = attachment_id,
        });
    }

    fn recordDetach(self: *Tracker, req: *const json_rpc.Request) void {
        const parsed = parseTrackedAttachment(req) orelse return;
        self.recordDetachValues(parsed.session_id, parsed.attachment_id);
    }

    fn recordDetachValues(self: *Tracker, session_id: []const u8, attachment_id: []const u8) void {
        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const item = self.items.items[i];
            if (!std.mem.eql(u8, item.session_id, session_id)) continue;
            if (!std.mem.eql(u8, item.attachment_id, attachment_id)) continue;
            const removed = self.items.orderedRemove(i);
            self.alloc.free(removed.session_id);
            self.alloc.free(removed.attachment_id);
            return;
        }
    }
};

fn parseTrackedAttachment(req: *const json_rpc.Request) ?struct { session_id: []const u8, attachment_id: []const u8 } {
    const params = req.parsed.value.object.get("params") orelse return null;
    if (params != .object) return null;
    const session_id_v = params.object.get("session_id") orelse return null;
    const attachment_id_v = params.object.get("attachment_id") orelse return null;
    if (session_id_v != .string or attachment_id_v != .string) return null;
    return .{
        .session_id = session_id_v.string,
        .attachment_id = attachment_id_v.string,
    };
}

fn responseOK(response: []const u8) bool {
    return std.mem.indexOf(u8, response, "\"ok\":true") != null;
}
