const std = @import("std");
const json_rpc = @import("json_rpc.zig");

pub const Handshake = struct {
    ticket: []const u8,
};

pub const TicketClaims = struct {
    server_id: []u8,
    team_id: []u8,
    session_id: []u8,
    attachment_id: []u8,
    capabilities: [][]u8,
    expires_at: i64,
    nonce: []u8,

    pub fn deinit(self: *TicketClaims, alloc: std.mem.Allocator) void {
        alloc.free(self.server_id);
        alloc.free(self.team_id);
        alloc.free(self.session_id);
        alloc.free(self.attachment_id);
        for (self.capabilities) |capability| {
            alloc.free(capability);
        }
        alloc.free(self.capabilities);
        alloc.free(self.nonce);
    }
};

pub const VerifyError = error{
    MalformedTicket,
    InvalidSignature,
    ExpiredTicket,
    WrongServer,
    MissingTicket,
    MissingAttachCapability,
    MissingTicketNonce,
    ReplayedTicket,
    OutOfMemory,
};

pub fn verifyErrorMessage(err: VerifyError) []const u8 {
    return switch (err) {
        error.MalformedTicket => "malformed ticket",
        error.InvalidSignature => "invalid ticket signature",
        error.ExpiredTicket => "ticket expired",
        error.WrongServer => "ticket server mismatch",
        error.MissingTicket => "ticket is required",
        error.MissingAttachCapability => "ticket missing session capability",
        error.MissingTicketNonce => "ticket nonce is required",
        error.ReplayedTicket => "ticket nonce already used",
        error.OutOfMemory => "ticket verification ran out of memory",
    };
}

pub const Unauthorized = struct {
    message: []const u8,
};

const RequestGrant = enum {
    none,
    open,
    attach,
};

pub const TicketVerifier = struct {
    alloc: std.mem.Allocator,
    server_id: []const u8,
    ticket_secret: []const u8,
    used_nonces: std.StringHashMap(i64),

    pub fn init(alloc: std.mem.Allocator, server_id: []const u8, ticket_secret: []const u8) TicketVerifier {
        return .{
            .alloc = alloc,
            .server_id = server_id,
            .ticket_secret = ticket_secret,
            .used_nonces = std.StringHashMap(i64).init(alloc),
        };
    }

    pub fn deinit(self: *TicketVerifier) void {
        var iter = self.used_nonces.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.used_nonces.deinit();
    }

    pub fn verifyHandshake(self: *TicketVerifier, hs: Handshake) VerifyError!TicketClaims {
        if (hs.ticket.len == 0) return error.MissingTicket;

        var claims = try verifyTicket(self.alloc, hs.ticket, self.ticket_secret, self.server_id);
        errdefer claims.deinit(self.alloc);

        if (!hasSessionCapability(claims.capabilities)) return error.MissingAttachCapability;
        if (claims.nonce.len == 0) return error.MissingTicketNonce;
        try self.consumeNonce(claims.nonce, claims.expires_at);
        return claims;
    }

    fn consumeNonce(self: *TicketVerifier, nonce: []const u8, expires_at: i64) VerifyError!void {
        const now = std.time.timestamp();

        var iter = self.used_nonces.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* <= now) {
                self.alloc.free(entry.key_ptr.*);
                _ = self.used_nonces.remove(entry.key_ptr.*);
            }
        }

        if (self.used_nonces.contains(nonce)) return error.ReplayedTicket;
        try self.used_nonces.put(try self.alloc.dupe(u8, nonce), expires_at);
    }
};

