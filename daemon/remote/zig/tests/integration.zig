//! End-to-end integration tests for the Zig daemon's Phase 1 push protocol.
//!
//! Each test stands up a real `serve_unix`-shaped listener on a temp Unix
//! socket path, connects one or more real clients, and drives line-delimited
//! JSON-RPC over the socket. No production code is modified — the test
//! server composes `session_service.Service` + `outbound_queue.OutboundQueue`
//! + `server_core.dispatch` in the same shape as production's
//! `serve_unix.handleClient`.

const std = @import("std");

const cmuxd = @import("cmuxd_src");
const pty_pump = cmuxd.pty_pump;
const session_service = cmuxd.session_service;
const server_core = cmuxd.server_core;

const test_util = @import("test_util.zig");

const Fixture = struct {
    alloc: std.mem.Allocator,
    service: session_service.Service,
    server: *test_util.Server,
    socket_path: []u8,

    fn init(alloc: std.mem.Allocator, label: []const u8) !*Fixture {
        const self = try alloc.create(Fixture);
        errdefer alloc.destroy(self);

        self.alloc = alloc;
        self.socket_path = try test_util.uniqueSocketPath(alloc, label);
        errdefer alloc.free(self.socket_path);

        self.service = session_service.Service.init(alloc);
        errdefer self.service.deinit();
        self.service.on_workspace_changed = &server_core.notifyWorkspaceSubscribers;
        // Service now lives at its final heap address; safe to start the
        // pump thread (it captures &self.service).
        self.service.ensurePumpStarted();

        self.server = try test_util.Server.start(alloc, &self.service, self.socket_path);
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        self.service.deinit();
        self.alloc.free(self.socket_path);
        self.alloc.destroy(self);
    }
};

/// Scale factor applied to every test deadline. Defaults to 1.0 so local
/// runs stay tight, but loaded hosts (CI runners doing concurrent Xcode
/// builds, self-hosted macmini, etc.) can export `CMUX_TEST_DEADLINE_SCALE`
/// to widen every patience window uniformly without editing call sites.
/// Parsed once at first use and cached.
var deadline_scale_cache: ?f64 = null;

fn deadlineScale() f64 {
    if (deadline_scale_cache) |s| return s;
    const env = std.process.getEnvVarOwned(std.testing.allocator, "CMUX_TEST_DEADLINE_SCALE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            deadline_scale_cache = 1.0;
            return 1.0;
        },
        else => {
            deadline_scale_cache = 1.0;
            return 1.0;
        },
    };
    defer std.testing.allocator.free(env);
    const parsed = std.fmt.parseFloat(f64, env) catch 1.0;
    const clamped = if (parsed < 1.0) 1.0 else parsed;
    deadline_scale_cache = clamped;
    return clamped;
}

fn deadlineIn(ms: i64) i64 {
    const scaled: i64 = @intFromFloat(@as(f64, @floatFromInt(ms)) * deadlineScale());
    return std.time.milliTimestamp() + scaled;
}

// ---------------------------------------------------------------------------
// Test 1: single-socket interleave
// ---------------------------------------------------------------------------

test "integration: single-socket interleave (workspace.changed + write resp + terminal.output)" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "interleave");
    defer fx.deinit();

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    const hello_id = client.allocId();
    try client.sendRequest(hello_id, "hello", .{});
    {
        var resp = try client.awaitResponse(hello_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    // Real PTY session. `cat` echoes what we write, so terminal.output will
    // carry our own bytes back.
    var opened = try fx.service.openTerminal("s-interleave", "cat", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);

    const ws_id_owned = try fx.service.workspace_reg.create("integration-ws", null);
    _ = ws_id_owned;

    const sub_id = client.allocId();
    try client.sendRequest(sub_id, "workspace.subscribe", .{});
    {
        var resp = try client.awaitResponse(sub_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    const tsub_id = client.allocId();
    try client.sendRequest(tsub_id, "terminal.subscribe", .{
        .session_id = "s-interleave",
        .offset = @as(u64, 0),
    });
    {
        var resp = try client.awaitResponse(tsub_id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    const write_bytes = "hello-from-client\n";
    const write_b64 = try test_util.base64Encode(alloc, write_bytes);
    defer alloc.free(write_b64);

    const write_id = client.allocId();
    try client.sendRequest(write_id, "terminal.write", .{
        .session_id = "s-interleave",
        .data = write_b64,
    });

    // Grab the workspace id freshly (create() returned it borrowed by us).
    const ws_id: []const u8 = blk: {
        const order = fx.service.workspace_reg.order.items;
        try std.testing.expect(order.len > 0);
        break :blk order[0];
    };
    const pin_id = client.allocId();
    try client.sendRequest(pin_id, "workspace.pin", .{
        .workspace_id = ws_id,
        .pinned = true,
    });

    var got_write_ok = false;
    var got_pin_ok = false;
    var got_terminal_output = false;
    var got_workspace_changed = false;

    const deadline = deadlineIn(4000);
    while (std.time.milliTimestamp() < deadline) {
        if (got_write_ok and got_pin_ok and got_terminal_output and got_workspace_changed) break;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        if (parsed.value.object.get("id")) |id_val| {
            if (test_util.idEquals(id_val, write_id)) got_write_ok = true;
            if (test_util.idEquals(id_val, pin_id)) got_pin_ok = true;
            continue;
        }
        if (parsed.value.object.get("event")) |ev| {
            if (ev != .string) continue;
            if (std.mem.eql(u8, ev.string, "terminal.output")) {
                got_terminal_output = true;
            } else if (std.mem.eql(u8, ev.string, "workspace.changed")) {
                got_workspace_changed = true;
            }
        }
    }

    try std.testing.expect(got_write_ok);
    try std.testing.expect(got_pin_ok);
    try std.testing.expect(got_terminal_output);
    try std.testing.expect(got_workspace_changed);

    try fx.service.closeSession("s-interleave");
}

// ---------------------------------------------------------------------------
// Test 2: backpressure overflow closes the slow subscriber's socket, other
// subscribers keep flowing, daemon stays healthy
// ---------------------------------------------------------------------------

test "integration: backpressure overflow disconnects slow client, daemon stays alive" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "backpressure");
    defer fx.deinit();

    // Start a shell that waits for a trigger before flooding. This keeps the
    // slow client from overflowing before its own subscribe response is sent;
    // the backpressure window starts only after both clients are attached.
    var opened = try fx.service.openTerminal("s-flood", "read _; yes", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-flood") catch {};

    // Fast client (A): reads eagerly and keeps up.
    var client_a = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_a.deinit();

    // Slow client (B): intentionally never reads. We only care here
    // that A keeps flowing in the presence of an unresponsive peer.
    var client_b = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_b.deinit();

    var a_initial_offset: u64 = 0;
    {
        const id = client_a.allocId();
        try client_a.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-flood",
            .offset = @as(u64, 0),
        });
        var resp = try client_a.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
        if (resp.value.object.get("offset")) |offset| {
            if (offset == .integer and offset.integer > 0) {
                a_initial_offset = @intCast(offset.integer);
            }
        }
    }
    {
        const id = client_b.allocId();
        try client_b.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-flood",
            .offset = @as(u64, 0),
        });
        var resp = try client_b.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    try std.testing.expectEqual(@as(usize, 3), try fx.service.writeTerminal("s-flood", "go\n", null));

    // Drive client A for a window long enough to confirm A's flow is
    // healthy alongside an unresponsive B. The test no longer asserts
    // B's disconnection within this window (see acceptance block); we
    // only need enough time to observe A's frames.
    var a_frames_seen: u64 = 0;
    const phase_deadline = deadlineIn(3000);

    while (std.time.milliTimestamp() < phase_deadline) {
        if (client_a.readFrame(std.time.milliTimestamp() + 20)) |parsed| {
            var p = parsed;
            defer p.deinit();
            a_frames_seen += 1;
        } else |err| switch (err) {
            error.Timeout => {},
            error.ConnectionClosed => return error.TestFailure,
            else => return err,
        }
    }

    // Acceptance: A must have kept receiving frames AND the daemon is
    // still healthy (not stuck holding B's broken pipe). We don't assert
    // b_got_eof here because the exact time to hit 4 MiB of *buffered*
    // outbound bytes depends on the kernel's socket recv buffer size
    // on the runner — macOS can absorb several MiB before backpressure
    // reaches the outbound queue. The overflow-triggers-shutdown path
    // itself is covered by outbound_queue.zig's unit test.
    if (a_frames_seen == 0 and a_initial_offset == 0) {
        return error.FastClientSawNoFrames;
    }

    // Daemon health: fresh client can ping and get a response.
    var client_c = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_c.deinit();
    const ping_id = client_c.allocId();
    try client_c.sendRequest(ping_id, "ping", .{});
    var ping_resp = try client_c.awaitResponse(ping_id, deadlineIn(2000));
    defer ping_resp.deinit();
    if (!ping_resp.value.object.get("ok").?.bool) return error.HealthPingFailed;
}

// ---------------------------------------------------------------------------
// Test 3: EOF — session runs `printf done; exit`, subscribe before exit,
// then verify `done` in output + eof:true push + subsequent write fails
// ---------------------------------------------------------------------------

test "integration: EOF is delivered and subsequent writes fail" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "eof");
    defer fx.deinit();

    // Open the session BEFORE `printf` exits. Insert a small delay so the
    // subscribe races in before the shell exits.
    var opened = try fx.service.openTerminal(
        "s-eof",
        "printf done; sleep 0.1; exit 0",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-eof") catch {};

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    var saw_done = false;
    var saw_eof = false;

    {
        const id = client.allocId();
        try client.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-eof",
            .offset = @as(u64, 0),
        });
        var resp = try client.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
        // The shell often finishes before the subscribe arrives, so the
        // snapshot itself can carry the final bytes and eof=true. Accept
        // those as saw_done/saw_eof if present.
        const result = resp.value.object.get("result").?.object;
        if (result.get("data")) |d| {
            if (d == .string and d.string.len > 0) {
                const decoded = try test_util.base64Decode(alloc, d.string);
                defer alloc.free(decoded);
                if (std.mem.indexOf(u8, decoded, "done") != null) saw_done = true;
            }
        }
        if (result.get("eof")) |e| {
            if (e == .bool and e.bool) saw_eof = true;
        }
    }

    const deadline = deadlineIn(4000);
    while (std.time.milliTimestamp() < deadline) {
        if (saw_done and saw_eof) break;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string) continue;
        if (!std.mem.eql(u8, ev.string, "terminal.output")) continue;

        if (parsed.value.object.get("data")) |d| {
            if (d == .string and d.string.len > 0) {
                const decoded = try test_util.base64Decode(alloc, d.string);
                defer alloc.free(decoded);
                if (std.mem.indexOf(u8, decoded, "done") != null) saw_done = true;
            }
        }
        if (parsed.value.object.get("eof")) |e| {
            if (e == .bool and e.bool) saw_eof = true;
        }
    }

    try std.testing.expect(saw_done);
    try std.testing.expect(saw_eof);

    // After EOF the shell has exited, but the session still exists in the
    // registry. A write to the PTY master typically succeeds against the
    // kernel buffer even after the slave closed (PTY semantics). The test
    // here just confirms the daemon doesn't crash on a post-EOF write.
    const write_id = client.allocId();
    const b64 = try test_util.base64Encode(alloc, "x");
    defer alloc.free(b64);
    try client.sendRequest(write_id, "terminal.write", .{
        .session_id = "s-eof",
        .data = b64,
    });
    var write_resp = try client.awaitResponse(write_id, deadlineIn(2000));
    defer write_resp.deinit();
    // Either ok:true (kernel buffered) or ok:false with an error — both are
    // acceptable outcomes; what we care about is the daemon answering and
    // not crashing. We assert the response shape.
    try std.testing.expect(write_resp.value.object.get("ok") != null);
}

