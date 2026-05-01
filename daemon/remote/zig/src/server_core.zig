const std = @import("std");
const build_options = @import("build_options");
const json_rpc = @import("json_rpc.zig");
const persistence = @import("persistence.zig");
const session_registry = @import("session_registry.zig");
const session_service = @import("session_service.zig");
const workspace_registry = @import("workspace_registry.zig");
const serialize = @import("serialize.zig");

const AttachmentResult = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub fn handleLine(service: *session_service.Service, output: anytype, raw_line: []const u8) !void {
    const alloc = service.alloc;
    const trimmed = std.mem.trimRight(u8, raw_line, "\r");
    if (trimmed.len == 0) return;

    var req = json_rpc.decodeRequest(alloc, trimmed) catch {
        return writeResponse(output, alloc, try json_rpc.encodeResponse(alloc, .{
            .ok = false,
            .@"error" = .{
                .code = "invalid_request",
                .message = "invalid JSON request",
            },
        }));
    };
    defer req.deinit(alloc);

    const response = try dispatch(service, &req);
    try writeResponse(output, alloc, response);
}

pub fn dispatch(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const seq_before = service.workspace_reg.change_seq;
    const result = try dispatchInner(service, req);
    // If any workspace state changed, notify subscribers
    if (service.workspace_reg.change_seq != seq_before) {
        notifyWorkspaceSubscribers(service);
    }
    return result;
}

fn dispatchInner(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;

    if (std.mem.eql(u8, req.method, "hello")) {
        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{
                .name = "cmuxd-remote",
                .version = build_options.version,
                .instance_id = service.instance_id,
                .workspace_count = service.workspace_reg.order.items.len,
                .change_seq = service.workspace_reg.change_seq,
                .capabilities = .{
                    "session.basic",
                    "session.resize.min",
                    "session.resize.owner",
                    "terminal.stream",
                    "terminal.subscribe",
                    "workspace.subscribe",
                    "workspace.sync",
                    "workspace.set_color",
                    "workspace.open_pane",
                    "notifications.push",
                    "notifications.remote",
                    "proxy.http_connect",
                    "proxy.socks5",
                    "proxy.stream",
                },
            },
        });
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{ .pong = true },
        });
    }
    if (std.mem.eql(u8, req.method, "proxy.open")) return handleProxyOpen(service, req);
    if (std.mem.eql(u8, req.method, "proxy.close")) return handleProxyClose(service, req);
    if (std.mem.eql(u8, req.method, "proxy.write")) return handleProxyWrite(service, req);
    if (std.mem.eql(u8, req.method, "proxy.read")) return handleProxyRead(service, req);
    if (std.mem.eql(u8, req.method, "session.open")) return handleSessionOpen(service, req);
    if (std.mem.eql(u8, req.method, "session.close")) return handleSessionClose(service, req);
    if (std.mem.eql(u8, req.method, "session.attach")) return handleSessionAttach(service, req);
    if (std.mem.eql(u8, req.method, "session.resize")) return handleSessionResize(service, req);
    if (std.mem.eql(u8, req.method, "session.detach")) return handleSessionDetach(service, req);
    if (std.mem.eql(u8, req.method, "session.status")) return handleSessionStatus(service, req);
    if (std.mem.eql(u8, req.method, "session.list")) return handleSessionList(service, req);
    if (std.mem.eql(u8, req.method, "session.markRead")) return handleSessionMarkRead(service, req);
    if (std.mem.eql(u8, req.method, "daemon.configure_notifications")) return handleConfigureNotifications(service, req);
    if (std.mem.eql(u8, req.method, "session.history")) return handleSessionHistory(service, req);
    if (std.mem.eql(u8, req.method, "workspace.list")) return handleWorkspaceList(service, req);
    if (std.mem.eql(u8, req.method, "workspace.create")) return handleWorkspaceCreate(service, req);
    if (std.mem.eql(u8, req.method, "workspace.open_pane")) return handleWorkspaceOpenPane(service, req);
    if (std.mem.eql(u8, req.method, "workspace.rename")) return handleWorkspaceRename(service, req);
    if (std.mem.eql(u8, req.method, "workspace.pin")) return handleWorkspacePin(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setPinned")) return handleWorkspacePin(service, req);
    if (std.mem.eql(u8, req.method, "workspace.set_color")) return handleWorkspaceSetColor(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setColor")) return handleWorkspaceSetColor(service, req);
    if (std.mem.eql(u8, req.method, "workspace.set_unread")) return handleWorkspaceSetUnread(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setUnread")) return handleWorkspaceSetUnread(service, req);
    if (std.mem.eql(u8, req.method, "workspace.set_directory")) return handleWorkspaceSetDirectory(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setDirectory")) return handleWorkspaceSetDirectory(service, req);
    if (std.mem.eql(u8, req.method, "workspace.set_preview")) return handleWorkspaceSetPreview(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setPreview")) return handleWorkspaceSetPreview(service, req);
    if (std.mem.eql(u8, req.method, "workspace.set_phase")) return handleWorkspaceSetPhase(service, req);
    if (std.mem.eql(u8, req.method, "workspace.setPhase")) return handleWorkspaceSetPhase(service, req);
    if (std.mem.eql(u8, req.method, "workspace.reorder")) return handleWorkspaceReorder(service, req);
    if (std.mem.eql(u8, req.method, "workspace.close")) return handleWorkspaceClose(service, req);
    if (std.mem.eql(u8, req.method, "workspace.select")) return handleWorkspaceSelect(service, req);
    if (std.mem.eql(u8, req.method, "pane.split")) return handlePaneSplit(service, req);
    if (std.mem.eql(u8, req.method, "pane.close")) return handlePaneClose(service, req);
    if (std.mem.eql(u8, req.method, "pane.focus")) return handlePaneFocus(service, req);
    if (std.mem.eql(u8, req.method, "pane.setFocused")) return handlePaneFocus(service, req);
    if (std.mem.eql(u8, req.method, "pane.set_title")) return handlePaneSetTitle(service, req);
    if (std.mem.eql(u8, req.method, "pane.setTitle")) return handlePaneSetTitle(service, req);
    if (std.mem.eql(u8, req.method, "pane.resize")) return handlePaneResize(service, req);
    if (std.mem.eql(u8, req.method, "workspace.sync")) return handleWorkspaceSync(service, req);
    if (std.mem.eql(u8, req.method, "workspace.subscribe")) return handleWorkspaceSubscribe(service, req);
    if (std.mem.eql(u8, req.method, "workspace.history.list") or
        std.mem.eql(u8, req.method, "workspace.history.query"))
    {
        return handleWorkspaceHistoryQuery(service, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.history.clear")) return handleWorkspaceHistoryClear(service, req);
    if (std.mem.eql(u8, req.method, "terminal.open")) return handleTerminalOpen(service, req);
    if (std.mem.eql(u8, req.method, "terminal.read")) return handleTerminalRead(service, req);
    if (std.mem.eql(u8, req.method, "terminal.write")) return handleTerminalWrite(service, req);
    // terminal.subscribe / terminal.unsubscribe must be handled by the
    // transport (serve_ws.zig) because they need the connection's stream
    // pointer + per-stream write lock for atomic snapshot+register and for
    // pump-driven push delivery.
    if (std.mem.eql(u8, req.method, "terminal.subscribe") or
        std.mem.eql(u8, req.method, "terminal.unsubscribe"))
    {
        return errorResponse(alloc, req.id, "transport_required", "terminal.subscribe/unsubscribe requires WebSocket transport");
    }

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = false,
        .@"error" = .{
            .code = "method_not_found",
            .message = "unknown method",
        },
    });
}

fn handleProxyOpen(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "proxy.open requires params");
    const host = getRequiredStringParam(params, "host", "proxy.open requires host") catch |err| return paramError(service.alloc, req.id, err);
    const port = getRequiredPositiveU16Param(params, "port", "proxy.open requires port in range 1-65535") catch |err| return paramError(service.alloc, req.id, err);

    const stream_id = service.openProxy(host, port) catch |err| {
        return errorResponse(service.alloc, req.id, "open_failed", @errorName(err));
    };

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .stream_id = stream_id },
    });
}