pub const RequestAuthorizer = struct {
    alloc: std.mem.Allocator,
    capabilities: std.StringHashMap(void),
    claimed_session_id: []u8,
    claimed_attachment_id: []u8,
    active_session_id: []u8,
    active_attachment_id: []u8,
    grant: RequestGrant = .none,
    used: bool = false,

    pub fn init(alloc: std.mem.Allocator, claims: TicketClaims) !RequestAuthorizer {
        var capabilities = std.StringHashMap(void).init(alloc);
        errdefer {
            var iter = capabilities.iterator();
            while (iter.next()) |entry| {
                alloc.free(entry.key_ptr.*);
            }
            capabilities.deinit();
        }

        for (claims.capabilities) |capability| {
            try capabilities.put(try alloc.dupe(u8, capability), {});
        }

        return .{
            .alloc = alloc,
            .capabilities = capabilities,
            .claimed_session_id = try alloc.dupe(u8, claims.session_id),
            .claimed_attachment_id = try alloc.dupe(u8, claims.attachment_id),
            .active_session_id = try alloc.dupe(u8, ""),
            .active_attachment_id = try alloc.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *RequestAuthorizer) void {
        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.capabilities.deinit();
        self.alloc.free(self.claimed_session_id);
        self.alloc.free(self.claimed_attachment_id);
        self.alloc.free(self.active_session_id);
        self.alloc.free(self.active_attachment_id);
    }

    pub fn authorize(self: *RequestAuthorizer, req: *const json_rpc.Request) ?Unauthorized {
        if (std.mem.eql(u8, req.method, "hello") or std.mem.eql(u8, req.method, "ping")) return null;
        if (std.mem.eql(u8, req.method, "terminal.open")) return self.authorizeTerminalOpen();
        if (std.mem.eql(u8, req.method, "session.attach")) return self.authorizeSessionAttach(req);
        if (std.mem.eql(u8, req.method, "terminal.read") or std.mem.eql(u8, req.method, "terminal.write") or std.mem.eql(u8, req.method, "session.status") or std.mem.eql(u8, req.method, "session.close")) {
            return self.authorizeEstablishedSession(req, false);
        }
        if (std.mem.eql(u8, req.method, "session.resize") or std.mem.eql(u8, req.method, "session.detach")) {
            return self.authorizeEstablishedSession(req, true);
        }
        return .{ .message = "request is not allowed for this direct ticket" };
    }

    pub fn observe(self: *RequestAuthorizer, req: *const json_rpc.Request, encoded_response: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, encoded_response, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const ok_value = parsed.value.object.get("ok") orelse return;
        if (ok_value != .bool or !ok_value.bool) return;

        if (std.mem.eql(u8, req.method, "terminal.open")) {
            const result = parsed.value.object.get("result") orelse return;
            const session_id = getStringFieldFromValue(result, "session_id") orelse return;
            const attachment_id = getStringFieldFromValue(result, "attachment_id") orelse return;
            try self.setActiveScope(session_id, attachment_id);
            self.grant = .open;
            self.used = true;
            return;
        }
        if (std.mem.eql(u8, req.method, "session.attach")) {
            const session_id = getStringParam(req, "session_id") orelse return;
            const attachment_id = getStringParam(req, "attachment_id") orelse return;
            try self.setActiveScope(session_id, attachment_id);
            self.grant = .attach;
            self.used = true;
            return;
        }
        if (std.mem.eql(u8, req.method, "session.close") or std.mem.eql(u8, req.method, "session.detach")) {
            self.grant = .none;
        }
    }

    fn authorizeTerminalOpen(self: *RequestAuthorizer) ?Unauthorized {
        if (!self.capabilities.contains("session.open")) {
            return .{ .message = "ticket missing session.open capability" };
        }
        if (self.used) {
            return .{ .message = "ticket is already bound to a terminal session" };
        }
        return null;
    }

    fn authorizeSessionAttach(self: *RequestAuthorizer, req: *const json_rpc.Request) ?Unauthorized {
        if (!self.capabilities.contains("session.attach")) {
            return .{ .message = "ticket missing session.attach capability" };
        }

        const session_id = getStringParam(req, "session_id") orelse return null;
        const attachment_id = getStringParam(req, "attachment_id") orelse return null;

        const allowed = self.allowedAttachScope() orelse return .{ .message = "ticket is not scoped to this session attachment" };
        if (!std.mem.eql(u8, session_id, allowed.session_id) or !std.mem.eql(u8, attachment_id, allowed.attachment_id)) {
            return .{ .message = "request exceeds direct ticket session scope" };
        }
        return null;
    }

    fn authorizeEstablishedSession(self: *RequestAuthorizer, req: *const json_rpc.Request, needs_attachment: bool) ?Unauthorized {
        const session_id = getStringParam(req, "session_id") orelse return null;
        const attachment_id = if (needs_attachment) getStringParam(req, "attachment_id") orelse return null else "";

        if (self.grant == .none or self.active_session_id.len == 0) {
            return .{ .message = "request requires an opened or attached terminal session" };
        }
        if (!std.mem.eql(u8, session_id, self.active_session_id)) {
            return .{ .message = "request exceeds direct ticket session scope" };
        }
        if (needs_attachment and !std.mem.eql(u8, attachment_id, self.active_attachment_id)) {
            return .{ .message = "request exceeds direct ticket attachment scope" };
        }
        return null;
    }

    fn allowedAttachScope(self: *RequestAuthorizer) ?struct { session_id: []const u8, attachment_id: []const u8 } {
        if (self.grant != .none and self.active_session_id.len > 0 and self.active_attachment_id.len > 0) {
            return .{
                .session_id = self.active_session_id,
                .attachment_id = self.active_attachment_id,
            };
        }
        if (self.claimed_session_id.len > 0 and self.claimed_attachment_id.len > 0) {
            return .{
                .session_id = self.claimed_session_id,
                .attachment_id = self.claimed_attachment_id,
            };
        }
        return null;
    }

    fn setActiveScope(self: *RequestAuthorizer, session_id: []const u8, attachment_id: []const u8) !void {
        self.alloc.free(self.active_session_id);
        self.alloc.free(self.active_attachment_id);
        self.active_session_id = try self.alloc.dupe(u8, session_id);
        self.active_attachment_id = try self.alloc.dupe(u8, attachment_id);
    }
};

pub fn signTicket(alloc: std.mem.Allocator, claims: struct {
    server_id: []const u8,
    team_id: []const u8 = "",
    session_id: []const u8 = "",
    attachment_id: []const u8 = "",
    capabilities: []const []const u8,
    expires_at: i64,
    nonce: []const u8,
}, secret: []const u8) ![]u8 {
    const payload = try std.json.stringifyAlloc(alloc, .{
        .server_id = claims.server_id,
        .team_id = claims.team_id,
        .session_id = claims.session_id,
        .attachment_id = claims.attachment_id,
        .capabilities = claims.capabilities,
        .exp = claims.expires_at,
        .nonce = claims.nonce,
    }, .{});
    defer alloc.free(payload);

    const encoded_payload = try base64UrlEncodeAlloc(alloc, payload);
    defer alloc.free(encoded_payload);
    const signature = sign(encoded_payload, secret);
    const encoded_signature = try base64UrlEncodeAlloc(alloc, &signature);
    defer alloc.free(encoded_signature);

    return try std.fmt.allocPrint(alloc, "{s}.{s}", .{ encoded_payload, encoded_signature });
}

pub fn verifyTicket(alloc: std.mem.Allocator, token: []const u8, secret: []const u8, expected_server_id: []const u8) VerifyError!TicketClaims {
    const dot_index = std.mem.indexOfScalar(u8, token, '.') orelse return error.MalformedTicket;
    if (std.mem.indexOfScalar(u8, token[dot_index + 1 ..], '.')) |_| return error.MalformedTicket;

    const payload_token = token[0..dot_index];
    const signature_token = token[dot_index + 1 ..];

    const signature = base64UrlDecodeAlloc(alloc, signature_token) catch return error.MalformedTicket;
    defer alloc.free(signature);

    const expected_signature = sign(payload_token, secret);
    if (signature.len != expected_signature.len or !std.mem.eql(u8, signature, &expected_signature)) {
        return error.InvalidSignature;
    }

    const payload = base64UrlDecodeAlloc(alloc, payload_token) catch return error.MalformedTicket;
    defer alloc.free(payload);

    var claims = try parseClaims(alloc, payload);
    errdefer claims.deinit(alloc);

    if (claims.expires_at <= std.time.timestamp()) return error.ExpiredTicket;
    if (expected_server_id.len > 0 and !std.mem.eql(u8, claims.server_id, expected_server_id)) return error.WrongServer;
    return claims;
}

fn parseClaims(alloc: std.mem.Allocator, payload: []const u8) VerifyError!TicketClaims {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return error.MalformedTicket;
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedTicket;
    const object = parsed.value.object;

    const server_id = getStringFieldFromObject(object, "server_id") orelse return error.MalformedTicket;
    const team_id = getStringFieldFromObject(object, "team_id") orelse "";
    const session_id = getStringFieldFromObject(object, "session_id") orelse "";
    const attachment_id = getStringFieldFromObject(object, "attachment_id") orelse "";
    const expires_at = getIntegerFieldFromObject(object, "exp") orelse return error.MalformedTicket;
    const nonce = getStringFieldFromObject(object, "nonce") orelse "";

    const capabilities_value = object.get("capabilities") orelse return error.MalformedTicket;
    if (capabilities_value != .array) return error.MalformedTicket;

    var capabilities = try alloc.alloc([]u8, capabilities_value.array.items.len);
    errdefer {
        for (capabilities[0..]) |capability| {
            alloc.free(capability);
        }
        alloc.free(capabilities);
    }
    for (capabilities_value.array.items, 0..) |item, idx| {
        if (item != .string) return error.MalformedTicket;
        capabilities[idx] = try alloc.dupe(u8, item.string);
    }

    return .{
        .server_id = try alloc.dupe(u8, server_id),
        .team_id = try alloc.dupe(u8, team_id),
        .session_id = try alloc.dupe(u8, session_id),
        .attachment_id = try alloc.dupe(u8, attachment_id),
        .capabilities = capabilities,
        .expires_at = expires_at,
        .nonce = try alloc.dupe(u8, nonce),
    };
}

fn sign(payload: []const u8, secret: []const u8) [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(mac[0..], payload, secret);
    return mac;
}

fn base64UrlEncodeAlloc(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(source.len);
    const dest = try alloc.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(dest, source);
    return dest;
}

fn base64UrlDecodeAlloc(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(source);
    const dest = try alloc.alloc(u8, size);
    errdefer alloc.free(dest);
    try std.base64.url_safe_no_pad.Decoder.decode(dest, source);
    return dest;
}

fn hasSessionCapability(capabilities: [][]u8) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, "session.attach") or std.mem.eql(u8, capability, "session.open")) {
            return true;
        }
    }
    return false;
}