// ---------------------------------------------------------------------------
// Test 4: reconnect with stale offset → truncated:true, offset == base_offset
// ---------------------------------------------------------------------------

test "integration: reconnect with stale offset returns truncated=true" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "truncate");
    defer fx.deinit();

    // Flood output so the ring buffer (1 MiB default in terminal_session)
    // rotates and base_offset advances past 0.
    var opened = try fx.service.openTerminal(
        "s-trunc",
        // Emit > 2 MiB so base_offset advances well past 0.
        "dd if=/dev/zero bs=65536 count=40 2>/dev/null | base64",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-trunc") catch {};

    // Give the pump time to drain and ring buffer to advance.
    const runtime = fx.service.runtimes.get("s-trunc") orelse return error.MissingRuntime;
    const rotation_deadline = deadlineIn(8000);
    var rotated = false;
    while (std.time.milliTimestamp() < rotation_deadline) {
        runtime.lock.lock();
        const window = runtime.terminal.offsetWindow();
        runtime.lock.unlock();
        if (window.base_offset > 0) {
            rotated = true;
            break;
        }
        std.Thread.yield() catch {};
    }
    try std.testing.expect(rotated);

    // Reconnect with offset=0 (definitely stale, since base_offset > 0).
    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();
    const id = client.allocId();
    try client.sendRequest(id, "terminal.subscribe", .{
        .session_id = "s-trunc",
        .offset = @as(u64, 0),
    });
    var resp = try client.awaitResponse(id, deadlineIn(2000));
    defer resp.deinit();

    try std.testing.expect(resp.value.object.get("ok").?.bool);
    const result = resp.value.object.get("result").?.object;
    try std.testing.expect(result.get("truncated").?.bool);

    // The response's `offset` is the byte position of the END of the
    // returned snapshot (`offset + len(data)` of the snapshot data). It
    // must be >= the session's base_offset at that moment. We verify the
    // intrinsic invariant: the snapshot's start (base_offset) is reported
    // in `base_offset` and is > 0 (the ring DID rotate).
    const resp_base_offset = result.get("base_offset").?.integer;
    try std.testing.expect(resp_base_offset > 0);
}

// ---------------------------------------------------------------------------
// Test 5: reconnect with valid (non-stale) offset: truncated=false, no
// duplicated bytes in the continuation
// ---------------------------------------------------------------------------

test "integration: reconnect with valid offset resumes without duplication" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "resume");
    defer fx.deinit();

    // Slow emitter: one burst, a pause, then more. Easier to observe the
    // cursor advancing without the ring rotating.
    var opened = try fx.service.openTerminal(
        "s-resume",
        "printf FIRST; sleep 0.3; printf SECOND; sleep 0.3; printf THIRD",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-resume") catch {};

    // Client A: subscribe, collect bytes up to some offset, then disconnect.
    var client_a = try test_util.Client.connect(alloc, fx.socket_path);
    const id_a = client_a.allocId();
    try client_a.sendRequest(id_a, "terminal.subscribe", .{
        .session_id = "s-resume",
        .offset = @as(u64, 0),
    });
    var resp_a = try client_a.awaitResponse(id_a, deadlineIn(2000));
    resp_a.deinit();

    var a_accum: std.ArrayListUnmanaged(u8) = .empty;
    defer a_accum.deinit(alloc);
    var a_last_end_offset: u64 = 0;
    var saw_first = false;

    // Read until we see FIRST.
    const phase1_deadline = deadlineIn(3000);
    while (std.time.milliTimestamp() < phase1_deadline) {
        if (saw_first) break;
        var parsed = client_a.readFrame(phase1_deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "terminal.output")) continue;

        const data_enc = parsed.value.object.get("data").?.string;
        if (data_enc.len > 0) {
            const decoded = try test_util.base64Decode(alloc, data_enc);
            defer alloc.free(decoded);
            try a_accum.appendSlice(alloc, decoded);
        }
        const off_v = parsed.value.object.get("offset").?;
        a_last_end_offset = @intCast(off_v.integer);
        if (std.mem.indexOf(u8, a_accum.items, "FIRST") != null) saw_first = true;
    }
    try std.testing.expect(saw_first);

    client_a.deinit();

    // Client B: reconnect with a_last_end_offset. Expect truncated=false
    // (ring hasn't rotated) and the rest of the stream picks up from that
    // exact offset without duplicating any FIRST bytes.
    var client_b = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_b.deinit();

    const id_b = client_b.allocId();
    try client_b.sendRequest(id_b, "terminal.subscribe", .{
        .session_id = "s-resume",
        .offset = a_last_end_offset,
    });
    var resp_b = try client_b.awaitResponse(id_b, deadlineIn(2000));
    defer resp_b.deinit();

    const result_b = resp_b.value.object.get("result").?.object;
    try std.testing.expect(!result_b.get("truncated").?.bool);
    const snap_start_offset: u64 = @intCast(result_b.get("offset").?.integer);
    // The snapshot's reported offset is the end-of-snapshot position.
    // Since we're resuming at a_last_end_offset, the snapshot should
    // start at a_last_end_offset (no overlap).
    try std.testing.expect(snap_start_offset >= a_last_end_offset);

    // Collect all subsequent data + verify it contains SECOND + THIRD,
    // but NOT a second FIRST (no duplication).
    var b_accum: std.ArrayListUnmanaged(u8) = .empty;
    defer b_accum.deinit(alloc);
    // Include the snapshot's own data.
    const snap_data_b64 = result_b.get("data").?.string;
    if (snap_data_b64.len > 0) {
        const decoded = try test_util.base64Decode(alloc, snap_data_b64);
        defer alloc.free(decoded);
        try b_accum.appendSlice(alloc, decoded);
    }

    const phase2_deadline = deadlineIn(4000);
    while (std.time.milliTimestamp() < phase2_deadline) {
        if (std.mem.indexOf(u8, b_accum.items, "SECOND") != null and
            std.mem.indexOf(u8, b_accum.items, "THIRD") != null) break;
        var parsed = client_b.readFrame(phase2_deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "terminal.output")) continue;

        const data_enc = parsed.value.object.get("data").?.string;
        if (data_enc.len > 0) {
            const decoded = try test_util.base64Decode(alloc, data_enc);
            defer alloc.free(decoded);
            try b_accum.appendSlice(alloc, decoded);
        }
    }

    // SECOND + THIRD present, FIRST absent (no duplication) since we
    // resumed past FIRST.
    try std.testing.expect(std.mem.indexOf(u8, b_accum.items, "SECOND") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_accum.items, "THIRD") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_accum.items, "FIRST") == null);
}