fn handleProxyClose(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "proxy.close requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.close requires stream_id") catch |err| return paramError(service.alloc, req.id, err);

    service.closeProxy(stream_id) catch {
        return errorResponse(service.alloc, req.id, "not_found", "stream not found");
    };
    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .closed = true },
    });
}

fn handleProxyWrite(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "proxy.write requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.write requires stream_id") catch |err| return paramError(service.alloc, req.id, err);
    const encoded = getRequiredStringParam(params, "data_base64", "proxy.write requires data_base64") catch |err| return paramError(service.alloc, req.id, err);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
        return invalidParams(service.alloc, req.id, "data_base64 must be valid base64");
    };
    const decoded = try service.alloc.alloc(u8, decoded_len);
    defer service.alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        return invalidParams(service.alloc, req.id, "data_base64 must be valid base64");
    };

    const written = service.writeProxy(stream_id, decoded) catch |err| switch (err) {
        error.StreamNotFound => return errorResponse(service.alloc, req.id, "not_found", "stream not found"),
        else => return errorResponse(service.alloc, req.id, "stream_error", @errorName(err)),
    };
    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .written = written },
    });
}

fn handleProxyRead(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "proxy.read requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.read requires stream_id") catch |err| return paramError(service.alloc, req.id, err);
    const max_bytes = getOptionalPositiveIntParam(params, "max_bytes") orelse 32_768;
    if (max_bytes > 262_144) return invalidParams(service.alloc, req.id, "max_bytes must be in range 1-262144");
    const timeout_ms = if (getOptionalNonNegativeIntParam(params, "timeout_ms")) |value| @as(i32, @intCast(value)) else 50;

    const read = service.readProxy(stream_id, @intCast(max_bytes), timeout_ms) catch |err| switch (err) {
        error.StreamNotFound => return errorResponse(service.alloc, req.id, "not_found", "stream not found"),
        else => return errorResponse(service.alloc, req.id, "stream_error", @errorName(err)),
    };
    defer service.alloc.free(read.data);

    const encoded_len = std.base64.standard.Encoder.calcSize(read.data.len);
    const encoded = try service.alloc.alloc(u8, encoded_len);
    defer service.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, read.data);

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .data_base64 = encoded,
            .eof = read.eof,
        },
    });
}

fn handleSessionOpen(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req);
    const requested_id = if (params) |object| getOptionalStringParam(object, "session_id") else null;
    var status = try service.openSession(requested_id);
    defer status.deinit(service.alloc);
    return encodeStatusResponse(service.alloc, req.id, status, null, null);
}

fn handleSessionClose(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.close requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.close requires session_id") catch |err| return paramError(service.alloc, req.id, err);

    service.closeSession(session_id) catch |err| return sessionErrorResponse(service.alloc, req.id, err);
    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .closed = true,
        },
    });
}

fn handleSessionAttach(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.attach requires params");
    const parsed = parseAttachmentParams(params, "session.attach") catch |err| return paramError(service.alloc, req.id, err);

    var status = service.attachSession(parsed.session_id, parsed.attachment_id, parsed.cols, parsed.rows) catch |err| return sessionErrorResponse(service.alloc, req.id, err);
    defer status.deinit(service.alloc);
    return encodeStatusResponse(service.alloc, req.id, status, null, null);
}

fn handleSessionResize(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.resize requires params");
    const parsed = parseAttachmentParams(params, "session.resize") catch |err| return paramError(service.alloc, req.id, err);

    var status = service.resizeSession(parsed.session_id, parsed.attachment_id, parsed.cols, parsed.rows) catch |err| return sessionErrorResponse(service.alloc, req.id, err);
    defer status.deinit(service.alloc);
    return encodeStatusResponse(service.alloc, req.id, status, null, null);
}

fn handleSessionDetach(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.detach requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.detach requires session_id") catch |err| return paramError(service.alloc, req.id, err);
    const attachment_id = getRequiredStringParam(params, "attachment_id", "session.detach requires attachment_id") catch |err| return paramError(service.alloc, req.id, err);

    var status = service.detachSession(session_id, attachment_id) catch |err| return sessionErrorResponse(service.alloc, req.id, err);
    defer status.deinit(service.alloc);
    return encodeStatusResponse(service.alloc, req.id, status, null, null);
}