fn getStringParam(req: *const json_rpc.Request, key: []const u8) ?[]const u8 {
    const params = req.parsed.value.object.get("params") orelse return null;
    if (params != .object) return null;
    const value = params.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getStringFieldFromObject(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getIntegerFieldFromObject(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (@floor(float) == float) @as(i64, @intFromFloat(float)) else null,
        else => null,
    };
}

fn getStringFieldFromValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    return getStringFieldFromObject(value.object, key);
}

test "verify handshake rejects malformed, expired, missing nonce, and replayed tickets" {
    var verifier = TicketVerifier.init(std.testing.allocator, "cmux-macmini", "secret");
    defer verifier.deinit();

    try std.testing.expectError(error.MalformedTicket, verifier.verifyHandshake(.{ .ticket = "not-a-valid-ticket" }));

    const expired = try signTicket(std.testing.allocator, .{
        .server_id = "cmux-macmini",
        .session_id = "sess-1",
        .attachment_id = "att-1",
        .capabilities = &.{"session.attach"},
        .expires_at = std.time.timestamp() - 60,
        .nonce = "expired-nonce",
    }, "secret");
    defer std.testing.allocator.free(expired);
    try std.testing.expectError(error.ExpiredTicket, verifier.verifyHandshake(.{ .ticket = expired }));

    const missing_nonce = try signTicket(std.testing.allocator, .{
        .server_id = "cmux-macmini",
        .session_id = "sess-1",
        .attachment_id = "att-1",
        .capabilities = &.{"session.attach"},
        .expires_at = std.time.timestamp() + 60,
        .nonce = "",
    }, "secret");
    defer std.testing.allocator.free(missing_nonce);
    try std.testing.expectError(error.MissingTicketNonce, verifier.verifyHandshake(.{ .ticket = missing_nonce }));

    const replay = try signTicket(std.testing.allocator, .{
        .server_id = "cmux-macmini",
        .session_id = "sess-1",
        .attachment_id = "att-1",
        .capabilities = &.{"session.attach"},
        .expires_at = std.time.timestamp() + 60,
        .nonce = "replayed-nonce",
    }, "secret");
    defer std.testing.allocator.free(replay);

    var claims = try verifier.verifyHandshake(.{ .ticket = replay });
    claims.deinit(std.testing.allocator);
    try std.testing.expectError(error.ReplayedTicket, verifier.verifyHandshake(.{ .ticket = replay }));
}