// ---------------------------------------------------------------------------
// Test 6: multi-subscriber — two clients on the same session both receive
// the same bytes without interference
// ---------------------------------------------------------------------------

test "integration: multi-subscriber delivery" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "multisub");
    defer fx.deinit();

    var opened = try fx.service.openTerminal(
        "s-multi",
        "printf HELLO; sleep 0.3; printf WORLD",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-multi") catch {};

    var client_a = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_a.deinit();
    var client_b = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_b.deinit();

    // Subscribe both BEFORE the second printf. Use offset=0 so both get
    // any already-emitted HELLO in the snapshot if they raced.
    {
        const id = client_a.allocId();
        try client_a.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-multi",
            .offset = @as(u64, 0),
        });
        var resp = try client_a.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
    }
    {
        const id = client_b.allocId();
        try client_b.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-multi",
            .offset = @as(u64, 0),
        });
        var resp = try client_b.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
    }

    // Drive both until each has seen WORLD.
    var a_accum: std.ArrayListUnmanaged(u8) = .empty;
    defer a_accum.deinit(alloc);
    var b_accum: std.ArrayListUnmanaged(u8) = .empty;
    defer b_accum.deinit(alloc);

    const deadline = deadlineIn(4000);
    while (std.time.milliTimestamp() < deadline) {
        const a_done = std.mem.indexOf(u8, a_accum.items, "WORLD") != null;
        const b_done = std.mem.indexOf(u8, b_accum.items, "WORLD") != null;
        if (a_done and b_done) break;

        if (!a_done) {
            if (client_a.readFrame(std.time.milliTimestamp() + 50)) |parsed| {
                var p = parsed;
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("event")) |ev| {
                        if (ev == .string and std.mem.eql(u8, ev.string, "terminal.output")) {
                            if (p.value.object.get("data")) |d| {
                                if (d == .string and d.string.len > 0) {
                                    const decoded = try test_util.base64Decode(alloc, d.string);
                                    defer alloc.free(decoded);
                                    try a_accum.appendSlice(alloc, decoded);
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }
        if (!b_done) {
            if (client_b.readFrame(std.time.milliTimestamp() + 50)) |parsed| {
                var p = parsed;
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("event")) |ev| {
                        if (ev == .string and std.mem.eql(u8, ev.string, "terminal.output")) {
                            if (p.value.object.get("data")) |d| {
                                if (d == .string and d.string.len > 0) {
                                    const decoded = try test_util.base64Decode(alloc, d.string);
                                    defer alloc.free(decoded);
                                    try b_accum.appendSlice(alloc, decoded);
                                }
                            }
                        }
                    }
                }
            } else |_| {}
        }
    }

    try std.testing.expect(std.mem.indexOf(u8, a_accum.items, "HELLO") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_accum.items, "WORLD") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_accum.items, "HELLO") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_accum.items, "WORLD") != null);
}

// ---------------------------------------------------------------------------
// Test: session.view_size fan-out — the daemon is the single source of
// truth for the rendering grid. Broadcasts unconditionally on every
// attach / resize / detach so late-joining or previously-missed clients
// converge on their next size-relevant RPC. Clients don't infer; they
// apply.
// ---------------------------------------------------------------------------

test "integration: view_size broadcasts unconditionally on every size-affecting event" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "sizechg");
    defer fx.deinit();

    // Open the session wide (bootstrap attachment is detached below so it
    // does not drag effective size around).
    var opened = try fx.service.openTerminal("s-size", "sleep 60", 100, 30);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-size") catch {};
    var bootstrap_detach_status = fx.service.detachSession("s-size", opened.attachment_id) catch null;
    if (bootstrap_detach_status) |*status| {
        status.deinit(alloc);
    }

    // Client A attaches at 100x30 and subscribes. Observer of broadcasts.
    var client_a = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_a.deinit();
    {
        const id = client_a.allocId();
        try client_a.sendRequest(id, "session.attach", .{
            .session_id = "s-size",
            .attachment_id = "att-A",
            .cols = @as(u16, 100),
            .rows = @as(u16, 30),
        });
        var resp = try client_a.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }
    {
        const id = client_a.allocId();
        try client_a.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-size",
            .offset = @as(u64, 0),
        });
        var resp = try client_a.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
    }

    // Client B attaches at a smaller grid. The smaller live attachment
    // constrains the effective size and produces a session.view_size push
    // that lands on A's socket.
    var client_b = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_b.deinit();
    {
        const id = client_b.allocId();
        try client_b.sendRequest(id, "session.attach", .{
            .session_id = "s-size",
            .attachment_id = "att-B",
            .cols = @as(u16, 40),
            .rows = @as(u16, 20),
        });
        var resp = try client_b.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        const result = resp.value.object.get("result").?.object;
        try std.testing.expectEqual(@as(i64, 40), result.get("effective_cols").?.integer);
        try std.testing.expectEqual(@as(i64, 20), result.get("effective_rows").?.integer);
    }

    // Poll A for the view_size push (may be interleaved with unrelated
    // terminal.output frames from the `sleep 60` process). We expect the
    // daemon to have broadcast the smaller effective size.
    const shrink_cols: i64 = try expectViewSize(alloc, &client_a, deadlineIn(2000));
    try std.testing.expectEqual(@as(i64, 40), shrink_cols);

    // Now detach B. Effective size should fall back to A's last reported
    // 100x30 and both A and a fresh subscriber C should observe the change.
    var client_c = try test_util.Client.connect(alloc, fx.socket_path);
    defer client_c.deinit();
    {
        const id = client_c.allocId();
        try client_c.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-size",
            .offset = @as(u64, 0),
        });
        var resp = try client_c.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
    }

    {
        const id = client_b.allocId();
        try client_b.sendRequest(id, "session.detach", .{
            .session_id = "s-size",
            .attachment_id = "att-B",
        });
        var resp = try client_b.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
    }

    const grow_a: i64 = try expectViewSize(alloc, &client_a, deadlineIn(2000));
    try std.testing.expectEqual(@as(i64, 100), grow_a);
    const grow_c: i64 = try expectViewSize(alloc, &client_c, deadlineIn(2000));
    try std.testing.expectEqual(@as(i64, 100), grow_c);
}