fn handleSessionStatus(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.status requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.status requires session_id") catch |err| return paramError(service.alloc, req.id, err);

    var status = service.sessionStatus(session_id) catch |err| return sessionErrorResponse(service.alloc, req.id, err);
    defer status.deinit(service.alloc);
    return encodeStatusResponse(service.alloc, req.id, status, null, null);
}

fn handleSessionList(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const sessions = try service.listSessions();
    defer {
        for (sessions) |*entry| entry.deinit(service.alloc);
        service.alloc.free(sessions);
    }

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .sessions = sessions },
    });
}

fn handleSessionMarkRead(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.markRead requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.markRead requires session_id") catch |err| return paramError(service.alloc, req.id, err);

    const found = service.markRead(session_id);
    if (!found) return terminalNotFound(service.alloc, req.id);

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .has_unread_output = false,
        },
    });
}

fn handleConfigureNotifications(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "daemon.configure_notifications requires params");

    // endpoint is required (may be empty string to disable).
    const endpoint_value = params.get("endpoint") orelse
        return invalidParams(alloc, req.id, "daemon.configure_notifications requires endpoint");
    if (endpoint_value != .string)
        return invalidParams(alloc, req.id, "endpoint must be a string");
    const endpoint = endpoint_value.string;

    // bearer_token is optional (defaults to empty).
    const bearer_token = if (params.get("bearer_token")) |v| switch (v) {
        .string => |s| s,
        else => return invalidParams(alloc, req.id, "bearer_token must be a string"),
    } else "";

    // device_tokens is required (may be empty array to disable without
    // clearing endpoint/bearer).
    const tokens_value = params.get("device_tokens") orelse
        return invalidParams(alloc, req.id, "daemon.configure_notifications requires device_tokens");
    if (tokens_value != .array)
        return invalidParams(alloc, req.id, "device_tokens must be an array of strings");

    var tokens_list: std.ArrayList([]const u8) = .empty;
    defer tokens_list.deinit(alloc);
    for (tokens_value.array.items) |item| {
        if (item != .string)
            return invalidParams(alloc, req.id, "device_tokens entries must be strings");
        try tokens_list.append(alloc, item.string);
    }

    service.configureNotifications(endpoint, bearer_token, tokens_list.items) catch |err| {
        return internalError(alloc, req.id, err);
    };

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .configured = true,
        },
    });
}

fn handleSessionHistory(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "session.history requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.history requires session_id") catch |err| return paramError(service.alloc, req.id, err);

    const format: serialize.HistoryFormat = blk: {
        const fmt_str = getOptionalStringParam(params, "format") orelse break :blk .plain;
        if (std.mem.eql(u8, fmt_str, "vt")) break :blk .vt;
        if (std.mem.eql(u8, fmt_str, "html")) break :blk .html;
        break :blk .plain;
    };

    const history = service.history(session_id, format) catch |err| switch (err) {
        error.TerminalSessionNotFound => return terminalNotFound(service.alloc, req.id),
        else => return internalError(service.alloc, req.id, err),
    };
    defer service.alloc.free(history.history);

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .history = history.history,
            .next_offset = history.next_offset,
        },
    });
}

fn handleTerminalOpen(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "terminal.open requires params");
    const requested_id = getOptionalStringParam(params, "session_id");
    const command = getRequiredStringParam(params, "command", "terminal.open requires command") catch |err| return paramError(service.alloc, req.id, err);
    const cols = getRequiredPositiveU16Param(params, "cols", "terminal.open requires cols > 0") catch |err| return paramError(service.alloc, req.id, err);
    const rows = getRequiredPositiveU16Param(params, "rows", "terminal.open requires rows > 0") catch |err| return paramError(service.alloc, req.id, err);

    var opened = service.openTerminal(requested_id, command, cols, rows) catch |err| switch (err) {
        error.SessionAlreadyExists => return errorResponse(service.alloc, req.id, "already_exists", "session already exists"),
        else => return internalError(service.alloc, req.id, err),
    };
    defer opened.status.deinit(service.alloc);
    defer service.alloc.free(opened.attachment_id);

    return encodeStatusResponse(service.alloc, req.id, opened.status, opened.attachment_id, opened.offset);
}

fn handleTerminalRead(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "terminal.read requires params");
    const session_id = getRequiredStringParam(params, "session_id", "terminal.read requires session_id") catch |err| return paramError(service.alloc, req.id, err);
    const offset = getRequiredU64Param(params, "offset", "terminal.read requires offset >= 0") catch |err| return paramError(service.alloc, req.id, err);
    const max_bytes = if (getOptionalPositiveIntParam(params, "max_bytes")) |value| @as(usize, @intCast(value)) else 65_536;
    const timeout_ms = if (getOptionalNonNegativeIntParam(params, "timeout_ms")) |value| @as(i32, @intCast(value)) else 0;

    const read = service.readTerminal(session_id, offset, max_bytes, timeout_ms) catch |err| switch (err) {
        error.TerminalSessionNotFound => return terminalNotFound(service.alloc, req.id),
        error.ReadTimeout => return deadlineExceeded(service.alloc, req.id, "terminal read timed out"),
        else => return internalError(service.alloc, req.id, err),
    };
    defer service.alloc.free(read.data);

    const encoded_len = std.base64.standard.Encoder.calcSize(read.data.len);
    const encoded = try service.alloc.alloc(u8, encoded_len);
    defer service.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, read.data);

    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .offset = read.offset,
            .base_offset = read.base_offset,
            .truncated = read.truncated,
            .eof = read.eof,
            .data = encoded,
        },
    });
}

fn handleTerminalWrite(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(service.alloc, req.id, "terminal.write requires params");
    const session_id = getRequiredStringParam(params, "session_id", "terminal.write requires session_id") catch |err| return paramError(service.alloc, req.id, err);
    const encoded = getRequiredStringParam(params, "data", "terminal.write requires data") catch |err| return paramError(service.alloc, req.id, err);
    const write_id = getOptionalStringParam(params, "write_id");

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
        return invalidParams(service.alloc, req.id, "terminal.write data must be base64");
    };
    const decoded = try service.alloc.alloc(u8, decoded_len);
    defer service.alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        return invalidParams(service.alloc, req.id, "terminal.write data must be base64");
    };

    const written = service.writeTerminal(session_id, decoded, write_id) catch |err| switch (err) {
        error.TerminalSessionNotFound => return terminalNotFound(service.alloc, req.id),
        else => return internalError(service.alloc, req.id, err),
    };
    return try json_rpc.encodeResponse(service.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .written = written,
        },
    });
}

