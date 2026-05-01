const std = @import("std");

pub const Request = struct {
    parsed: std.json.Parsed(std.json.Value),
    id: ?std.json.Value,
    method: []const u8,

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.parsed.deinit();
    }
};

pub fn decodeRequest(alloc: std.mem.Allocator, raw: []const u8) !Request {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
        return error.InvalidJSON;
    };
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJSON;

    const method_value = parsed.value.object.get("method") orelse return error.InvalidJSON;
    if (method_value != .string) return error.InvalidJSON;

    return .{
        .parsed = parsed,
        .id = parsed.value.object.get("id"),
        .method = method_value.string,
    };
}

pub fn encodeResponse(alloc: std.mem.Allocator, response: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    return try out.toOwnedSlice();
}

test "decode hello request" {
    const raw = "{\"id\":1,\"method\":\"hello\",\"params\":{}}";
    var req = try decodeRequest(std.testing.allocator, raw);
    defer req.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", req.method);
}

test "encode ok response" {
    const encoded = try encodeResponse(std.testing.allocator, .{
        .id = 1,
        .ok = true,
        .result = .{ .pong = true },
    });
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"ok\":true") != null);
}

test "reject malformed json line" {
    try std.testing.expectError(error.InvalidJSON, decodeRequest(std.testing.allocator, "{"));
}