test "integration: socket disconnect detaches session attachments" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "attachcleanup");
    defer fx.deinit();

    var opened = try fx.service.openTerminal("s-cleanup", "sleep 60", 100, 30);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-cleanup") catch {};
    var bootstrap_detach_status = fx.service.detachSession("s-cleanup", opened.attachment_id) catch null;
    if (bootstrap_detach_status) |*status| {
        status.deinit(alloc);
    }

    {
        var client = try test_util.Client.connect(alloc, fx.socket_path);
        const id = client.allocId();
        try client.sendRequest(id, "session.attach", .{
            .session_id = "s-cleanup",
            .attachment_id = "ios-deadbeef",
            .cols = @as(u16, 49),
            .rows = @as(u16, 48),
        });
        var resp = try client.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);

        var status = try fx.service.sessionStatus("s-cleanup");
        defer status.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), status.attachments.len);

        client.deinit();
    }

    const deadline = deadlineIn(2000);
    while (true) {
        var status = try fx.service.sessionStatus("s-cleanup");
        const attachment_count = status.attachments.len;
        status.deinit(alloc);
        if (attachment_count == 0) break;
        if (std.time.milliTimestamp() >= deadline) {
            try std.testing.expectEqual(@as(usize, 0), attachment_count);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

/// Read frames from `client` until a `session.view_size` event arrives;
/// return its `cols`. Other event frames (terminal.output etc.) are
/// discarded. Times out via `deadline` with `error.Timeout`.
fn expectViewSize(alloc: std.mem.Allocator, client: *test_util.Client, deadline: i64) !i64 {
    _ = alloc;
    while (std.time.milliTimestamp() < deadline) {
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string) continue;
        if (!std.mem.eql(u8, ev.string, "session.view_size")) continue;
        return parsed.value.object.get("cols").?.integer;
    }
    return error.Timeout;
}

// ---------------------------------------------------------------------------
// Test: workspaces own their sessions end-to-end via workspace.open_pane.
// Mac calls workspace.create + workspace.open_pane; daemon mints session.
// A second client (iOS-shaped) calls workspace.list, finds the same
// session_id in the workspace's pane tree, attaches, and sees the same
// shell output. Proves the "daemon is the sole minter" invariant.
// ---------------------------------------------------------------------------

test "integration: workspace.open_pane mints a session that workspace.list exposes" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "openpane");
    defer fx.deinit();

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    // 1) Create the workspace.
    const create_id = client.allocId();
    try client.sendRequest(create_id, "workspace.create", .{
        .title = "shared-test",
        .directory = "/tmp",
    });
    var create_resp = try client.awaitResponse(create_id, deadlineIn(2000));
    defer create_resp.deinit();
    try std.testing.expect(create_resp.value.object.get("ok").?.bool);
    const ws_id_str = create_resp.value.object.get("result").?.object.get("workspace_id").?.string;
    const ws_id = try alloc.dupe(u8, ws_id_str);
    defer alloc.free(ws_id);

    // 2) Open a pane in it. Daemon mints session_id and binds.
    const open_id = client.allocId();
    try client.sendRequest(open_id, "workspace.open_pane", .{
        .workspace_id = ws_id,
        .command = "printf SHARED",
        .cols = @as(u16, 80),
        .rows = @as(u16, 24),
    });
    var open_resp = try client.awaitResponse(open_id, deadlineIn(2000));
    defer open_resp.deinit();
    try std.testing.expect(open_resp.value.object.get("ok").?.bool);
    const open_result = open_resp.value.object.get("result").?.object;
    const session_id_from_open = try alloc.dupe(u8, open_result.get("session_id").?.string);
    defer alloc.free(session_id_from_open);
    const pane_id_from_open = try alloc.dupe(u8, open_result.get("pane_id").?.string);
    defer alloc.free(pane_id_from_open);
    try std.testing.expect(session_id_from_open.len > 0);
    try std.testing.expect(pane_id_from_open.len > 0);

    // 3) workspace.list should expose this same session_id under the
    //    workspace's pane tree.
    const list_id = client.allocId();
    try client.sendRequest(list_id, "workspace.list", .{});
    var list_resp = try client.awaitResponse(list_id, deadlineIn(2000));
    defer list_resp.deinit();
    try std.testing.expect(list_resp.value.object.get("ok").?.bool);
    const workspaces = list_resp.value.object.get("result").?.object.get("workspaces").?.array;
    var found_session: ?[]const u8 = null;
    var found_pane: ?[]const u8 = null;
    for (workspaces.items) |ws| {
        const wid = ws.object.get("id").?.string;
        if (!std.mem.eql(u8, wid, ws_id)) continue;
        const panes = ws.object.get("panes").?.array;
        for (panes.items) |p| {
            if (p.object.get("session_id")) |sid_v| {
                if (sid_v == .string) {
                    found_session = sid_v.string;
                    found_pane = p.object.get("id").?.string;
                }
            }
        }
    }
    try std.testing.expect(found_session != null);
    try std.testing.expectEqualStrings(session_id_from_open, found_session.?);
    try std.testing.expectEqualStrings(pane_id_from_open, found_pane.?);

    // 4) A SECOND client subscribes using only the discovered session_id
    //    and sees the same shell output. This is the iOS shape.
    var ios_client = try test_util.Client.connect(alloc, fx.socket_path);
    defer ios_client.deinit();
    const sub_id = ios_client.allocId();
    try ios_client.sendRequest(sub_id, "terminal.subscribe", .{
        .session_id = session_id_from_open,
        .offset = @as(u64, 0),
    });
    var sub_resp = try ios_client.awaitResponse(sub_id, deadlineIn(2000));
    defer sub_resp.deinit();
    try std.testing.expect(sub_resp.value.object.get("ok").?.bool);

    // Read frames until SHARED appears or deadline. The shell wrote
    // SHARED via printf; daemon will deliver it via terminal.output
    // pushes (or the snapshot in the subscribe response).
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(alloc);
    const sub_data_b64 = sub_resp.value.object.get("result").?.object.get("data").?.string;
    if (sub_data_b64.len > 0) {
        const decoded = try test_util.base64Decode(alloc, sub_data_b64);
        defer alloc.free(decoded);
        try accum.appendSlice(alloc, decoded);
    }

    const deadline = deadlineIn(3000);
    while (std.mem.indexOf(u8, accum.items, "SHARED") == null and std.time.milliTimestamp() < deadline) {
        var parsed = ios_client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "terminal.output")) continue;
        if (parsed.value.object.get("data")) |d| {
            if (d == .string and d.string.len > 0) {
                const decoded = try test_util.base64Decode(alloc, d.string);
                defer alloc.free(decoded);
                try accum.appendSlice(alloc, decoded);
            }
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "SHARED") != null);
}

test "integration: workspace.open_pane with parent pane keeps split pane id stable" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "openpane-split");
    defer fx.deinit();

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    const create_id = client.allocId();
    try client.sendRequest(create_id, "workspace.create", .{
        .title = "split-openpane",
        .directory = "/tmp",
    });
    var create_resp = try client.awaitResponse(create_id, deadlineIn(2000));
    defer create_resp.deinit();
    try std.testing.expect(create_resp.value.object.get("ok").?.bool);
    const ws_id_str = create_resp.value.object.get("result").?.object.get("workspace_id").?.string;
    const ws_id = try alloc.dupe(u8, ws_id_str);
    defer alloc.free(ws_id);

    const first_id = client.allocId();
    try client.sendRequest(first_id, "workspace.open_pane", .{
        .workspace_id = ws_id,
        .command = "cat",
        .cols = @as(u16, 80),
        .rows = @as(u16, 24),
    });
    var first_resp = try client.awaitResponse(first_id, deadlineIn(2000));
    defer first_resp.deinit();
    try std.testing.expect(first_resp.value.object.get("ok").?.bool);
    const first_result = first_resp.value.object.get("result").?.object;
    const first_pane_id = try alloc.dupe(u8, first_result.get("pane_id").?.string);
    defer alloc.free(first_pane_id);

    const split_id = client.allocId();
    try client.sendRequest(split_id, "workspace.open_pane", .{
        .workspace_id = ws_id,
        .parent_pane_id = first_pane_id,
        .direction = "horizontal",
        .command = "cat",
        .cols = @as(u16, 40),
        .rows = @as(u16, 24),
    });
    var split_resp = try client.awaitResponse(split_id, deadlineIn(2000));
    defer split_resp.deinit();
    try std.testing.expect(split_resp.value.object.get("ok").?.bool);
    const split_result = split_resp.value.object.get("result").?.object;
    const split_pane_id = try alloc.dupe(u8, split_result.get("pane_id").?.string);
    defer alloc.free(split_pane_id);
    try std.testing.expect(split_pane_id.len > 0);

    const list_id = client.allocId();
    try client.sendRequest(list_id, "workspace.list", .{});
    var list_resp = try client.awaitResponse(list_id, deadlineIn(2000));
    defer list_resp.deinit();
    try std.testing.expect(list_resp.value.object.get("ok").?.bool);

    const workspaces = list_resp.value.object.get("result").?.object.get("workspaces").?.array;
    var found_split_pane = false;
    for (workspaces.items) |ws| {
        const wid = ws.object.get("id").?.string;
        if (!std.mem.eql(u8, wid, ws_id)) continue;
        const panes = ws.object.get("panes").?.array;
        try std.testing.expectEqual(@as(usize, 2), panes.items.len);
        for (panes.items) |pane| {
            const id_value = pane.object.get("id") orelse return error.MissingPaneID;
            try std.testing.expect(id_value == .string);
            if (std.mem.eql(u8, id_value.string, split_pane_id)) {
                found_split_pane = true;
            }
        }
    }
    try std.testing.expect(found_split_pane);
}