fn encodeStatusResponse(
    alloc: std.mem.Allocator,
    id: ?std.json.Value,
    status: session_registry.SessionStatus,
    attachment_id: ?[]const u8,
    offset: ?u64,
) ![]u8 {
    var attachments = std.ArrayList(AttachmentResult).empty;
    defer attachments.deinit(alloc);

    for (status.attachments) |attachment| {
        try attachments.append(alloc, .{
            .attachment_id = attachment.attachment_id,
            .cols = attachment.cols,
            .rows = attachment.rows,
        });
    }

    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = true,
        .result = .{
            .session_id = status.session_id,
            .attachments = attachments.items,
            .effective_cols = status.effective_cols,
            .effective_rows = status.effective_rows,
            .last_known_cols = status.last_known_cols,
            .last_known_rows = status.last_known_rows,
            .grid_generation = status.grid_generation,
            .attachment_id = attachment_id,
            .offset = offset,
        },
    });
}

fn getParamsObject(req: *const json_rpc.Request) ?std.json.ObjectMap {
    const value = req.parsed.value.object.get("params") orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn getOptionalStringParam(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = params.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getRequiredStringParam(params: std.json.ObjectMap, key: []const u8, message: []const u8) ![]const u8 {
    if (getOptionalStringParam(params, key)) |value| return value;
    _ = message;
    return error.InvalidStringParam;
}

fn getOptionalNonNegativeIntParam(params: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = params.get(key) orelse return null;
    return intFromValue(value);
}

fn getOptionalPositiveIntParam(params: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = intFromValue(params.get(key) orelse return null) orelse return null;
    if (value <= 0) return null;
    return value;
}

fn getRequiredPositiveU16Param(params: std.json.ObjectMap, key: []const u8, message: []const u8) !u16 {
    const value = getOptionalPositiveIntParam(params, key) orelse {
        _ = message;
        return error.InvalidPositiveParam;
    };
    if (value > std.math.maxInt(u16)) return error.InvalidPositiveParam;
    return @intCast(value);
}

fn getRequiredU64Param(params: std.json.ObjectMap, key: []const u8, message: []const u8) !u64 {
    const raw = params.get(key) orelse {
        _ = message;
        return error.InvalidUnsignedParam;
    };
    const value = intFromValue(raw) orelse {
        _ = message;
        return error.InvalidUnsignedParam;
    };
    if (value < 0) return error.InvalidUnsignedParam;
    return @intCast(value);
}

fn intFromValue(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (@floor(float) == float) @as(i64, @intFromFloat(float)) else null,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch null,
        else => null,
    };
}

const ParsedAttachmentParams = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

fn parseAttachmentParams(params: std.json.ObjectMap, method: []const u8) !ParsedAttachmentParams {
    const session_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires session_id", .{method});
    defer std.heap.page_allocator.free(session_message);
    const attachment_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires attachment_id", .{method});
    defer std.heap.page_allocator.free(attachment_message);
    const cols_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires cols > 0", .{method});
    defer std.heap.page_allocator.free(cols_message);
    const rows_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires rows > 0", .{method});
    defer std.heap.page_allocator.free(rows_message);

    return .{
        .session_id = try getRequiredStringParam(params, "session_id", session_message),
        .attachment_id = try getRequiredStringParam(params, "attachment_id", attachment_message),
        .cols = try getRequiredPositiveU16Param(params, "cols", cols_message),
        .rows = try getRequiredPositiveU16Param(params, "rows", rows_message),
    };
}

fn paramError(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return switch (err) {
        error.InvalidStringParam => invalidParams(alloc, id, "missing required string parameter"),
        error.InvalidPositiveParam => invalidParams(alloc, id, "missing required positive integer parameter"),
        error.InvalidUnsignedParam => invalidParams(alloc, id, "missing required unsigned integer parameter"),
        else => internalError(alloc, id, err),
    };
}

fn sessionErrorResponse(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return switch (err) {
        error.SessionNotFound => errorResponse(alloc, id, "not_found", "session not found"),
        error.AttachmentNotFound => errorResponse(alloc, id, "not_found", "attachment not found"),
        error.SessionAlreadyExists => errorResponse(alloc, id, "already_exists", "session already exists"),
        else => errorResponse(alloc, id, "invalid_params", "cols and rows must be greater than zero"),
    };
}

fn terminalNotFound(alloc: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    return errorResponse(alloc, id, "not_found", "terminal session not found");
}

fn deadlineExceeded(alloc: std.mem.Allocator, id: ?std.json.Value, message: []const u8) ![]u8 {
    return errorResponse(alloc, id, "deadline_exceeded", message);
}

fn invalidParams(alloc: std.mem.Allocator, id: ?std.json.Value, message: []const u8) ![]u8 {
    return errorResponse(alloc, id, "invalid_params", message);
}

fn internalError(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return errorResponse(alloc, id, "internal_error", @errorName(err));
}

fn handleWorkspaceList(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const reg = &service.workspace_reg;

    const PaneEntry = struct {
        id: []const u8,
        session_id: ?[]const u8,
        title: []const u8,
        directory: []const u8,
        has_unread_output: bool,
    };

    const WorkspaceEntry = struct {
        id: []const u8,
        title: []const u8,
        directory: []const u8,
        preview: []const u8,
        phase: []const u8,
        color: ?[]const u8,
        unread_count: u32,
        has_unread: bool,
        pinned: bool,
        session_id: ?[]const u8,
        focused_pane_id: ?[]const u8,
        pane_count: usize,
        panes: []const PaneEntry,
        created_at: i64,
        last_activity_at: i64,
    };

    var entries: std.ArrayList(WorkspaceEntry) = .empty;
    defer entries.deinit(alloc);
    var all_pane_entries: std.ArrayList([]const PaneEntry) = .empty;
    defer {
        for (all_pane_entries.items) |pe| alloc.free(pe);
        all_pane_entries.deinit(alloc);
    }

    // Pump all runtime sessions first so OSC-extracted title/directory
    // reflects the latest PTY output, even if no client is reading.
    // Snapshot values under the map's read lock so we iterate without
    // holding it (pumping is allowed to block on per-runtime locks).
    {
        const runtimes_snapshot = try service.runtimes.valuesSnapshot(alloc);
        defer alloc.free(runtimes_snapshot);
        for (runtimes_snapshot) |rt| {
            rt.pty.pump(&rt.terminal) catch {};
        }
    }

    for (reg.order.items) |ws_id| {
        const ws = reg.workspaces.get(ws_id) orelse continue;
        const leaves = try ws.root_pane.collectLeaves(alloc);
        defer alloc.free(leaves);

        var pane_entries: std.ArrayList(PaneEntry) = .empty;
        var ws_has_unread = false;
        for (leaves) |leaf| {
            // Use OSC-extracted title/directory from the daemon's terminal
            // session as fallback when the macOS sync hasn't provided them.
            var title = leaf.title;
            var directory = leaf.directory;
            var pane_unread = false;
            if (leaf.session_id) |sid| {
                if (service.runtimes.get(sid)) |runtime| {
                    if (title.len == 0 or std.mem.eql(u8, title, "Terminal")) {
                        if (runtime.terminal.last_title) |t| {
                            title = t;
                        }
                    }
                    if (directory.len == 0) {
                        if (runtime.terminal.last_directory) |d| {
                            directory = d;
                        }
                    }
                    pane_unread = runtime.has_unread_output.load(.seq_cst);
                    if (pane_unread) ws_has_unread = true;
                }
            }
            try pane_entries.append(alloc, .{
                .id = leaf.id,
                .session_id = leaf.session_id,
                .title = title,
                .directory = directory,
                .has_unread_output = pane_unread,
            });
        }
        const panes_slice = try pane_entries.toOwnedSlice(alloc);
        try all_pane_entries.append(alloc, panes_slice);

        try entries.append(alloc, .{
            .id = ws.id,
            .title = ws.title,
            .directory = ws.directory,
            .preview = ws.preview,
            .phase = ws.phase,
            .color = ws.color,
            .unread_count = ws.unread_count,
            .has_unread = ws_has_unread,
            .pinned = ws.pinned,
            .session_id = ws.session_id,
            .focused_pane_id = ws.focused_pane_id,
            .pane_count = leaves.len,
            .panes = panes_slice,
            .created_at = ws.created_at,
            .last_activity_at = ws.last_activity_at,
        });
    }

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .workspaces = entries.items,
            .selected_workspace_id = reg.selected_id,
            .change_seq = reg.change_seq,
        },
    });
}