test "verify handshake accepts valid attach ticket" {
    var verifier = TicketVerifier.init(std.testing.allocator, "cmux-macmini", "secret");
    defer verifier.deinit();

    const token = try signTicket(std.testing.allocator, .{
        .server_id = "cmux-macmini",
        .session_id = "sess-1",
        .attachment_id = "att-1",
        .capabilities = &.{"session.attach"},
        .expires_at = std.time.timestamp() + 60,
        .nonce = "n-1",
    }, "secret");
    defer std.testing.allocator.free(token);

    var claims = try verifier.verifyHandshake(.{ .ticket = token });
    defer claims.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sess-1", claims.session_id);
    try std.testing.expectEqualStrings("att-1", claims.attachment_id);
}

test "request authorizer rejects scoped session escape" {
    var authorizer = try RequestAuthorizer.init(std.testing.allocator, .{
        .server_id = try std.testing.allocator.dupe(u8, "cmux-macmini"),
        .team_id = try std.testing.allocator.dupe(u8, ""),
        .session_id = try std.testing.allocator.dupe(u8, "sess-1"),
        .attachment_id = try std.testing.allocator.dupe(u8, "att-1"),
        .capabilities = blk: {
            var caps = try std.testing.allocator.alloc([]u8, 1);
            caps[0] = try std.testing.allocator.dupe(u8, "session.attach");
            break :blk caps;
        },
        .expires_at = std.time.timestamp() + 60,
        .nonce = try std.testing.allocator.dupe(u8, "n-1"),
    });
    defer authorizer.deinit();

    var req = try json_rpc.decodeRequest(std.testing.allocator, "{\"id\":1,\"method\":\"session.resize\",\"params\":{\"session_id\":\"sess-2\",\"attachment_id\":\"att-1\",\"cols\":120,\"rows\":40}}");
    defer req.deinit(std.testing.allocator);

    const unauthorized = authorizer.authorize(&req) orelse return error.TestExpectedError;
    try std.testing.expectEqualStrings("request exceeds direct ticket session scope", unauthorized.message);
}

