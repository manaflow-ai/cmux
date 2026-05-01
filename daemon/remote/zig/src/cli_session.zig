const std = @import("std");
const cli_attach = @import("cli_attach.zig");
const json_rpc = @import("json_rpc.zig");
const rpc_client = @import("rpc_client.zig");

const Command = enum {
    attach,
    list,
    status,
    history,
    kill,
    new,
};

const ParsedArgs = struct {
    command: Command,
    socket_path: ?[]const u8 = null,
    session_name: ?[]const u8 = null,
    detached: bool = false,
    quiet: bool = false,
    command_text: ?[]u8 = null,

    pub fn deinit(self: *ParsedArgs, alloc: std.mem.Allocator) void {
        if (self.command_text) |command_text| alloc.free(command_text);
    }
};

pub fn run(args: []const []const u8, stderr: anytype, stdout: anytype) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = parseArgs(alloc, args) catch {
        try usage(stderr);
        return 2;
    };
    defer parsed.deinit(alloc);

    const socket_path = parsed.socket_path orelse defaultSocketPath(alloc) orelse {
        try usage(stderr);
        return 2;
    };

    var client = rpc_client.Client.init(alloc, socket_path);
    defer client.deinit();
    switch (parsed.command) {
        .attach => return cli_attach.run(alloc, socket_path, parsed.session_name.?, stderr),
        .list => return runList(&client, stdout, stderr),
        .status => return runStatus(&client, stdout, stderr, parsed.session_name.?),
        .history => return runHistory(&client, stdout, stderr, parsed.session_name.?),
        .kill => return runKill(&client, stdout, stderr, parsed.session_name.?),
        .new => return runNew(&client, stdout, stderr, parsed.session_name.?, parsed.command_text, parsed.detached, parsed.quiet),
    }
}

fn defaultSocketPath(alloc: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(alloc, "CMUXD_UNIX_PATH") catch null;
}

pub fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.InvalidArgs;

    var parsed = ParsedArgs{
        .command = switchCommand(args[0]) orelse return error.InvalidArgs,
    };

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--socket")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidArgs;
            parsed.socket_path = args[idx];
            continue;
        }
        if (std.mem.eql(u8, arg, "--detached")) {
            parsed.detached = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            parsed.quiet = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            idx += 1;
            break;
        }
        if (parsed.session_name == null) {
            parsed.session_name = arg;
            continue;
        }
        break;
    }

    if (parsed.command == .list and parsed.session_name != null) return error.InvalidArgs;
    if (parsed.command != .list and parsed.session_name == null) return error.InvalidArgs;

    if (parsed.command == .new and idx < args.len) {
        parsed.command_text = try std.mem.join(alloc, " ", args[idx..]);
    }

    return parsed;
}

fn switchCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "attach")) return .attach;
    if (std.mem.eql(u8, raw, "ls")) return .list;
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "history")) return .history;
    if (std.mem.eql(u8, raw, "kill")) return .kill;
    if (std.mem.eql(u8, raw, "new")) return .new;
    return null;
}

fn runList(client: *rpc_client.Client, stdout: anytype, stderr: anytype) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.list",
        .params = .{},
    }, stderr);
    defer response.deinit();

    const sessions = response.value.object.get("result").?.object.get("sessions").?.array;
    if (sessions.items.len == 0) {
        try stdout.print("No sessions\n", .{});
        try stdout.flush();
        return 0;
    }

    for (sessions.items) |item| {
        const session_id = item.object.get("session_id").?.string;
        var status = try sessionStatus(client, session_id, stderr);
        defer status.deinit();

        const result = status.value.object.get("result").?.object;
        const effective_cols = try i64FromValue(result.get("effective_cols").?);
        const effective_rows = try i64FromValue(result.get("effective_rows").?);
        const attachments = result.get("attachments").?.array;

        if (attachments.items.len == 0) {
            try stdout.print("session {s} {d}x{d} [detached]\n", .{
                session_id,
                effective_cols,
                effective_rows,
            });
            continue;
        }

        try stdout.print("session {s} {d}x{d} attachments={d}\n", .{
            session_id,
            effective_cols,
            effective_rows,
            attachments.items.len,
        });
        for (attachments.items, 0..) |attachment, index| {
            const branch = if (index + 1 == attachments.items.len) "└──" else "├──";
            try stdout.print("{s} {s} {d}x{d}\n", .{
                branch,
                attachment.object.get("attachment_id").?.string,
                try i64FromValue(attachment.object.get("cols").?),
                try i64FromValue(attachment.object.get("rows").?),
            });
        }
    }
    try stdout.flush();
    return 0;
}