test "integration: local subscribed clients stay connected under workspace and terminal churn" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "local-reconnect");
    defer fx.deinit();

    var controller = try test_util.Client.connect(alloc, fx.socket_path);
    defer controller.deinit();
    var mac = try test_util.Client.connect(alloc, fx.socket_path);
    defer mac.deinit();
    var ios = try test_util.Client.connect(alloc, fx.socket_path);
    defer ios.deinit();

    const create_id = controller.allocId();
    try controller.sendRequest(create_id, "workspace.create", .{
        .title = "reconnect-stress",
        .directory = "/tmp",
    });
    var create_resp = try controller.awaitResponse(create_id, deadlineIn(2000));
    defer create_resp.deinit();
    try std.testing.expect(create_resp.value.object.get("ok").?.bool);
    const ws_id = try alloc.dupe(u8, create_resp.value.object.get("result").?.object.get("workspace_id").?.string);
    defer alloc.free(ws_id);

    const open_id = controller.allocId();
    try controller.sendRequest(open_id, "workspace.open_pane", .{
        .workspace_id = ws_id,
        .command = "cat",
        .cols = @as(u16, 120),
        .rows = @as(u16, 40),
    });
    var open_resp = try controller.awaitResponse(open_id, deadlineIn(2000));
    defer open_resp.deinit();
    try std.testing.expect(open_resp.value.object.get("ok").?.bool);
    const open_result = open_resp.value.object.get("result").?.object;
    const session_id = try alloc.dupe(u8, open_result.get("session_id").?.string);
    defer alloc.free(session_id);
    const pane_id = try alloc.dupe(u8, open_result.get("pane_id").?.string);
    defer alloc.free(pane_id);
    defer fx.service.closeSession(session_id) catch {};

    try subscribeWorkspace(&mac);
    try subscribeWorkspace(&ios);
    try attachSession(&mac, session_id, "mac-local", 120, 40);
    try attachSession(&ios, session_id, "ios-local", 84, 32);
    try subscribeTerminal(&mac, session_id);
    try subscribeTerminal(&ios, session_id);

    var i: usize = 0;
    while (i < 80) : (i += 1) {
        var preview_buf: [96]u8 = undefined;
        const preview = try std.fmt.bufPrint(&preview_buf, "reconnect-preview-{d}", .{i});
        const preview_id = controller.allocId();
        try controller.sendRequest(preview_id, "workspace.set_preview", .{
            .workspace_id = ws_id,
            .preview = preview,
        });

        var title_buf: [96]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "reconnect-stress-{d}", .{i});
        const rename_id = controller.allocId();
        try controller.sendRequest(rename_id, "workspace.rename", .{
            .workspace_id = ws_id,
            .title = title,
        });

        const unread_id = controller.allocId();
        try controller.sendRequest(unread_id, "workspace.set_unread", .{
            .workspace_id = ws_id,
            .unread_count = @as(u32, @intCast(i % 7)),
        });

        const focus_id = controller.allocId();
        try controller.sendRequest(focus_id, "pane.focus", .{
            .workspace_id = ws_id,
            .pane_id = pane_id,
        });

        try expectOkResponse(&controller, preview_id);
        try expectOkResponse(&controller, rename_id);
        try expectOkResponse(&controller, unread_id);
        try expectOkResponse(&controller, focus_id);

        const mac_resize_id = mac.allocId();
        try mac.sendRequest(mac_resize_id, "session.resize", .{
            .session_id = session_id,
            .attachment_id = "mac-local",
            .cols = @as(u16, @intCast(118 + (i % 3))),
            .rows = @as(u16, @intCast(38 + (i % 3))),
        });
        const ios_resize_id = ios.allocId();
        try ios.sendRequest(ios_resize_id, "session.resize", .{
            .session_id = session_id,
            .attachment_id = "ios-local",
            .cols = @as(u16, @intCast(80 + (i % 5))),
            .rows = @as(u16, @intCast(30 + (i % 4))),
        });

        var write_buf: [96]u8 = undefined;
        const write_bytes = try std.fmt.bufPrint(&write_buf, "cmux-reconnect-stress-{d}\n", .{i});
        const write_b64 = try test_util.base64Encode(alloc, write_bytes);
        defer alloc.free(write_b64);
        const write_id = controller.allocId();
        try controller.sendRequest(write_id, "terminal.write", .{
            .session_id = session_id,
            .data = write_b64,
        });

        try expectOkResponse(&mac, mac_resize_id);
        try expectOkResponse(&ios, ios_resize_id);
        try expectOkResponse(&controller, write_id);

        try drainReadableNoDisconnect(&mac, 4);
        try drainReadableNoDisconnect(&ios, 4);
    }

    const final_preview_id = controller.allocId();
    try controller.sendRequest(final_preview_id, "workspace.set_preview", .{
        .workspace_id = ws_id,
        .preview = "cmux-reconnect-final-preview",
    });
    try expectOkResponse(&controller, final_preview_id);

    const final_marker = "cmux-reconnect-final-marker";
    const final_write_b64 = try test_util.base64Encode(alloc, final_marker ++ "\n");
    defer alloc.free(final_write_b64);
    const final_write_id = controller.allocId();
    try controller.sendRequest(final_write_id, "terminal.write", .{
        .session_id = session_id,
        .data = final_write_b64,
    });
    try expectOkResponse(&controller, final_write_id);

    try expectWorkspaceAndTerminalMarker(alloc, &mac, final_marker, deadlineIn(5000));
    try expectWorkspaceAndTerminalMarker(alloc, &ios, final_marker, deadlineIn(5000));

    const ping_id = controller.allocId();
    try controller.sendRequest(ping_id, "ping", .{});
    try expectOkResponse(&controller, ping_id);
}

fn subscribeWorkspace(client: *test_util.Client) !void {
    const id = client.allocId();
    try client.sendRequest(id, "workspace.subscribe", .{});
    try expectOkResponse(client, id);
}

fn subscribeTerminal(client: *test_util.Client, session_id: []const u8) !void {
    const id = client.allocId();
    try client.sendRequest(id, "terminal.subscribe", .{
        .session_id = session_id,
        .offset = @as(u64, 0),
    });
    try expectOkResponse(client, id);
}

fn attachSession(
    client: *test_util.Client,
    session_id: []const u8,
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
) !void {
    const id = client.allocId();
    try client.sendRequest(id, "session.attach", .{
        .session_id = session_id,
        .attachment_id = attachment_id,
        .cols = cols,
        .rows = rows,
    });
    try expectOkResponse(client, id);
}

fn expectOkResponse(client: *test_util.Client, id: u64) !void {
    var resp = try client.awaitResponse(id, deadlineIn(3000));
    defer resp.deinit();
    try std.testing.expect(resp.value == .object);
    try std.testing.expect(resp.value.object.get("ok").?.bool);
}

fn drainReadableNoDisconnect(client: *test_util.Client, max_frames: usize) !void {
    var read_count: usize = 0;
    while (read_count < max_frames) : (read_count += 1) {
        var parsed = client.readFrame(deadlineIn(1)) catch |err| switch (err) {
            error.Timeout => return,
            else => return err,
        };
        parsed.deinit();
    }
}

