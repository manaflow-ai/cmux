const std = @import("std");
const tls = @import("tls");
const json_rpc = @import("json_rpc.zig");
const server_core = @import("server_core.zig");
const session_service = @import("session_service.zig");
const ticket_auth = @import("ticket_auth.zig");

pub const Config = struct {
    listen_addr: []const u8,
    server_id: []const u8,
    ticket_secret: []const u8,
    cert_file: []const u8,
    key_file: []const u8,
};

pub fn serve(cfg: Config) !void {
    if (cfg.listen_addr.len == 0 or cfg.server_id.len == 0 or cfg.ticket_secret.len == 0 or cfg.cert_file.len == 0 or cfg.key_file.len == 0) {
        return error.MissingTLSConfig;
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var service = session_service.Service.init(alloc);
    defer service.deinit();
    service.on_workspace_changed = &server_core.notifyWorkspaceSubscribers;
    service.ensurePumpStarted();
    service.ensureWriterStarted();

    var verifier = ticket_auth.TicketVerifier.init(alloc, cfg.server_id, cfg.ticket_secret);
    defer verifier.deinit();

    var auth = try tls.config.CertKeyPair.fromFilePathAbsolute(alloc, cfg.cert_file, cfg.key_file);
    defer auth.deinit(alloc);

    var server = try listen(cfg.listen_addr);
    defer server.deinit();

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        serveConn(alloc, &service, &verifier, &auth, conn.stream) catch {};
    }
}

fn serveConn(
    alloc: std.mem.Allocator,
    service: *session_service.Service,
    verifier: *ticket_auth.TicketVerifier,
    auth: *tls.config.CertKeyPair,
    stream: std.net.Stream,
) !void {
    var tls_conn = tls.serverFromStream(stream, .{ .auth = auth }) catch return;
    defer tls_conn.close() catch {};

    const handshake_line = (try readLine(alloc, &tls_conn, 4 * 1024 * 1024)) orelse return;
    defer alloc.free(handshake_line);

    const handshake_trimmed = std.mem.trimRight(u8, handshake_line, "\r\n");
    var parsed_handshake = std.json.parseFromSlice(ticket_auth.Handshake, alloc, handshake_trimmed, .{}) catch {
        return writeError(&tls_conn, alloc, null, "invalid_request", "invalid JSON handshake");
    };
    defer parsed_handshake.deinit();

    var claims = verifier.verifyHandshake(parsed_handshake.value) catch |err| {
        return writeError(&tls_conn, alloc, null, "unauthorized", ticket_auth.verifyErrorMessage(err));
    };
    defer claims.deinit(alloc);

    var authorizer = try ticket_auth.RequestAuthorizer.init(alloc, claims);
    defer authorizer.deinit();

    try writePayload(&tls_conn, alloc, try json_rpc.encodeResponse(alloc, .{
        .ok = true,
        .result = .{ .authenticated = true },
    }));

    while (true) {
        const raw_line = (try readLine(alloc, &tls_conn, 4 * 1024 * 1024)) orelse return;
        defer alloc.free(raw_line);

        const trimmed = std.mem.trimRight(u8, raw_line, "\r\n");
        if (trimmed.len == 0) continue;

        var req = json_rpc.decodeRequest(alloc, trimmed) catch {
            try writeError(&tls_conn, alloc, null, "invalid_request", "invalid JSON request");
            continue;
        };
        defer req.deinit(alloc);

        if (authorizer.authorize(&req)) |unauthorized| {
            try writeError(&tls_conn, alloc, req.id, "unauthorized", unauthorized.message);
            continue;
        }

        const response = try server_core.dispatch(service, &req);
        defer alloc.free(response);
        try authorizer.observe(&req, response);
        try tls_conn.writeAll(response);
        try tls_conn.writeAll("\n");
    }
}

fn listen(listen_addr: []const u8) !std.net.Server {
    const colon = std.mem.lastIndexOfScalar(u8, listen_addr, ':') orelse return error.InvalidListenAddress;
    const host = listen_addr[0..colon];
    const port = try std.fmt.parseInt(u16, listen_addr[colon + 1 ..], 10);
    const address = try std.net.Address.parseIp(host, port);
    return address.listen(.{ .reuse_address = true });
}

fn readLine(
    alloc: std.mem.Allocator,
    conn: *tls.Connection,
    max_bytes: usize,
) !?[]u8 {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(alloc);

    var byte: [1]u8 = undefined;
    while (line.items.len < max_bytes) {
        const n = try conn.read(&byte);
        if (n == 0) {
            if (line.items.len == 0) return null;
            break;
        }
        try line.append(alloc, byte[0]);
        if (byte[0] == '\n') break;
    }
    if (line.items.len >= max_bytes) return error.FrameTooLarge;
    return try line.toOwnedSlice(alloc);
}

fn writePayload(conn: *tls.Connection, alloc: std.mem.Allocator, payload: []u8) !void {
    defer alloc.free(payload);
    try conn.writeAll(payload);
    try conn.writeAll("\n");
}

fn writeError(
    conn: *tls.Connection,
    alloc: std.mem.Allocator,
    id: ?std.json.Value,
    code: []const u8,
    message: []const u8,
) !void {
    try writePayload(conn, alloc, try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }));
}
