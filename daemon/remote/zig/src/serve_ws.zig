const std = @import("std");
const connection_attachments = @import("connection_attachments.zig");
const json_rpc = @import("json_rpc.zig");
const server_core = @import("server_core.zig");
const session_service = @import("session_service.zig");

pub const Config = struct {
    listen_addr: []const u8,
    secret: []const u8,
    instance_id: []const u8 = "",
};

pub fn serve(cfg: Config) !void {
    if (cfg.listen_addr.len == 0 or cfg.secret.len == 0) return error.MissingWSConfig;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var service = session_service.Service.init(alloc);
    defer service.deinit();
    service.on_workspace_changed = &server_core.notifyWorkspaceSubscribers;
    service.ensurePumpStarted();
    service.ensureWriterStarted();

    serveShared(&service, try std.fmt.parseInt(u16, blk: {
        const colon = std.mem.lastIndexOfScalar(u8, cfg.listen_addr, ':') orelse break :blk cfg.listen_addr;
        break :blk cfg.listen_addr[colon + 1 ..];
    }, 10), cfg.secret, cfg.instance_id) catch {};
}

/// Serve WebSocket on the given port, sharing an existing session service.
/// Intended to be called from a spawned thread alongside serve_unix.
pub fn serveShared(service: *session_service.Service, port: u16, secret: []const u8, instance_id: []const u8) !void {
    service.instance_id = instance_id;
    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleClientThreadShared, .{ service, secret, conn.stream });
        thread.detach();
    }
}

const SharedService = struct {
    service: session_service.Service,
};

fn handleClientThread(shared: *SharedService, secret: []const u8, stream: std.net.Stream) void {
    handleClient(&shared.service, secret, stream) catch {};
}

fn handleClientThreadShared(service: *session_service.Service, secret: []const u8, stream: std.net.Stream) void {
    handleClient(service, secret, stream) catch {};
}

fn handleClient(service: *session_service.Service, secret: []const u8, stream: std.net.Stream) !void {
    var mutable_stream = stream;
    defer stream.close();

    var read_buf: [8192]u8 = undefined;
    const http_req = try readHttpRequest(stream, &read_buf);

    const ws_key = extractWebSocketKey(http_req) orelse return error.MissingWebSocketKey;
    if (!isWebSocketUpgrade(http_req)) return error.NotWebSocketUpgrade;

    try sendUpgradeResponse(stream, ws_key);

    // Auth: first message must be {"secret":"<value>"}
    const auth_msg = (try readWsTextMessage(stream, std.heap.page_allocator)) orelse return;
    defer std.heap.page_allocator.free(auth_msg);

    const authenticated = verifySecret(auth_msg, secret);
    if (authenticated) {
        try sendWsTextMessage(stream, "{\"ok\":true,\"result\":{\"authenticated\":true}}");
    } else {
        try sendWsTextMessage(stream, "{\"ok\":false,\"error\":{\"code\":\"unauthorized\",\"message\":\"invalid secret\"}}");
        return;
    }

    // Broadcast the current workspace state to the freshly connected
    // client. iOS reconnect path then has the full picture before it
    // even sends `workspace.subscribe`, so a mac reload that tears down
    // the daemon and respawns recovers in a single round-trip instead
    // of waiting for the client's exponential-backoff probe.
    if (server_core.encodeWorkspaceChangedEvent(service, std.heap.page_allocator)) |snapshot| {
        defer std.heap.page_allocator.free(snapshot);
        sendWsTextMessage(stream, snapshot) catch {};
    }

    var subscribed = false;
    var write_mutex: std.Thread.Mutex = .{};
    var attachments = connection_attachments.Tracker.init(service.alloc);
    defer attachments.deinit();
    defer attachments.detachAll(service);
    defer if (subscribed) {
        service.subscriptions.remove(&mutable_stream);
    };
    // Always sweep terminal subscriptions on disconnect so the pump thread
    // doesn't push to a closed fd.
    defer service.unsubscribeAllForStream(&mutable_stream);

    // Request loop
    while (true) {
        const msg = (try readWsTextMessage(stream, std.heap.page_allocator)) orelse return;
        defer std.heap.page_allocator.free(msg);

        if (msg.len == 0) continue;

        // Check if this is a workspace.subscribe request
        if (!subscribed and std.mem.indexOf(u8, msg, "workspace.subscribe") != null) {
            service.subscriptions.add(service.alloc, &mutable_stream) catch {};
            subscribed = true;
        }

        // terminal.subscribe / terminal.unsubscribe need the stream pointer
        // and per-stream write lock, so they bypass server_core.dispatch.
        const alloc = service.alloc;
        var req = json_rpc.decodeRequest(alloc, msg) catch {
            const err_resp = try json_rpc.encodeResponse(alloc, .{
                .ok = false,
                .@"error" = .{
                    .code = "invalid_request",
                    .message = "invalid JSON request",
                },
            });
            defer alloc.free(err_resp);
            try sendWsTextMessageLocked(&write_mutex, stream, err_resp);
            continue;
        };
        defer req.deinit(alloc);

        if (std.mem.eql(u8, req.method, "terminal.subscribe")) {
            const response = try handleTerminalSubscribe(service, &mutable_stream, &write_mutex, &req);
            defer alloc.free(response);
            try sendWsTextMessageLocked(&write_mutex, stream, response);
            continue;
        }
        if (std.mem.eql(u8, req.method, "terminal.unsubscribe")) {
            const response = try handleTerminalUnsubscribe(service, &mutable_stream, &req);
            defer alloc.free(response);
            try sendWsTextMessageLocked(&write_mutex, stream, response);
            continue;
        }

        const response = try server_core.dispatch(service, &req);
        defer alloc.free(response);
        attachments.recordResponse(&req, response);
        try sendWsTextMessageLocked(&write_mutex, stream, response);
    }
}