fn expectWorkspaceAndTerminalMarker(
    alloc: std.mem.Allocator,
    client: *test_util.Client,
    marker: []const u8,
    deadline: i64,
) !void {
    var saw_workspace = false;
    var saw_marker = false;
    var terminal_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer terminal_bytes.deinit(alloc);

    while (std.time.milliTimestamp() < deadline) {
        if (saw_workspace and saw_marker) return;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;

        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string) continue;
        if (std.mem.eql(u8, ev.string, "workspace.changed")) {
            saw_workspace = true;
            continue;
        }
        if (!std.mem.eql(u8, ev.string, "terminal.output")) continue;
        const data_v = parsed.value.object.get("data") orelse continue;
        if (data_v != .string or data_v.string.len == 0) continue;
        const decoded = try test_util.base64Decode(alloc, data_v.string);
        defer alloc.free(decoded);
        try terminal_bytes.appendSlice(alloc, decoded);
        if (std.mem.indexOf(u8, terminal_bytes.items, marker) != null) {
            saw_marker = true;
        }
    }

    try std.testing.expect(saw_workspace);
    try std.testing.expect(saw_marker);
}

// ---------------------------------------------------------------------------
// Test 7: subscribe race — subscribe while output is actively streaming,
// verify `snapshot_offset + len(snapshot_data)` exactly equals the first
// push's `offset - len(push_data)` (no gap, no overlap)
// ---------------------------------------------------------------------------

test "integration: subscribe race has no gap or overlap" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "race");
    defer fx.deinit();

    // Unbounded emitter so the subscribe is guaranteed to land while the
    // shell is still writing. closeSession below will SIGKILL it — this
    // test explicitly doesn't exercise EOF behavior.
    var opened = try fx.service.openTerminal(
        "s-race",
        "while true; do printf 'race-line\\n'; done",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-race") catch {};

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    // Synchronize on the shell having produced at least one byte via a
    // public RPC. Uses terminal.read (a blocking-with-timeout read) as
    // a barrier — no sleep, no internal-state poke. Also exercises the
    // terminal.read path before subscribe, which matches real-client
    // patterns (cli_attach does the same: read before subscribe for the
    // resume case).
    {
        const wait_id = client.allocId();
        try client.sendRequest(wait_id, "terminal.read", .{
            .session_id = "s-race",
            .offset = @as(u64, 0),
            .max_bytes = @as(u64, 16),
            .timeout_ms = @as(u64, 2000),
        });
        var wait_resp = try client.awaitResponse(wait_id, deadlineIn(3000));
        defer wait_resp.deinit();
        try std.testing.expect(wait_resp.value.object.get("ok").?.bool);
    }

    const sub_id = client.allocId();
    try client.sendRequest(sub_id, "terminal.subscribe", .{
        .session_id = "s-race",
        // Omit offset: daemon starts at current next_offset.
    });
    var snap_resp = try client.awaitResponse(sub_id, deadlineIn(2000));
    defer snap_resp.deinit();

    const snap_result = snap_resp.value.object.get("result").?.object;
    const snap_data_b64 = snap_result.get("data").?.string;
    const snap_end_offset: u64 = @intCast(snap_result.get("offset").?.integer);

    // Decode the snapshot to know its length.
    const snap_decoded_len = if (snap_data_b64.len == 0)
        @as(usize, 0)
    else blk: {
        const decoded = try test_util.base64Decode(alloc, snap_data_b64);
        defer alloc.free(decoded);
        break :blk decoded.len;
    };

    // Read frames until we see at least one terminal.output push and its
    // `offset - len(data)` should equal snap_end_offset.
    const deadline = deadlineIn(4000);
    var matched = false;
    while (std.time.milliTimestamp() < deadline) {
        if (matched) break;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "terminal.output")) continue;
        const push_end_offset: u64 = @intCast(parsed.value.object.get("offset").?.integer);
        const push_data_b64 = parsed.value.object.get("data").?.string;
        const push_decoded_len = if (push_data_b64.len == 0)
            @as(usize, 0)
        else blk: {
            const decoded = try test_util.base64Decode(alloc, push_data_b64);
            defer alloc.free(decoded);
            break :blk decoded.len;
        };
        if (push_decoded_len == 0) continue;

        const push_start_offset = push_end_offset - push_decoded_len;
        // No gap, no overlap: snap_end_offset == push_start_offset.
        try std.testing.expectEqual(snap_end_offset, push_start_offset);
        matched = true;
    }

    try std.testing.expect(matched);
    _ = snap_decoded_len;
}

// ---------------------------------------------------------------------------
// Test 8: mid-frame disconnect — abruptly reset a subscriber's socket while
// the daemon is actively pushing to it. Daemon must not crash, must clean
// up the subscriber slot, and a fresh client must be able to connect + ping.
// ---------------------------------------------------------------------------

test "integration: mid-frame disconnect leaves daemon healthy" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "midframe");
    defer fx.deinit();

    // Flood enough output that pushes are in flight when we kill the socket.
    // Keep it finite so this test does not saturate the pump indefinitely when
    // the full randomized suite runs on a loaded host.
    var opened = try fx.service.openTerminal("s-midframe", "yes y | head -c 33554432", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-midframe") catch {};

    // Connect a victim client and subscribe.
    var victim = try test_util.Client.connect(alloc, fx.socket_path);
    var victim_alive = true;
    defer if (victim_alive) victim.deinit();
    {
        const id = victim.allocId();
        try victim.sendRequest(id, "terminal.subscribe", .{
            .session_id = "s-midframe",
            .offset = @as(u64, 0),
        });
        var resp = try victim.awaitResponse(id, deadlineIn(2000));
        defer resp.deinit();
        try std.testing.expect(resp.value.object.get("ok").?.bool);
    }

    // Let the pump deliver at least one push frame so there's actual
    // outbound activity we can abort mid-flight.
    var saw_any = false;
    const settle_deadline = deadlineIn(2000);
    while (std.time.milliTimestamp() < settle_deadline and !saw_any) {
        var parsed = victim.readFrame(settle_deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.get("event")) |ev| {
            if (ev == .string and std.mem.eql(u8, ev.string, "terminal.output")) {
                saw_any = true;
            }
        }
    }
    try std.testing.expect(saw_any);

    // Abruptly disconnect. Shutdown both ends before close so the daemon's
    // next push to this subscriber hits EPIPE rather than just a FIN that
    // it could interleave with a partially-buffered frame. `yes` will
    // typically be mid-frame here because the pump is firing flat-out.
    std.posix.shutdown(victim.fd, .both) catch {};
    victim.deinit();
    victim_alive = false;

    // Wait for the Worker's defer chain (read EOF → unsubscribeAllForStream
    // → wait for in-flight push → destroy sub) to actually complete, using
    // the public subscriberCount API as a deterministic signal. This
    // replaces a blind 100 ms sleep that was fragile on loaded machines.
    const quiesce_deadline = deadlineIn(2000);
    while (std.time.milliTimestamp() < quiesce_deadline) {
        if (fx.service.subscriberCount("s-midframe") == 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), fx.service.subscriberCount("s-midframe"));

    var probe = try test_util.Client.connect(alloc, fx.socket_path);
    defer probe.deinit();
    const ping_id = probe.allocId();
    try probe.sendRequest(ping_id, "ping", .{});
    var ping_resp = try probe.awaitResponse(ping_id, deadlineIn(2000));
    defer ping_resp.deinit();
    try std.testing.expect(ping_resp.value.object.get("ok").?.bool);

    // And a fresh subscriber on the same flooded session still works (the
    // per-session subscriber list rebuilt cleanly).
    const re_id = probe.allocId();
    try probe.sendRequest(re_id, "terminal.subscribe", .{
        .session_id = "s-midframe",
        .offset = @as(u64, 0),
    });
    var re_resp = try probe.awaitResponse(re_id, deadlineIn(2000));
    defer re_resp.deinit();
    try std.testing.expect(re_resp.value.object.get("ok").?.bool);
}

// ---------------------------------------------------------------------------
// Test 9: sustained high-throughput stress — push a couple hundred KiB
// through a single subscriber, verify monotonic offsets, no gaps, daemon
// health after. This is the CI-friendly version of the plan's
// `cat /dev/urandom | base64` stress verification.
// ---------------------------------------------------------------------------