fn handleWorkspaceCreate(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req);
    const title = if (params) |p| getOptionalStringParam(p, "title") else null;
    const directory = if (params) |p| getOptionalStringParam(p, "directory") else null;
    const explicit_id = if (params) |p| getOptionalStringParam(p, "id") else null;

    const id = service.workspace_reg.createWithId(explicit_id, title, directory) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };

    // Record in history log. Keep payload schema minimal so changes to
    // title/color/pinned can be added via dedicated history events later.
    service.appendHistory(id, "created", "{}");

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .workspace_id = id,
            .change_seq = service.workspace_reg.change_seq,
        },
    });
}

/// Mint a new daemon-side terminal session and bind it to a pane in the
/// given workspace. This is the canonical "I want a new shell in this
/// workspace" RPC — clients never invent session IDs themselves; they
/// call this and use whatever session_id the daemon returns. Both mac
/// and iOS go through this path so a workspace's panes always have
/// daemon-minted IDs that both can discover via `workspace.list`.
///
/// Params:
///   workspace_id    (required)
///   command         (required) — shell to exec
///   cols, rows      (required, > 0)
///   parent_pane_id  (optional) — when present, splitPane creates a new
///                                 sibling next to this pane and the
///                                 session is bound to the new sibling.
///                                 When absent, the session is bound to
///                                 the workspace's first leaf pane —
///                                 typically the empty root created by
///                                 workspace.create.
///   direction       (optional)  — "horizontal"|"vertical"; only meaningful
///                                 with parent_pane_id.
///
/// Returns: { workspace_id, pane_id, session_id, attachment_id, offset,
///            change_seq }.
fn handleWorkspaceOpenPane(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.open_pane requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.open_pane requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const command = getRequiredStringParam(params, "command", "workspace.open_pane requires command") catch |err|
        return paramError(alloc, req.id, err);
    const cols = getRequiredPositiveU16Param(params, "cols", "workspace.open_pane requires cols > 0") catch |err|
        return paramError(alloc, req.id, err);
    const rows = getRequiredPositiveU16Param(params, "rows", "workspace.open_pane requires rows > 0") catch |err|
        return paramError(alloc, req.id, err);
    const parent_pane_id = getOptionalStringParam(params, "parent_pane_id");
    const dir_str = getOptionalStringParam(params, "direction") orelse "horizontal";
    const direction: workspace_registry.SplitDirection = if (std.mem.eql(u8, dir_str, "vertical"))
        .vertical
    else
        .horizontal;

    // Resolve the target pane id: either splitPane creates a fresh
    // sibling, or we reuse the workspace's first existing leaf.
    var copied_pane_id: ?[]const u8 = null;
    defer if (copied_pane_id) |pid| alloc.free(pid);
    const target_pane_id: []const u8 = blk: {
        if (parent_pane_id) |pid| {
            const new_pid = service.workspace_reg.splitPane(workspace_id, pid, direction, .terminal) catch |err| {
                return try errorResponse(alloc, req.id, "not_found", @errorName(err));
            };
            break :blk new_pid;
        }
        const ws = service.workspace_reg.workspaces.getPtr(workspace_id) orelse
            return errorResponse(alloc, req.id, "not_found", "workspace not found");
        const leaves = ws.root_pane.collectLeaves(alloc) catch |err| {
            return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
        };
        defer alloc.free(leaves);
        if (leaves.len == 0) {
            return try errorResponse(alloc, req.id, "internal_error", "workspace has no panes");
        }
        // Take ownership of a copy so the slice survives `defer alloc.free(leaves)`.
        copied_pane_id = try alloc.dupe(u8, leaves[0].id);
        break :blk copied_pane_id.?;
    };

    // Mint the session. `workspace.open_pane` does NOT create a bootstrap
    // attachment: the PTY is sized via `last_known_cols/rows` seeded from
    // the requested cols/rows, but no entry lands in `SessionState.attachments`.
    // This prevents the "phantom attachment caps effective_cols forever"
    // bug where `min(openPane_size, client_attach_size)` pinned the PTY
    // to the open_pane dimensions. The first real client (mac's bridge or
    // iOS) attaches via `session.attach` and becomes the sole attachment.
    var opened = service.openTerminalWithOptions(null, command, cols, rows, .{
        .create_bootstrap_attachment = false,
    }) catch |err| switch (err) {
        else => return internalError(service.alloc, req.id, err),
    };
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    const session_id = opened.status.session_id;

    // Bind into the workspace tree.
    service.workspace_reg.bindSession(workspace_id, target_pane_id, session_id) catch |err| {
        // Bind failed — try to clean up the orphaned session so we
        // don't leak. Best-effort; closeSession swallows missing IDs.
        service.closeSession(session_id) catch {};
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .workspace_id = workspace_id,
            .pane_id = target_pane_id,
            .session_id = session_id,
            .attachment_id = opened.attachment_id,
            .offset = opened.offset,
            .change_seq = service.workspace_reg.change_seq,
            .effective_cols = opened.status.effective_cols,
            .effective_rows = opened.status.effective_rows,
        },
    });
}