fn runStatus(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try sessionStatus(client, session_name, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try stdout.print("{s} {d}x{d}\n", .{
        result.get("session_id").?.string,
        try i64FromValue(result.get("effective_cols").?),
        try i64FromValue(result.get("effective_rows").?),
    });
    try stdout.flush();
    return 0;
}

fn sessionStatus(client: *rpc_client.Client, session_name: []const u8, stderr: anytype) !std.json.Parsed(std.json.Value) {
    return call(client, .{
        .id = "1",
        .method = "session.status",
        .params = .{ .session_id = session_name },
    }, stderr);
}

fn runHistory(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.history",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const history = response.value.object.get("result").?.object.get("history").?.string;
    try stdout.print("{s}", .{history});
    try stdout.flush();
    return 0;
}

fn runKill(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.close",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try stdout.print("{s}\n", .{result.get("session_id").?.string});
    try stdout.flush();
    return 0;
}

fn runNew(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8, command_text: ?[]const u8, detached: bool, quiet: bool) !u8 {
    const command = command_text orelse "exec ${SHELL:-/bin/sh} -l";
    const size = cli_attach.currentAttachSize(.{ .cols = 80, .rows = 24 });
    var response = try call(client, .{
        .id = "1",
        .method = "terminal.open",
        .params = .{
            .session_id = session_name,
            .command = command,
            .cols = size.cols,
            .rows = size.rows,
        },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    const created_session = result.get("session_id").?.string;
    const bootstrap_attachment_id = result.get("attachment_id").?.string;
    if (!quiet) {
        try stdout.print("{s}\n", .{created_session});
        try stdout.flush();
    }
    try detachSession(client, created_session, bootstrap_attachment_id, stderr);
    if (detached) return 0;
    return cli_attach.run(client.alloc, client.socket_path, created_session, stderr);
}

fn detachSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.detach",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
        },
    }, stderr);
    response.deinit();
}

fn call(client: *rpc_client.Client, request: anytype, stderr: anytype) !std.json.Parsed(std.json.Value) {
    const request_json = try json_rpc.encodeResponse(client.alloc, request);
    defer client.alloc.free(request_json);

    var response = try client.call(request_json);
    const root = response.value;
    if (root != .object) return error.InvalidResponse;
    if ((root.object.get("ok") orelse return error.InvalidResponse) != .bool) return error.InvalidResponse;
    if (root.object.get("ok").?.bool) return response;

    const err_obj = root.object.get("error") orelse return error.InvalidResponse;
    if (err_obj != .object) return error.InvalidResponse;
    const message = err_obj.object.get("message") orelse return error.InvalidResponse;
    if (message != .string) return error.InvalidResponse;

    try stderr.print("{s}\n", .{message.string});
    try stderr.flush();
    response.deinit();
    return error.RemoteError;
}

fn usage(stderr: anytype) !void {
    try stderr.print("Usage:\n", .{});
    try stderr.print("  cmuxd-remote session ls|list [--socket <path>]\n", .{});
    try stderr.print("  cmuxd-remote session attach|status|history|kill <name> [--socket <path>]\n", .{});
    try stderr.print("  cmuxd-remote session new <name> [--socket <path>] [--detached] [--quiet] [-- <command>]\n", .{});
    try stderr.print("Defaults:\n", .{});
    try stderr.print("  --socket defaults to $CMUXD_UNIX_PATH when set.\n", .{});
    try stderr.flush();
}

fn i64FromValue(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (@floor(float) == float) @as(i64, @intFromFloat(float)) else error.InvalidResponse,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

test "parse session ls" {
    var parsed = try parseArgs(std.testing.allocator, &.{ "ls", "--socket", "/tmp/cmuxd.sock" });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(Command.list, parsed.command);
    try std.testing.expectEqualStrings("/tmp/cmuxd.sock", parsed.socket_path.?);
}

test "parse session list" {
    var parsed = try parseArgs(std.testing.allocator, &.{ "list", "--socket", "/tmp/cmuxd.sock" });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(Command.list, parsed.command);
    try std.testing.expectEqualStrings("/tmp/cmuxd.sock", parsed.socket_path.?);
}

test "parse session new quiet detached" {
    var parsed = try parseArgs(std.testing.allocator, &.{ "new", "dev", "--socket", "/tmp/cmuxd.sock", "--quiet", "--detached", "--", "cat" });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(Command.new, parsed.command);
    try std.testing.expectEqualStrings("dev", parsed.session_name.?);
    try std.testing.expectEqualStrings("/tmp/cmuxd.sock", parsed.socket_path.?);
    try std.testing.expect(parsed.quiet);
    try std.testing.expect(parsed.detached);
    try std.testing.expectEqualStrings("cat", parsed.command_text.?);
}