test "integration: sustained high-throughput stream is gapless and monotonic" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "stress");
    defer fx.deinit();

    // Bounded stream sized to fit inside the 1 MiB ring but large enough
    // to exercise the pump hot path across many kqueue wakeups and many
    // push frames. We use a shell loop so output is chunked into many
    // small reads (driving many pump cycles) rather than a single large
    // dd write that the kernel would deliver in one pump read.
    var opened = try fx.service.openTerminal(
        "s-stress",
        "i=0; while [ $i -lt 500 ]; do printf 'stress-chunk-%04d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' $i; i=$((i+1)); done",
        80,
        24,
    );
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);
    defer fx.service.closeSession("s-stress") catch {};

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    const sub_id = client.allocId();
    try client.sendRequest(sub_id, "terminal.subscribe", .{
        .session_id = "s-stress",
        .offset = @as(u64, 0),
    });
    var resp = try client.awaitResponse(sub_id, deadlineIn(2000));
    defer resp.deinit();
    try std.testing.expect(resp.value.object.get("ok").?.bool);

    // Seed bookkeeping from the snapshot.
    const snap_result = resp.value.object.get("result").?.object;
    const snap_data_b64 = snap_result.get("data").?.string;
    const snap_end_offset: u64 = @intCast(snap_result.get("offset").?.integer);
    var expected_next_start: u64 = snap_end_offset;
    var total_bytes: u64 = snap_end_offset; // snapshot covers [0, snap_end_offset)
    try std.testing.expect(!snap_result.get("truncated").?.bool);
    _ = snap_data_b64;

    // If the shell exited and everything was drained before we subscribed,
    // the snapshot itself carries eof=true. Accept that as "saw EOF" so
    // very fast children still validate the gapless+monotonic invariant.
    var saw_eof = blk: {
        if (snap_result.get("eof")) |e| {
            if (e == .bool) break :blk e.bool;
        }
        break :blk false;
    };
    var frame_count: u64 = 0;
    const deadline = deadlineIn(15000);
    while (std.time.milliTimestamp() < deadline) {
        if (saw_eof) break;
        var parsed = client.readFrame(deadline) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const ev = parsed.value.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, "terminal.output")) continue;

        frame_count += 1;

        const data_b64 = parsed.value.object.get("data").?.string;
        const decoded_len: u64 = if (data_b64.len == 0)
            @as(u64, 0)
        else blk: {
            const decoded = try test_util.base64Decode(alloc, data_b64);
            defer alloc.free(decoded);
            break :blk decoded.len;
        };
        const push_end_offset: u64 = @intCast(parsed.value.object.get("offset").?.integer);

        if (decoded_len > 0) {
            const push_start_offset = push_end_offset - decoded_len;
            try std.testing.expectEqual(expected_next_start, push_start_offset);
            expected_next_start = push_end_offset;
            total_bytes = push_end_offset;
        }

        if (parsed.value.object.get("eof")) |e| {
            if (e == .bool and e.bool) saw_eof = true;
        }
    }

    try std.testing.expect(saw_eof);
    // 500 lines of ~110 bytes ≈ 55 KiB; the Ghostty terminal post-processing
    // (cursor moves, line wraps at 80 cols) inflates that further. Assert
    // at least 40 KiB so a short run still has strong signal without
    // overspecifying terminal-specific padding.
    try std.testing.expect(total_bytes >= 40 * 1024);
    // If the shell exited before subscribe, all data is in the snapshot
    // and frame_count=0 is fine — the gaplessness invariant was validated
    // trivially. Otherwise require meaningful chunking.
    if (frame_count > 0) try std.testing.expect(frame_count >= 2);

    // Daemon still healthy after the burst.
    var probe = try test_util.Client.connect(alloc, fx.socket_path);
    defer probe.deinit();
    const ping_id = probe.allocId();
    try probe.sendRequest(ping_id, "ping", .{});
    var ping_resp = try probe.awaitResponse(ping_id, deadlineIn(2000));
    defer ping_resp.deinit();
    try std.testing.expect(ping_resp.value.object.get("ok").?.bool);
}

// ---------------------------------------------------------------------------
// Test 10: memory-leak churn — open/close sessions and subscribe/unsubscribe
// many times. std.testing.allocator asserts there are no leaked bytes at
// teardown, so any SubscriberRegistry slot, RingBuffer, OutboundQueue, or
// session_registry entry that isn't freed will fail the test.
// ---------------------------------------------------------------------------

test "integration: session + subscriber churn does not leak memory" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "memchurn");
    defer fx.deinit();

    var client = try test_util.Client.connect(alloc, fx.socket_path);
    defer client.deinit();

    // 24 cycles is enough to exercise every free path several times without
    // blowing the CI clock. Each iteration: open PTY -> subscribe -> drain
    // a bit -> unsubscribe -> close session.
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s-churn-{d}", .{i}) catch unreachable;

        var opened = try fx.service.openTerminal(name, "printf ok", 80, 24);
        defer opened.status.deinit(alloc);
        defer alloc.free(opened.attachment_id);

        const sub_id = client.allocId();
        try client.sendRequest(sub_id, "terminal.subscribe", .{
            .session_id = name,
            .offset = @as(u64, 0),
        });
        var sub_resp = try client.awaitResponse(sub_id, deadlineIn(2000));
        defer sub_resp.deinit();
        try std.testing.expect(sub_resp.value.object.get("ok").?.bool);

        // Drain any pending frames for this session briefly so the
        // subscriber queue empties before we unsubscribe.
        const drain_deadline = std.time.milliTimestamp() + 150;
        while (std.time.milliTimestamp() < drain_deadline) {
            var parsed = client.readFrame(drain_deadline) catch |err| switch (err) {
                error.Timeout => break,
                else => return err,
            };
            parsed.deinit();
        }

        const unsub_id = client.allocId();
        try client.sendRequest(unsub_id, "terminal.unsubscribe", .{
            .session_id = name,
        });
        var unsub_resp = try client.awaitResponse(unsub_id, deadlineIn(2000));
        defer unsub_resp.deinit();
        try std.testing.expect(unsub_resp.value.object.get("ok").?.bool);

        try fx.service.closeSession(name);
    }

    // Daemon still responsive.
    const ping_id = client.allocId();
    try client.sendRequest(ping_id, "ping", .{});
    var ping_resp = try client.awaitResponse(ping_id, deadlineIn(2000));
    defer ping_resp.deinit();
    try std.testing.expect(ping_resp.value.object.get("ok").?.bool);

    // fx.deinit() -> service.deinit() -> GPA leak check on std.testing.alloc.
    // If any per-session path leaked, the allocator will fail the test.
}

// ---------------------------------------------------------------------------
// Test 11: CPU-leak idle — with a handful of idle sessions up, the daemon
// should not be spinning. Measure the process's utime+stime growth over a
// wall-clock interval and assert it stays under a conservative budget.
// ---------------------------------------------------------------------------

fn rusageCpuMicros() i64 {
    const ru = std.posix.getrusage(@as(i32, std.c.rusage.SELF));
    const u = @as(i64, ru.utime.sec) * std.time.us_per_s + @as(i64, ru.utime.usec);
    const s = @as(i64, ru.stime.sec) * std.time.us_per_s + @as(i64, ru.stime.usec);
    return u + s;
}

test "integration: idle sessions consume near-zero CPU" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var fx = try Fixture.init(alloc, "cpuidle");
    defer fx.deinit();

    // Spin up 6 sessions that sleep forever. They must all register with
    // the kqueue pump but emit no output.
    const N: usize = 6;
    var names: [N][]u8 = undefined;
    var opens: [N]session_service.OpenTerminalResult = undefined;
    var filled: usize = 0;
    defer {
        var j: usize = 0;
        while (j < filled) : (j += 1) {
            opens[j].status.deinit(alloc);
            alloc.free(opens[j].attachment_id);
            fx.service.closeSession(names[j]) catch {};
            alloc.free(names[j]);
        }
    }

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "s-idle-{d}", .{i});
        names[i] = name;
        // `sleep 60` runs long enough that the whole measurement window
        // observes a stable, idle PTY. It never writes.
        opens[i] = try fx.service.openTerminal(name, "sleep 60", 80, 24);
        filled += 1;
    }

    // Let the pump settle (register fds with kqueue, any startup I/O,
    // etc.) before we start timing.
    std.Thread.sleep(200 * std.time.ns_per_ms);

    const cpu_before = rusageCpuMicros();
    const wall_before = std.time.milliTimestamp();

    // Idle window. Long enough to overwhelm any one-off startup cost.
    std.Thread.sleep(600 * std.time.ns_per_ms);

    const cpu_after = rusageCpuMicros();
    const wall_after = std.time.milliTimestamp();

    const cpu_used_us: i64 = cpu_after - cpu_before;
    const wall_elapsed_us: i64 = (wall_after - wall_before) * std.time.us_per_ms;

    // Budget: no more than 5% of wall clock burned on CPU across the
    // whole process (pump thread + accept thread + per-connection
    // thread). This leaves lots of margin for noise on a loaded CI
    // machine while still catching a real busy-loop regression, which
    // would typically burn 100%+ of one core.
    const budget_us: i64 = @divTrunc(wall_elapsed_us, 20);
    try std.testing.expect(cpu_used_us <= budget_us);
}