fn handleWorkspaceRename(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.rename requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.rename requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const title = getRequiredStringParam(params, "title", "workspace.rename requires title") catch |err|
        return paramError(alloc, req.id, err);

    service.workspace_reg.rename(workspace_id, title) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    service.appendHistory(workspace_id, "renamed", "{}");

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspacePin(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.pin requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.pin requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pinned: bool = if (params.get("pinned")) |v| switch (v) {
        .bool => |b| b,
        else => true,
    } else true;

    service.workspace_reg.setPin(workspace_id, pinned) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSetColor(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.set_color requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.set_color requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const color: []const u8 = if (params.get("color")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => "",
    } else "";

    service.workspace_reg.setColor(workspace_id, color) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceClose(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.close requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.close requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);

    service.workspace_reg.close(workspace_id) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    service.appendHistory(workspace_id, "closed", "{}");

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSelect(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.select requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.select requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);

    service.workspace_reg.select(workspace_id) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handlePaneSplit(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "pane.split requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "pane.split requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pane_id = getRequiredStringParam(params, "pane_id", "pane.split requires pane_id") catch |err|
        return paramError(alloc, req.id, err);
    const dir_str = getOptionalStringParam(params, "direction") orelse "horizontal";
    const direction: workspace_registry.SplitDirection = if (std.mem.eql(u8, dir_str, "vertical")) .vertical else .horizontal;
    const type_str = getOptionalStringParam(params, "type") orelse "terminal";
    const pane_type: workspace_registry.PaneType = if (std.mem.eql(u8, type_str, "browser")) .browser else .terminal;

    const new_pane_id = service.workspace_reg.splitPane(workspace_id, pane_id, direction, pane_type) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    service.appendHistory(workspace_id, "pane_split", "{}");

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .pane_id = new_pane_id,
            .change_seq = service.workspace_reg.change_seq,
        },
    });
}

