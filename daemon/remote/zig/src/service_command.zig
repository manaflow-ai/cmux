//! Single-writer actor scaffolding for `session_service.Service` state.
//!
//! All mutations to Service-owned shared state funnel through a single
//! writer thread via this command queue. Submitters allocate a
//! `PendingReply(T)` on their stack, push a command carrying a pointer
//! to it, and block on the reply. The writer thread drains commands,
//! runs the corresponding impl synchronously (no other thread touches
//! Service state concurrently), and fulfills the reply.
//!
//! Why: per-field mutex discipline produced four distinct daemon
//! crashes in a single dogfood session (race in `runtimes` hashmap,
//! race in SQLite connection, double-init race on the debouncer maps,
//! publication-ordering race after the first fix). Every new field
//! added is a new hazard; every new thread is a new forgot-to-lock
//! site. Option A: make concurrent mutation unrepresentable.
//!
//! Migration strategy: introduce this scaffolding alongside the
//! existing locked-by-convention code. Migrate one method group per
//! PR (start with `openTerminal`/`closeSession`). Delete the
//! corresponding mutex when all paths to that field go through the
//! queue. The writer is spawned from `Service.init`'s caller (same
//! pattern as the kqueue pump).

const std = @import("std");

/// Envelope for a command reply. Submitters pre-allocate one on their
/// stack, pass a pointer in with the command, and call `.wait()` to
/// block until the writer fills it. Supports both success payloads
/// and error returns.
pub fn PendingReply(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Outcome = union(enum) {
            ok: T,
            err: anyerror,
        };

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        outcome: ?Outcome = null,

        pub fn wait(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.outcome == null) self.cond.wait(&self.mutex);
            return switch (self.outcome.?) {
                .ok => |v| v,
                .err => |e| e,
            };
        }

        pub fn fulfillOk(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.outcome == null);
            self.outcome = .{ .ok = value };
            self.cond.signal();
        }

        pub fn fulfillErr(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.outcome == null);
            self.outcome = .{ .err = err };
            self.cond.signal();
        }
    };
}

/// Opaque command dispatch. Each variant is (request fields, reply
/// pointer). The writer thread destructures via a switch; new command
/// types are added here, dispatched in `service_actor.zig`.
///
/// Request fields are borrowed: the submitter guarantees they stay
/// live until the reply is fulfilled (which happens before `wait()`
/// returns). Reply payloads carry ownership per their type's
/// conventions (typically heap-allocated slices that caller now owns).
pub const Command = union(enum) {
    open_terminal: OpenTerminalCmd,
    close_session: CloseSessionCmd,
    attach_session: AttachSessionCmd,
    resize_session: ResizeSessionCmd,
    detach_session: DetachSessionCmd,
    session_status: SessionStatusCmd,
    list_sessions: ListSessionsCmd,
    persist_workspaces: PersistWorkspacesCmd,
    append_history: AppendHistoryCmd,
    history_query: HistoryQueryCmd,
    history_clear: HistoryClearCmd,
    unsubscribe_terminal: UnsubscribeTerminalCmd,
    unsubscribe_all_for_stream: UnsubscribeAllForStreamCmd,
    shutdown: void,
};

/// Result shape for `open_terminal`. Matches the existing public API.
/// Caller owns `attachment_id` on success; `status` is a
/// `SessionStatus` which the caller must deinit.
pub const OpenTerminalResult = struct {
    status: OpenStatusOpaque,
    // `[]const u8` mirrors the existing `session_service.OpenTerminalResult`.
    // Caller owns the allocation and frees via its own allocator after use.
    attachment_id: []const u8,
    offset: u64,

    /// `SessionStatus` from `session_registry`; we keep it opaque here
    /// to avoid cross-module coupling in the command enum.
    pub const OpenStatusOpaque = @import("session_registry.zig").SessionStatus;
};

pub const OpenTerminalCmd = struct {
    // Borrowed — submitter keeps these alive through reply.wait().
    maybe_session_id: ?[]const u8,
    command: []const u8,
    cols: u16,
    rows: u16,
    options: @import("session_registry.zig").Registry.OpenOptions,
    reply: *PendingReply(OpenTerminalResult),
};

pub const CloseSessionCmd = struct {
    session_id: []const u8,
    reply: *PendingReply(void),
};

// `SessionStatus` from session_registry; caller owns and deinits after
// the reply returns.
const SessionStatus = @import("session_registry.zig").SessionStatus;

pub const AttachSessionCmd = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
    reply: *PendingReply(SessionStatus),
};