fn sendWsTextMessageLocked(lock: *std.Thread.Mutex, stream: std.net.Stream, data: []const u8) !void {
    lock.lock();
    defer lock.unlock();
    try sendWsTextMessage(stream, data);
}

fn handleTerminalSubscribe(
    service: *session_service.Service,
    stream: *std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    req: *const json_rpc.Request,
) ![]u8 {
    const alloc = service.alloc;
    const params_value = req.parsed.value.object.get("params") orelse {
        return try errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires params");
    };
    if (params_value != .object) return try errorResp(alloc, req.id, "invalid_params", "params must be object");
    const session_id_v = params_value.object.get("session_id") orelse {
        return try errorResp(alloc, req.id, "invalid_params", "terminal.subscribe requires session_id");
    };
    if (session_id_v != .string) return try errorResp(alloc, req.id, "invalid_params", "session_id must be string");
    const session_id = session_id_v.string;

    const requested_offset: ?u64 = blk: {
        const off_v = params_value.object.get("offset") orelse break :blk null;
        if (off_v != .integer) break :blk null;
        if (off_v.integer < 0) break :blk null;
        break :blk @intCast(off_v.integer);
    };

    const snap = service.subscribeTerminal(stream, write_mutex, session_id, requested_offset) catch |err| switch (err) {
        error.TerminalSessionNotFound => return try errorResp(alloc, req.id, "not_found", "terminal session not found"),
        else => return try errorResp(alloc, req.id, "internal_error", @errorName(err)),
    };
    defer alloc.free(snap.data);

    const enc_len = std.base64.standard.Encoder.calcSize(snap.data.len);
    const enc = try alloc.alloc(u8, enc_len);
    defer alloc.free(enc);
    _ = std.base64.standard.Encoder.encode(enc, snap.data);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .seq = snap.seq,
            .offset = snap.offset,
            .base_offset = snap.base_offset,
            .truncated = snap.truncated,
            .eof = snap.eof,
            .data = enc,
        },
    });
}

fn handleTerminalUnsubscribe(
    service: *session_service.Service,
    stream: *std.net.Stream,
    req: *const json_rpc.Request,
) ![]u8 {
    const alloc = service.alloc;
    const params_value = req.parsed.value.object.get("params") orelse {
        return try errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires params");
    };
    if (params_value != .object) return try errorResp(alloc, req.id, "invalid_params", "params must be object");
    const session_id_v = params_value.object.get("session_id") orelse {
        return try errorResp(alloc, req.id, "invalid_params", "terminal.unsubscribe requires session_id");
    };
    if (session_id_v != .string) return try errorResp(alloc, req.id, "invalid_params", "session_id must be string");

    const removed = service.unsubscribeTerminal(stream, session_id_v.string);
    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .removed = removed },
    });
}

fn errorResp(alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    });
}

// --- HTTP upgrade ---

fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) {
            return buf[0..total];
        }
    }
    return error.HttpRequestTooLarge;
}

fn isWebSocketUpgrade(req: []const u8) bool {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    while (it.next()) |line| {
        if (asciiStartsWithIgnoreCase(line, "upgrade:")) {
            const val = std.mem.trim(u8, line["upgrade:".len..], " \t");
            if (asciiEqlIgnoreCase(val, "websocket")) return true;
        }
    }
    return false;
}