fn handlePaneClose(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "pane.close requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "pane.close requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pane_id = getRequiredStringParam(params, "pane_id", "pane.close requires pane_id") catch |err|
        return paramError(alloc, req.id, err);

    service.workspace_reg.closePane(workspace_id, pane_id) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handlePaneFocus(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "pane.focus requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "pane.focus requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pane_id = getRequiredStringParam(params, "pane_id", "pane.focus requires pane_id") catch |err|
        return paramError(alloc, req.id, err);

    service.workspace_reg.focusPane(workspace_id, pane_id) catch |err| {
        return try errorResponse(alloc, req.id, "not_found", @errorName(err));
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSetUnread(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.set_unread requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.set_unread requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const unread_count: u32 = if (params.get("unread_count")) |v| switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    } else 0;

    const ws = service.workspace_reg.get(workspace_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "workspace not found");
    ws.unread_count = unread_count;
    service.workspace_reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSetPreview(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.set_preview requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.set_preview requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const preview = getOptionalStringParam(params, "preview") orelse "";

    const ws = service.workspace_reg.get(workspace_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "workspace not found");
    const new_preview = alloc.dupe(u8, preview) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    alloc.free(ws.preview);
    ws.preview = new_preview;
    service.workspace_reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSetPhase(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.set_phase requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.set_phase requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const phase = getOptionalStringParam(params, "phase") orelse "idle";

    const ws = service.workspace_reg.get(workspace_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "workspace not found");
    const new_phase = alloc.dupe(u8, phase) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    alloc.free(ws.phase);
    ws.phase = new_phase;
    service.workspace_reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSetDirectory(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.set_directory requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "workspace.set_directory requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const directory = getRequiredStringParam(params, "directory", "workspace.set_directory requires directory") catch |err|
        return paramError(alloc, req.id, err);

    const ws = service.workspace_reg.get(workspace_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "workspace not found");
    const new_dir = alloc.dupe(u8, directory) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    alloc.free(ws.directory);
    ws.directory = new_dir;
    ws.last_activity_at = std.time.milliTimestamp();
    service.workspace_reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceReorder(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.reorder requires params");
    const ordered_value = params.get("ordered_ids") orelse
        return invalidParams(alloc, req.id, "workspace.reorder requires ordered_ids array");
    if (ordered_value != .array) return invalidParams(alloc, req.id, "ordered_ids must be an array");

    var new_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (new_ids.items) |id| alloc.free(id);
        new_ids.deinit(alloc);
    }
    for (ordered_value.array.items) |item| {
        if (item != .string) continue;
        try new_ids.append(alloc, try alloc.dupe(u8, item.string));
    }

    // Validate every id exists before mutating so a partial reorder doesn't
    // leave the registry in an inconsistent state.
    for (new_ids.items) |id| {
        if (!service.workspace_reg.workspaces.contains(id)) {
            return try errorResponse(alloc, req.id, "not_found", "unknown workspace id");
        }
    }

    // Replace the order list. Take ownership of the new ids.
    const reg = &service.workspace_reg;
    for (reg.order.items) |old| reg.alloc.free(old);
    reg.order.clearRetainingCapacity();
    for (new_ids.items) |id| {
        try reg.order.append(reg.alloc, try reg.alloc.dupe(u8, id));
    }
    reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = reg.change_seq },
    });
}

fn handlePaneSetTitle(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "pane.set_title requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "pane.set_title requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pane_id = getRequiredStringParam(params, "pane_id", "pane.set_title requires pane_id") catch |err|
        return paramError(alloc, req.id, err);
    const title = getRequiredStringParam(params, "title", "pane.set_title requires title") catch |err|
        return paramError(alloc, req.id, err);

    const ws = service.workspace_reg.get(workspace_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "workspace not found");
    const leaf = ws.root_pane.findLeaf(pane_id) orelse
        return try errorResponse(alloc, req.id, "not_found", "pane not found");
    const new_title = alloc.dupe(u8, title) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    if (leaf.title.len > 0) alloc.free(leaf.title);
    leaf.title = new_title;
    ws.last_activity_at = std.time.milliTimestamp();
    service.workspace_reg.change_seq += 1;

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handlePaneResize(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "pane.resize requires params");
    const workspace_id = getRequiredStringParam(params, "workspace_id", "pane.resize requires workspace_id") catch |err|
        return paramError(alloc, req.id, err);
    const pane_id = getRequiredStringParam(params, "pane_id", "pane.resize requires pane_id") catch |err|
        return paramError(alloc, req.id, err);
    const ratio: f32 = if (params.get("ratio")) |v| switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.5,
    } else 0.5;

    service.workspace_reg.resizePane(workspace_id, pane_id, ratio) catch |err| switch (err) {
        error.WorkspaceNotFound => return try errorResponse(alloc, req.id, "not_found", "workspace not found"),
        else => return try errorResponse(alloc, req.id, "not_found", "pane has no parent split"),
    };

    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSync(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req) orelse
        return invalidParams(alloc, req.id, "workspace.sync requires params");

    const selected_id = getOptionalStringParam(params, "selected_workspace_id");
    const prune_sessionless_missing: bool = if (params.get("prune_sessionless_missing")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    // Parse workspaces array from the JSON Value
    const ws_value = params.get("workspaces") orelse
        return invalidParams(alloc, req.id, "workspace.sync requires workspaces array");

    if (ws_value != .array) return invalidParams(alloc, req.id, "workspaces must be an array");
    const ws_array = ws_value.array.items;

    var sync_workspaces: std.ArrayList(workspace_registry.Registry.SyncWorkspace) = .empty;
    defer sync_workspaces.deinit(alloc);

    for (ws_array) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = if (obj.get("id")) |v| (if (v == .string) v.string else null) else null;
        const title = if (obj.get("title")) |v| (if (v == .string) v.string else null) else null;
        if (id == null or title == null) continue;

        const unread_count: u32 = if (obj.get("unread_count")) |v| switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else 0,
            else => 0,
        } else 0;

        const pinned: bool = if (obj.get("pinned")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false;

        // Parse session_ids array (multi-pane workspaces).
        var session_ids_list: std.ArrayList([]const u8) = .empty;
        if (obj.get("session_ids")) |sids_val| {
            if (sids_val == .array) {
                for (sids_val.array.items) |sid_item| {
                    if (sid_item == .string) {
                        try session_ids_list.append(alloc, sid_item.string);
                    }
                }
            }
        }
        const session_ids = try session_ids_list.toOwnedSlice(alloc);

        // Parse per-pane metadata (richer than bare session_ids).
        var panes_list: std.ArrayList(workspace_registry.Registry.SyncPane) = .empty;
        if (obj.get("panes")) |panes_val| {
            if (panes_val == .array) {
                for (panes_val.array.items) |pane_item| {
                    if (pane_item != .object) continue;
                    const pane_obj = pane_item.object;
                    const pane_sid = if (pane_obj.get("session_id")) |v| (if (v == .string) v.string else null) else null;
                    if (pane_sid) |sid| {
                        try panes_list.append(alloc, .{
                            .session_id = sid,
                            .title = if (pane_obj.get("title")) |v| (if (v == .string) v.string else "") else "",
                            .directory = if (pane_obj.get("directory")) |v| (if (v == .string) v.string else "") else "",
                        });
                    }
                }
            }
        }
        const sync_panes = try panes_list.toOwnedSlice(alloc);

        try sync_workspaces.append(alloc, .{
            .id = id.?,
            .title = title.?,
            .directory = if (obj.get("directory")) |v| (if (v == .string) v.string else "") else "",
            .preview = if (obj.get("preview")) |v| (if (v == .string) v.string else "") else "",
            .phase = if (obj.get("phase")) |v| (if (v == .string) v.string else "idle") else "idle",
            .color = if (obj.get("color")) |v| (if (v == .string) v.string else "") else "",
            .unread_count = unread_count,
            .pinned = pinned,
            .session_id = if (obj.get("session_id")) |v| (if (v == .string) v.string else null) else null,
            .session_ids = session_ids,
            .panes = sync_panes,
        });
    }

    service.workspace_reg.syncAll(sync_workspaces.items, selected_id, prune_sessionless_missing) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };

    // Broadcast the new state so subscribed clients (iOS, other desktops)
    // pick up title / pinned / pane updates without waiting for a poll.
    if (service.on_workspace_changed) |cb| cb(service);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .change_seq = service.workspace_reg.change_seq },
    });
}

fn handleWorkspaceSubscribe(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    // Note: actual subscription registration happens in serve_ws.zig's handleClient.
    // This handler just returns the current state as the initial snapshot.
    return handleWorkspaceList(service, req);
}