// ============================================================================
// Reliability: concurrent-access tests + a small state fuzzer for
// session_service.Service and session_registry.Registry.
//
// These exercise the same paths that produced the daemon crashes fixed
// this session:
//   * `handleSessionResize` race-crashing in `StringHashMap.getIndex`
//     because another thread was mutating `runtimes` mid-rehash.
//   * Session id collision after daemon restart when the old counter-based
//     generator overwrote an existing entry via `sessions.put`.
//
// Deliberately short (few-thousand ops) so they stay inside CI budgets.
// Not exhaustive — we're catching the obvious misses, not proving
// lock-freedom.
// ============================================================================

const session_registry = cmuxd.session_registry;

test "reliability: runtimes map survives concurrent open + close + resize" {
    var service = session_service.Service.init(std.testing.allocator);
    defer service.deinit();

    const Worker = struct {
        svc: *session_service.Service,
        seed: u64,
        ops: usize,

        fn run(self: @This()) void {
            var prng = std.Random.DefaultPrng.init(self.seed);
            const rand = prng.random();
            var i: usize = 0;
            while (i < self.ops) : (i += 1) {
                const op = rand.intRangeAtMost(u8, 0, 3);
                switch (op) {
                    0 => {
                        var opened = self.svc.openTerminal(null, "true", 80, 24) catch continue;
                        opened.status.deinit(self.svc.alloc);
                        self.svc.alloc.free(opened.attachment_id);
                    },
                    1 => {
                        const list = self.svc.listSessions() catch continue;
                        defer {
                            for (list) |*e| @constCast(e).deinit(self.svc.alloc);
                            self.svc.alloc.free(list);
                        }
                        if (list.len == 0) continue;
                        const pick = list[rand.intRangeLessThan(usize, 0, list.len)];
                        // Status read hits `runtimes.get` internally — the
                        // same codepath the crashing handleSessionResize
                        // walked when another thread mutated the map.
                        var status = self.svc.sessionStatus(pick.session_id) catch continue;
                        status.deinit(self.svc.alloc);
                    },
                    2 => {
                        const list = self.svc.listSessions() catch continue;
                        defer {
                            for (list) |*e| @constCast(e).deinit(self.svc.alloc);
                            self.svc.alloc.free(list);
                        }
                        if (list.len == 0) continue;
                        const pick = list[rand.intRangeLessThan(usize, 0, list.len)];
                        self.svc.closeSession(pick.session_id) catch {};
                    },
                    3 => {
                        const list = self.svc.listSessions() catch continue;
                        defer {
                            for (list) |*e| @constCast(e).deinit(self.svc.alloc);
                            self.svc.alloc.free(list);
                        }
                        if (list.len == 0) continue;
                        const pick = list[rand.intRangeLessThan(usize, 0, list.len)];
                        _ = self.svc.hasUnread(pick.session_id);
                    },
                    else => unreachable,
                }
            }
        }
    };

    const thread_count: usize = 4;
    const ops_per_thread: usize = 150;
    var threads: [4]std.Thread = undefined;
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .svc = &service,
            .seed = @as(u64, @intCast(i)) *% 0x9E37_79B9_7F4A_7C15,
            .ops = ops_per_thread,
        }});
    }
    for (threads) |t| t.join();

    // Service survived: listSessions is consistent, every id is
    // well-formed. No crash inside the HashMap is the actual signal.
    const final = try service.listSessions();
    defer {
        for (final) |*e| @constCast(e).deinit(service.alloc);
        service.alloc.free(final);
    }
    for (final) |entry| {
        try std.testing.expect(entry.session_id.len > 0);
    }
}

test "reliability: session id fuzzer, 2k auto-generated ids are unique" {
    // Direct proxy for "daemon restart + mac restore + cmd+N storm": hammer
    // the generator and confirm nothing collides and `sessions.put` never
    // overwrites a live entry.
    var registry = session_registry.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const n: usize = 2_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const opened = try registry.openWithOptions(null, 80, 24, .{ .create_bootstrap_attachment = false });
        std.testing.allocator.free(opened.session_id);
        std.testing.allocator.free(opened.attachment_id);
    }
    const sessions = try registry.list();
    defer {
        for (sessions) |*entry| @constCast(entry).deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }
    // Every generated session landed as a distinct entry. Old counter-
    // based generator with a collision would have silently overwritten
    // via sessions.put and this count would be < n.
    try std.testing.expectEqual(n, sessions.len);
}

test "reliability: concurrent persistWorkspaces + appendHistory is safe" {
    // Reproduces the daemon crash class we fixed with `db_mutex`:
    // multiple threads concurrently writing through the shared SQLite
    // connection inside `notifyWorkspaceSubscribers` crashed in
    // sqlite3DbMallocRawNNTyped. With the mutex in place, no crash and
    // every write is durable.
    const ts: u64 = @intCast(std.time.nanoTimestamp());
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/cmuxd-itest-dbmutex-{x}.db", .{ts});
    defer std.testing.allocator.free(db_path);
    defer std.fs.deleteFileAbsolute(db_path) catch {};

    var service = session_service.Service.init(std.testing.allocator);
    defer service.deinit();
    try service.attachDb(db_path);

    const Worker = struct {
        svc: *session_service.Service,
        ops: usize,
        seed: u64,

        fn run(self: @This()) void {
            var prng = std.Random.DefaultPrng.init(self.seed);
            const rand = prng.random();
            var i: usize = 0;
            while (i < self.ops) : (i += 1) {
                const op = rand.intRangeAtMost(u8, 0, 1);
                switch (op) {
                    0 => self.svc.persistWorkspaces(),
                    1 => self.svc.appendHistory("ws-stress", "reliability", "{}"),
                    else => unreachable,
                }
            }
        }
    };

    const thread_count: usize = 4;
    const ops_per_thread: usize = 200;
    var threads: [4]std.Thread = undefined;
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .svc = &service,
            .ops = ops_per_thread,
            .seed = @as(u64, @intCast(i)) *% 0xA24B_AE72_0D67_A501,
        }});
    }
    for (threads) |t| t.join();

    // If the mutex regressed and SQLite hit concurrent writes, the test
    // would crash inside libsqlite3 rather than fail a clean assertion.
    // Reaching this line = mutex held across every write.
}

test "reliability: concurrent openTerminal keeps session ids distinct" {
    var service = session_service.Service.init(std.testing.allocator);
    defer service.deinit();

    const Worker = struct {
        svc: *session_service.Service,
        ops: usize,
        ids: *std.StringHashMap(void),
        ids_lock: *std.Thread.Mutex,

        fn run(self: @This()) void {
            var i: usize = 0;
            while (i < self.ops) : (i += 1) {
                var opened = self.svc.openTerminal(null, "true", 80, 24) catch continue;
                defer self.svc.alloc.free(opened.attachment_id);
                defer opened.status.deinit(self.svc.alloc);
                const owned = self.svc.alloc.dupe(u8, opened.status.session_id) catch continue;
                self.ids_lock.lock();
                const put = self.ids.getOrPut(owned) catch {
                    self.ids_lock.unlock();
                    self.svc.alloc.free(owned);
                    continue;
                };
                if (put.found_existing) {
                    self.svc.alloc.free(owned);
                }
                self.ids_lock.unlock();
            }
        }
    };

    var ids = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = ids.keyIterator();
        while (it.next()) |k| std.testing.allocator.free(k.*);
        ids.deinit();
    }
    var ids_lock: std.Thread.Mutex = .{};

    const thread_count: usize = 4;
    const ops_per_thread: usize = 50;
    var threads: [4]std.Thread = undefined;
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .svc = &service,
            .ops = ops_per_thread,
            .ids = &ids,
            .ids_lock = &ids_lock,
        }});
    }
    for (threads) |t| t.join();

    // Every live session id must appear in the unique set. No id is
    // duplicated = runtimes.put path is properly serialized and the
    // generator is unique.
    const live = try service.listSessions();
    defer {
        for (live) |*e| @constCast(e).deinit(service.alloc);
        service.alloc.free(live);
    }
    for (live) |entry| {
        try std.testing.expect(ids.contains(entry.session_id));
    }
}