pub const ResizeSessionCmd = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
    reply: *PendingReply(SessionStatus),
};

pub const DetachSessionCmd = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    reply: *PendingReply(SessionStatus),
};

pub const SessionStatusCmd = struct {
    session_id: []const u8,
    reply: *PendingReply(SessionStatus),
};

pub const ListSessionsCmd = struct {
    reply: *PendingReply([]@import("session_registry.zig").SessionListEntry),
};

// persistence types, kept opaque in the command enum to avoid coupling.
const persistence = @import("persistence.zig");

pub const PersistWorkspacesCmd = struct {
    reply: ?*PendingReply(void) = null,
};

pub const AppendHistoryCmd = struct {
    workspace_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    reply: *PendingReply(void),
};

pub const HistoryQueryCmd = struct {
    workspace_id: ?[]const u8,
    limit: u32,
    before_seq: ?i64,
    // HistoryList owns its rows; caller deinits after reading.
    reply: *PendingReply(persistence.HistoryList),
};

pub const HistoryClearCmd = struct {
    reply: *PendingReply(void),
};

pub const UnsubscribeTerminalCmd = struct {
    // Stream pointer identifies a specific (stream, session_id)
    // subscription. Caller guarantees the stream outlives the
    // reply.
    stream: *anyopaque,
    session_id: []const u8,
    reply: *PendingReply(bool),
};

pub const UnsubscribeAllForStreamCmd = struct {
    stream: *anyopaque,
    reply: *PendingReply(void),
};

/// Bounded-at-runtime-only command queue. Unbounded by design: back-
/// pressure is not useful for a single-writer daemon (submitters are
/// the transports; blocking them blocks the whole daemon). If growth
/// becomes a concern, add a high-water warning but don't reject.
pub const Queue = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    pending: std.ArrayListUnmanaged(Command) = .empty,
    shutdown_requested: bool = false,

    pub fn init(alloc: std.mem.Allocator) Queue {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Queue) void {
        self.pending.deinit(self.alloc);
    }

    /// Post a command. Returns `error.QueueShutdown` if the writer has
    /// begun shutdown (submitters should treat this as "daemon going
    /// down, give up").
    pub fn submit(self: *Queue, cmd: Command) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown_requested) return error.QueueShutdown;
        try self.pending.append(self.alloc, cmd);
        self.cond.signal();
    }

    /// Signal the writer to stop accepting commands and exit after
    /// draining the current queue. Idempotent.
    pub fn signalShutdown(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown_requested = true;
        self.cond.broadcast();
    }

    /// Block until a command is available, or the queue has been shut
    /// down and drained. Returns null on final drain so the writer's
    /// outer loop can exit cleanly.
    pub fn takeBlocking(self: *Queue) ?Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.pending.items.len == 0) {
            if (self.shutdown_requested) return null;
            self.cond.wait(&self.mutex);
        }
        return self.pending.orderedRemove(0);
    }
};

test "PendingReply wait/fulfill round-trips a value" {
    var reply: PendingReply(u32) = .{};

    const t = try std.Thread.spawn(.{}, struct {
        fn run(r: *PendingReply(u32)) void {
            r.fulfillOk(42);
        }
    }.run, .{&reply});

    const got = try reply.wait();
    try std.testing.expectEqual(@as(u32, 42), got);
    t.join();
}

test "PendingReply wait returns the error on fulfillErr" {
    var reply: PendingReply(u32) = .{};
    reply.fulfillErr(error.TestFailure);
    try std.testing.expectError(error.TestFailure, reply.wait());
}

test "Queue FIFO + shutdown drains then returns null" {
    var q = Queue.init(std.testing.allocator);
    defer q.deinit();

    var r1: PendingReply(void) = .{};
    var r2: PendingReply(void) = .{};
    try q.submit(.{ .close_session = .{ .session_id = "a", .reply = &r1 } });
    try q.submit(.{ .close_session = .{ .session_id = "b", .reply = &r2 } });

    const c1 = q.takeBlocking() orelse return error.MissingCommand;
    try std.testing.expectEqualStrings("a", c1.close_session.session_id);

    const c2 = q.takeBlocking() orelse return error.MissingCommand;
    try std.testing.expectEqualStrings("b", c2.close_session.session_id);

    q.signalShutdown();
    try std.testing.expect(q.takeBlocking() == null);

    // Post-shutdown submits are refused.
    var r3: PendingReply(void) = .{};
    try std.testing.expectError(error.QueueShutdown, q.submit(.{
        .close_session = .{ .session_id = "c", .reply = &r3 },
    }));
}