fn handleWorkspaceHistoryQuery(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    const params = getParamsObject(req);
    const workspace_id = if (params) |p| getOptionalStringParam(p, "workspace_id") else null;
    var limit: i64 = 100;
    var before_seq: ?i64 = null;
    if (params) |p| {
        if (p.get("limit")) |v| {
            switch (v) {
                .integer => |i| {
                    if (i < 0) limit = 100 else if (i > 1000) limit = 1000 else limit = i;
                },
                else => {},
            }
        }
        if (p.get("before_seq")) |v| {
            switch (v) {
                .integer => |i| before_seq = i,
                else => {},
            }
        }
    }

    if (service.db == null) {
        return try errorResponse(alloc, req.id, "not_available", "persistence not enabled");
    }

    const limit_u32: u32 = @intCast(@max(@as(i64, 0), @min(limit, 1000)));
    var result = service.historyQuery(workspace_id, limit_u32, before_seq) catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    defer result.deinit();

    const RowOut = struct {
        seq: i64,
        workspace_id: []const u8,
        event_type: []const u8,
        payload_json: []const u8,
        at: i64,
    };
    var rows: std.ArrayList(RowOut) = .empty;
    defer rows.deinit(alloc);
    for (result.rows) |row| {
        try rows.append(alloc, .{
            .seq = row.seq,
            .workspace_id = row.workspace_id,
            .event_type = row.event_type,
            .payload_json = row.payload_json,
            .at = row.at,
        });
    }

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .history = rows.items },
    });
}

fn handleWorkspaceHistoryClear(service: *session_service.Service, req: *const json_rpc.Request) ![]u8 {
    const alloc = service.alloc;
    if (service.db == null) {
        return try errorResponse(alloc, req.id, "not_available", "persistence not enabled");
    }
    service.historyClear() catch |err| {
        return try errorResponse(alloc, req.id, "internal_error", @errorName(err));
    };
    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .cleared = true },
    });
}

/// Notify all workspace subscribers that state has changed.
/// Called after any workspace/pane mutation.
/// Includes the full workspace list so clients don't need a round-trip re-fetch.
/// Encode the current workspace state as a workspace.changed push event.
/// Caller owns the returned buffer (must free via the same allocator).
/// Returns null on failure (caller can ignore).
pub fn encodeWorkspaceChangedEvent(service: *session_service.Service, alloc: std.mem.Allocator) ?[]u8 {
    const reg = &service.workspace_reg;
    const PaneEntry = struct {
        id: []const u8,
        session_id: ?[]const u8,
        title: []const u8,
        directory: []const u8,
        has_unread_output: bool,
    };
    const WorkspaceEntry = struct {
        id: []const u8,
        title: []const u8,
        directory: []const u8,
        preview: []const u8,
        phase: []const u8,
        color: ?[]const u8,
        unread_count: u32,
        has_unread: bool,
        pinned: bool,
        session_id: ?[]const u8,
        focused_pane_id: ?[]const u8,
        pane_count: usize,
        panes: []const PaneEntry,
        created_at: i64,
        last_activity_at: i64,
    };

    var entries: std.ArrayList(WorkspaceEntry) = .empty;
    defer entries.deinit(alloc);
    var all_pane_entries: std.ArrayList([]const PaneEntry) = .empty;
    defer {
        for (all_pane_entries.items) |pe| alloc.free(pe);
        all_pane_entries.deinit(alloc);
    }

    for (reg.order.items) |ws_id| {
        const ws = reg.workspaces.get(ws_id) orelse continue;
        const leaves = ws.root_pane.collectLeaves(alloc) catch continue;
        defer alloc.free(leaves);

        var pane_entries: std.ArrayList(PaneEntry) = .empty;
        var ws_has_unread = false;
        for (leaves) |leaf| {
            var title = leaf.title;
            var directory = leaf.directory;
            var pane_unread = false;
            if (leaf.session_id) |sid| {
                if (service.runtimes.get(sid)) |runtime| {
                    if (title.len == 0 or std.mem.eql(u8, title, "Terminal")) {
                        if (runtime.terminal.last_title) |t| title = t;
                    }
                    if (directory.len == 0) {
                        if (runtime.terminal.last_directory) |d| directory = d;
                    }
                    pane_unread = runtime.has_unread_output.load(.seq_cst);
                    if (pane_unread) ws_has_unread = true;
                }
            }
            pane_entries.append(alloc, .{
                .id = leaf.id,
                .session_id = leaf.session_id,
                .title = title,
                .directory = directory,
                .has_unread_output = pane_unread,
            }) catch continue;
        }
        const panes_slice = pane_entries.toOwnedSlice(alloc) catch continue;
        all_pane_entries.append(alloc, panes_slice) catch {
            alloc.free(panes_slice);
            continue;
        };

        entries.append(alloc, .{
            .id = ws.id,
            .title = ws.title,
            .directory = ws.directory,
            .preview = ws.preview,
            .phase = ws.phase,
            .color = ws.color,
            .unread_count = ws.unread_count,
            .has_unread = ws_has_unread,
            .pinned = ws.pinned,
            .session_id = ws.session_id,
            .focused_pane_id = ws.focused_pane_id,
            .pane_count = leaves.len,
            .panes = panes_slice,
            .created_at = ws.created_at,
            .last_activity_at = ws.last_activity_at,
        }) catch continue;
    }

    return json_rpc.encodeResponse(alloc, .{
        .event = "workspace.changed",
        .change_seq = reg.change_seq,
        .result = .{
            .workspaces = entries.items,
            .selected_workspace_id = reg.selected_id,
        },
    }) catch null;
}

pub fn notifyWorkspaceSubscribers(service: *session_service.Service) void {
    const alloc = service.alloc;
    // Persist first for normal workspace mutations so a crash between mutation
    // and broadcast still lands the state on disk. Pump-origin unread updates
    // cannot block on the writer queue: closeSession may be waiting for the
    // pump to quiesce, so a synchronous writer round trip deadlocks.
    if (service.isOnPumpNotifyThread()) {
        service.persistWorkspacesAsync();
    } else {
        service.persistWorkspaces();
    }
    const event = encodeWorkspaceChangedEvent(service, alloc) orelse return;
    defer alloc.free(event);
    service.subscriptions.notifyAllAlloc(alloc, event);
}

fn errorResponse(alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
}

fn writeResponse(output: anytype, alloc: std.mem.Allocator, payload: []u8) !void {
    defer alloc.free(payload);
    try output.print("{s}\n", .{payload});
    try output.flush();
}