fn extractWebSocketKey(req: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    while (it.next()) |line| {
        if (asciiStartsWithIgnoreCase(line, "sec-websocket-key:")) {
            return std.mem.trim(u8, line["sec-websocket-key:".len..], " \t");
        }
    }
    return null;
}

fn sendUpgradeResponse(stream: std.net.Stream, ws_key: []const u8) !void {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(ws_key);
    hasher.update(magic);
    const digest = hasher.finalResult();

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return error.ResponseTooLarge;
    _ = try stream.write(resp);
}

// --- WebSocket framing ---

fn readWsTextMessage(stream: std.net.Stream, alloc: std.mem.Allocator) !?[]u8 {
    // Read 2-byte header
    var header: [2]u8 = undefined;
    if (try readExact(stream, &header) != 2) return null;

    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;

    // Handle close
    if (opcode == 0x08) return null;

    // Handle ping: read payload and send pong
    if (opcode == 0x09) {
        const ping_payload = try readWsPayload(stream, header[1] & 0x7F, masked, alloc);
        defer alloc.free(ping_payload);
        try sendWsFrame(stream, 0x0A, ping_payload);
        return try readWsTextMessage(stream, alloc);
    }

    // Only accept text frames
    if (opcode != 0x01) {
        // Skip unknown frames
        const skip_payload = try readWsPayload(stream, header[1] & 0x7F, masked, alloc);
        alloc.free(skip_payload);
        return try readWsTextMessage(stream, alloc);
    }

    return try readWsPayload(stream, header[1] & 0x7F, masked, alloc);
}

fn readWsPayload(stream: std.net.Stream, len_byte: u8, masked: bool, alloc: std.mem.Allocator) ![]u8 {
    var payload_len: u64 = len_byte;
    if (len_byte == 126) {
        var ext: [2]u8 = undefined;
        if (try readExact(stream, &ext) != 2) return error.ConnectionClosed;
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (len_byte == 127) {
        var ext: [8]u8 = undefined;
        if (try readExact(stream, &ext) != 8) return error.ConnectionClosed;
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    if (payload_len > 4 * 1024 * 1024) return error.FrameTooLarge;

    var mask_key: [4]u8 = undefined;
    if (masked) {
        if (try readExact(stream, &mask_key) != 4) return error.ConnectionClosed;
    }

    const payload = try alloc.alloc(u8, @intCast(payload_len));
    errdefer alloc.free(payload);
    if (payload.len > 0) {
        if (try readExact(stream, payload) != payload.len) {
            alloc.free(payload);
            return error.ConnectionClosed;
        }
    }

    if (masked) {
        for (payload, 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
    }

    return payload;
}

fn sendWsTextMessage(stream: std.net.Stream, data: []const u8) !void {
    try sendWsFrame(stream, 0x01, data);
}

fn sendWsFrame(stream: std.net.Stream, opcode: u8, data: []const u8) !void {
    // FIN bit + opcode
    var header: [10]u8 = undefined;
    header[0] = 0x80 | opcode;

    var header_len: usize = 2;
    if (data.len <= 125) {
        header[1] = @intCast(data.len);
    } else if (data.len <= 65535) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(data.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @intCast(data.len), .big);
        header_len = 10;
    }

    _ = try stream.write(header[0..header_len]);
    if (data.len > 0) {
        _ = try stream.write(data);
    }
}

fn readExact(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return total;
        total += n;
    }
    return total;
}

// --- Auth ---

fn verifySecret(msg: []const u8, expected: []const u8) bool {
    const parsed = std.json.parseFromSlice(struct { secret: []const u8 }, std.heap.page_allocator, msg, .{}) catch return false;
    defer parsed.deinit();
    const provided = parsed.value.secret;
    if (provided.len != expected.len) return false;
    var diff: u8 = 0;
    for (provided, expected) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

// --- Helpers ---

fn listen(listen_addr: []const u8) !std.net.Server {
    const colon = std.mem.lastIndexOfScalar(u8, listen_addr, ':') orelse return error.InvalidListenAddress;
    const host = listen_addr[0..colon];
    const port = try std.fmt.parseInt(u16, listen_addr[colon + 1 ..], 10);
    const address = try std.net.Address.parseIp(host, port);
    return address.listen(.{ .reuse_address = true });
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return asciiEqlIgnoreCase(haystack[0..prefix.len], prefix);
}