test "request authorizer binds fresh session and rejects second terminal open" {
    var claims = TicketClaims{
        .server_id = try std.testing.allocator.dupe(u8, "cmux-macmini"),
        .team_id = try std.testing.allocator.dupe(u8, ""),
        .session_id = try std.testing.allocator.dupe(u8, ""),
        .attachment_id = try std.testing.allocator.dupe(u8, ""),
        .capabilities = blk: {
            var caps = try std.testing.allocator.alloc([]u8, 1);
            caps[0] = try std.testing.allocator.dupe(u8, "session.open");
            break :blk caps;
        },
        .expires_at = std.time.timestamp() + 60,
        .nonce = try std.testing.allocator.dupe(u8, "n-2"),
    };
    defer claims.deinit(std.testing.allocator);

    var authorizer = try RequestAuthorizer.init(std.testing.allocator, claims);
    defer authorizer.deinit();

    var open_req = try json_rpc.decodeRequest(std.testing.allocator, "{\"id\":1,\"method\":\"terminal.open\",\"params\":{\"command\":\"sh\",\"cols\":120,\"rows\":40}}");
    defer open_req.deinit(std.testing.allocator);
    try std.testing.expect(authorizer.authorize(&open_req) == null);

    const open_resp = try json_rpc.encodeResponse(std.testing.allocator, .{
        .id = 1,
        .ok = true,
        .result = .{
            .session_id = "sess-1",
            .attachment_id = "att-1",
        },
    });
    defer std.testing.allocator.free(open_resp);
    try authorizer.observe(&open_req, open_resp);

    var write_req = try json_rpc.decodeRequest(std.testing.allocator, "{\"id\":2,\"method\":\"terminal.write\",\"params\":{\"session_id\":\"sess-1\",\"data\":\"aGVsbG8K\"}}");
    defer write_req.deinit(std.testing.allocator);
    try std.testing.expect(authorizer.authorize(&write_req) == null);

    const second_open = authorizer.authorize(&open_req) orelse return error.TestExpectedError;
    try std.testing.expectEqualStrings("ticket is already bound to a terminal session", second_open.message);
}
