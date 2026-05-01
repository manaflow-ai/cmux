const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const outbound_queue = @import("outbound_queue.zig");
const persistence = @import("persistence.zig");
const proxy_streams = @import("proxy_streams.zig");
const pty_host = @import("pty_host.zig");
const pty_pump = @import("pty_pump.zig");
const serialize = @import("serialize.zig");
const service_command = @import("service_command.zig");
const session_registry = @import("session_registry.zig");
const sync_map = @import("sync_map.zig");
const terminal_session = @import("terminal_session.zig");
pub const workspace_registry = @import("workspace_registry.zig");
const workspace_persistence = @import("workspace_persistence.zig");

const RuntimeMap = sync_map.SyncStringHashMap(*RuntimeSession);

/// One client subscription to a terminal session. Pump-driven push events
/// get framed as WebSocket text frames and written to `stream` while
/// `stream_lock` is held to serialize against any RPC response writer
/// running on the connection's reader thread.
pub const TerminalSubscription = struct {
    session_id: []const u8, // slice into `owned_session_id`
    /// Owned storage for `session_id`. Previously the subscription
    /// borrowed the `runtimes` map's key slice, which required strict
    /// ordering between runtime removal and subscription cleanup.
    /// Now subscriptions own their id so the map's key can be freed
    /// independently. `null` only in test fixtures that bypass the
    /// normal subscribe path.
    owned_session_id: ?[]u8 = null,
    stream: *std.net.Stream,
    stream_lock: *std.Thread.Mutex,
    /// If set, push frames are enqueued (line-framed) into a per-connection
    /// writer thread. Otherwise the WS sync framing path is used.
    queue: ?*outbound_queue.OutboundQueue = null,
    last_offset: u64,
    seq: u64 = 0,
    dead: std.atomic.Value(bool) = .init(false),
    /// Last bell_count observed when we pushed to this subscriber.
    last_bell_count: u64 = 0,
    /// Last command_seq observed when we pushed to this subscriber.
    last_command_seq: u64 = 0,
    /// Last notification_seq observed when we pushed to this subscriber.
    last_notification_seq: u64 = 0,
    /// Whether we've already delivered an eof=true push to this subscriber.
    /// The dispatch decision ("do we have anything new?") has to include
    /// this, otherwise a PTY that closes after its last byte was pushed
    /// would leave the subscriber hanging on eof=false forever.
    eof_sent: bool = false,
    /// Count of in-flight `deliverTerminalPushes` iterations carrying a
    /// snapshot pointer to this sub. Incremented under `sub_mutex` while
    /// the sub was still live; decremented after the per-sub push
    /// completes. Unsubscribe marks the sub dead, drops it from
    /// `terminal_subs`, releases `sub_mutex`, then waits on `in_flight_cv`
    /// before freeing the allocation. This also keeps `sub.queue` (which
    /// points into the owning Worker's stack frame in the unix-socket
    /// transport) valid for the push duration, because `Worker.run`'s
    /// defer chain calls `unsubscribeAllForStream` which doesn't return
    /// past this wait until no push is in flight.
    in_flight: u32 = 0,
    in_flight_mutex: std.Thread.Mutex = .{},
    in_flight_cv: std.Thread.Condition = .{},

    fn retainForPush(self: *TerminalSubscription) void {
        self.in_flight_mutex.lock();
        defer self.in_flight_mutex.unlock();
        self.in_flight += 1;
    }

    fn releasePush(self: *TerminalSubscription) void {
        self.in_flight_mutex.lock();
        defer self.in_flight_mutex.unlock();
        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
        if (self.in_flight == 0) self.in_flight_cv.broadcast();
    }
};

pub const SubscribeSnapshot = struct {
    data: []u8, // owned
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
    seq: u64,
};

pub const AttachmentResult = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub const OpenTerminalResult = struct {
    status: session_registry.SessionStatus,
    attachment_id: []const u8,
    offset: u64,
};

pub const ReadTerminalResult = struct {
    data: []u8,
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
};

const RuntimeSession = struct {
    const RefCount = struct {
        mutex: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        count: u32 = 0,

        fn retain(self: *RefCount) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.count += 1;
        }

        fn release(self: *RefCount) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.count > 0);
            self.count -= 1;
            if (self.count == 0) self.cv.broadcast();
        }

        fn waitUntilZero(self: *RefCount) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count > 0) {
                self.cv.wait(&self.mutex);
            }
        }
    };

    alloc: std.mem.Allocator,
    pty: pty_host.PtyHost,
    terminal: terminal_session.TerminalSession,
    recent_write_ids: std.StringHashMap(void),
    recent_write_id_order: std.ArrayListUnmanaged([]u8) = .empty,
    /// Serializes pump-thread access to `pty`/`terminal` against any
    /// foreground caller (read/write/history/resize/deinit).
    lock: std.Thread.Mutex = .{},
    /// Published to the pump via `pty_pump.Entry.in_flight`. The pump bumps
    /// this while it holds pointers into this RuntimeSession and `unregister`
    /// waits for it to hit zero before returning, so `closeSession` can safely
    /// free the struct after unregister.
    pump_in_flight: pty_pump.InflightCounter = .{},
    /// True when the pump observed new PTY output while no client was
    /// subscribed. Cleared on terminal.subscribe or session.markRead.
    has_unread_output: std.atomic.Value(bool) = .init(false),
    /// Last counters observed when we dispatched a remote push for this
    /// session. Independent of the subscriber-facing counters so we only
    /// fire once per remote-visible notification event. Only touched while
    /// holding `lock`.
    last_remote_bell_count: u64 = 0,
    last_remote_command_seq: u64 = 0,
    last_remote_notification_seq: u64 = 0,
    /// Last cols/rows we actually fired. Packed into a single u32 so
    /// both halves can be read/written atomically without a second
    /// lock. Lets us skip identical back-to-back resizes cheaply.
    last_resize_dims: std.atomic.Value(u32) = .init(0),
    /// Transport-thread refcount. Incremented by `Service.acquireRuntime`
    /// under the runtimes-map shared lock; decremented by
    /// `RuntimeSession.release` when the caller is done dereferencing the
    /// pointer. `Service.removeRuntime` waits for this to hit zero after
    /// `fetchRemove` so no transport thread can touch freed memory.
    /// Writer-thread paths (actor-routed methods) do not use the refcount —
    /// the writer is single-threaded against removal so the pointer stays
    /// valid for the duration of the command handler.
    users: RefCount = .{},

    /// Decrement the transport refcount. Call exactly once per successful
    /// `Service.acquireRuntime`.
    fn release(self: *RuntimeSession) void {
        self.users.release();
    }

    fn init(alloc: std.mem.Allocator, command: []const u8, cols: u16, rows: u16) !RuntimeSession {
        return .{
            .alloc = alloc,
            .pty = try pty_host.PtyHost.init(alloc, command, cols, rows),
            .terminal = try terminal_session.TerminalSession.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 100_000,
            }),
            .recent_write_ids = std.StringHashMap(void).init(alloc),
        };
    }

    fn deinit(self: *RuntimeSession) void {
        self.lock.lock();
        defer self.lock.unlock();
        var write_id_iter = self.recent_write_ids.keyIterator();
        while (write_id_iter.next()) |key| self.alloc.free(key.*);
        self.recent_write_ids.deinit();
        self.recent_write_id_order.deinit(self.alloc);
        self.terminal.deinit();
        self.pty.deinit();
    }

    fn resize(self: *RuntimeSession, cols: u16, rows: u16) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.pty.resize(cols, rows);
        try self.terminal.resize(cols, rows);
    }

    fn read(self: *RuntimeSession, alloc: std.mem.Allocator, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const start_ms = std.time.milliTimestamp();

        while (true) {
            self.lock.lock();
            try self.pty.pump(&self.terminal);
            const window = self.terminal.offsetWindow();
            var effective_offset = offset;
            const truncated = effective_offset < window.base_offset;
            if (effective_offset < window.base_offset) effective_offset = window.base_offset;

            if (effective_offset < window.next_offset) {
                defer self.lock.unlock();
                const refreshed = self.terminal.offsetWindow();
                const raw = try self.terminal.readRaw(alloc, offset, max_bytes);
                return .{
                    .data = raw.data,
                    .offset = raw.offset,
                    .base_offset = raw.base_offset,
                    .truncated = raw.truncated,
                    .eof = self.pty.isClosed() and raw.offset >= refreshed.next_offset,
                };
            }

            if (self.pty.isClosed()) {
                defer self.lock.unlock();
                return .{
                    .data = try alloc.dupe(u8, ""),
                    .offset = window.next_offset,
                    .base_offset = window.base_offset,
                    .truncated = truncated,
                    .eof = true,
                };
            }
            self.lock.unlock();

            const wait_ms = if (timeout_ms <= 0) -1 else blk: {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const remaining = @as(i64, timeout_ms) - elapsed;
                if (remaining <= 0) return error.ReadTimeout;
                break :blk @as(i32, @intCast(remaining));
            };
            const ready = try self.pty.waitReadable(wait_ms);
            if (!ready) return error.ReadTimeout;
        }
    }

    fn writeDraining(self: *RuntimeSession, write_id: ?[]const u8, data: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var owned_write_id: ?[]u8 = null;
        errdefer if (owned_write_id) |owned| self.alloc.free(owned);
        if (write_id) |id| {
            if (id.len > 0) {
                if (self.recent_write_ids.contains(id)) return;
                try self.recent_write_id_order.ensureUnusedCapacity(self.alloc, 1);
                try self.recent_write_ids.ensureUnusedCapacity(1);
                owned_write_id = try self.alloc.dupe(u8, id);
            }
        }

        if (owned_write_id) |owned| {
            self.recent_write_ids.putAssumeCapacity(owned, {});
            self.recent_write_id_order.appendAssumeCapacity(owned);
            owned_write_id = null;
            while (self.recent_write_id_order.items.len > 256) {
                const evicted = self.recent_write_id_order.orderedRemove(0);
                _ = self.recent_write_ids.remove(evicted);
                self.alloc.free(evicted);
            }
        }

        try self.pty.writeDraining(&self.terminal, data);
    }

    fn historyDump(self: *RuntimeSession, alloc: std.mem.Allocator, format: serialize.HistoryFormat) !TerminalHistorySnapshot {
        self.lock.lock();
        defer self.lock.unlock();
        try self.pty.pump(&self.terminal);
        const window = self.terminal.offsetWindow();
        return .{
            .history = try self.terminal.history(alloc, format),
            .next_offset = window.next_offset,
        };
    }
};

/// Remote push config for APNs delivery through an HTTP endpoint (e.g. a
/// Next.js route on Vercel). Populated by the `daemon.configure_notifications`
/// RPC. All fields are owned by the `Service` allocator and protected by
/// `notifications_lock`.
pub const RemoteNotificationConfig = struct {
    endpoint: []const u8 = "",
    bearer_token: []const u8 = "",
    device_tokens: [][]const u8 = &.{},
};

pub const TerminalHistorySnapshot = struct {
    history: []u8,
    next_offset: u64,
};

/// Snapshot of notification state for an unread session, handed off to the
/// dispatcher thread. Fields are owned by the allocator that created the job
/// and are freed by `freePushJob` once delivery completes.
const PushJob = struct {
    service: *Service,
    endpoint: []u8,
    bearer_token: []u8,
    device_tokens: [][]u8,
    session_id: []u8,
    workspace_id: ?[]u8,
    bell: bool,
    command_finished: bool,
    exit_code: ?i32,
    notification_present: bool,
    notif_title: ?[]u8,
    notif_body: ?[]u8,
};

pub const Service = struct {
    alloc: std.mem.Allocator,
    instance_id: []const u8 = "",
    proxies: proxy_streams.Manager,
    registry: session_registry.Registry,
    runtimes: RuntimeMap,
    workspace_reg: workspace_registry.Registry,
    subscriptions: workspace_registry.SubscriptionManager = .{},
    pump: ?pty_pump.Pump = null,
    /// Serializes `ensurePumpStarted`. Without it, two transports
    /// calling the function concurrently can both observe `pump == null`
    /// and both run init; the second init overwrites the field, leaking
    /// the first pump and orphaning its kqueue thread. Same structural
    /// bug as the debouncer's init race. Publication-safe: the flag is
    /// the `pump != null` check itself, which is set under this mutex.
    pump_init_mutex: std.Thread.Mutex = .{},
    pump_notify_thread_id: std.atomic.Value(u64) = .init(0),
    sub_mutex: std.Thread.Mutex = .{},
    terminal_subs: std.ArrayListUnmanaged(*TerminalSubscription) = .empty,
    /// Optional hook invoked when an unread-state transition occurs so the
    /// transport layer can broadcast workspace.changed. Wired by serve_*.
    on_workspace_changed: ?*const fn (*Service) void = null,
    /// Guards `remote_notifications`.
    notifications_lock: std.Thread.Mutex = .{},
    remote_notifications: RemoteNotificationConfig = .{},
    /// Number of in-flight remote push dispatcher threads. Each thread
    /// increments before spawn and decrements on completion. `deinit`
    /// waits for this to reach zero (signalled via `push_cv`) so detached
    /// threads never outlive the service's allocator / config strings.
    push_inflight: std.atomic.Value(usize) = .init(0),
    push_cv_mutex: std.Thread.Mutex = .{},
    push_cv: std.Thread.Condition = .{},
    push_shutting_down: std.atomic.Value(bool) = .init(false),
    /// Persistence layer. When non-null, every workspace-registry mutation is
    /// mirrored to disk so daemon restarts rehydrate the same state. Owned
    /// by the Service; closed in deinit.
    db: ?persistence.Db = null,
    // db_mutex: deleted. All four db-access methods (persistWorkspaces,
    // appendHistory, historyQuery, historyClear) are routed through the
    // writer thread via the command queue, so only one thread ever
    // touches `db` at a time by construction. No mutex needed.
    // `runtimes` is a SyncStringHashMap — the lock is encapsulated in
    // the map itself. No separate `runtimes_mutex` field: that pattern
    // was "forget to lock at site N" bait.

    /// Single-writer command queue. Starting with openTerminal/closeSession
    /// migrated through the queue; other Service methods still use the
    /// legacy locked-by-convention pattern until subsequent cuts migrate
    /// them. See `service_command.zig` for the end-state rationale.
    command_queue: service_command.Queue,
    /// Writer thread that drains `command_queue`. Spawned lazily via
    /// `ensureWriterStarted` using the same idempotent pattern as the
    /// other worker threads.
    writer_thread: ?std.Thread = null,
    writer_started: std.atomic.Value(bool) = .init(false),
    writer_init_mutex: std.Thread.Mutex = .{},
    /// OS-level ID of the writer thread. Used by submit-and-wait shims
    /// to detect re-entrant calls: a command handler running on the
    /// writer that calls another migrated method would deadlock if it
    /// submitted + waited, because the writer is busy waiting for the
    /// reply from its own next-iteration drain. `isOnWriterThread`
    /// short-circuits that by invoking the impl directly when we're
    /// already on the writer.
    writer_thread_id: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: std.mem.Allocator) Service {
        // NOTE: we intentionally do NOT start the kqueue pump thread here.
        // Zig's result-location semantics do not guarantee that `&service`
        // inside this function equals `&caller_destination` — so a pump
        // thread started here would capture a stale pointer into a local
        // stack slot that is about to be copied and overwritten. Callers
        // must invoke `ensurePumpStarted(&service)` once the Service value
        // is in its final (stable) memory location.
        return .{
            .alloc = alloc,
            .proxies = proxy_streams.Manager.init(alloc),
            .registry = session_registry.Registry.init(alloc),
            .runtimes = RuntimeMap.init(alloc),
            .workspace_reg = workspace_registry.Registry.init(alloc),
            .command_queue = service_command.Queue.init(alloc),
        };
    }

    /// Open the persistence DB at `path` and hydrate the workspace registry
    /// from it. Must be called with `self` at its final memory location (it
    /// stores the DB handle in the struct). Idempotent: re-opening an
    /// already-attached DB is a no-op.
    pub fn attachDb(self: *Service, path: []const u8) !void {
        if (self.db != null) return;
        self.db = try persistence.Db.open(self.alloc, path);
        workspace_persistence.hydrateRegistry(&self.db.?, &self.workspace_reg, self.alloc) catch |err| {
            std.log.warn("session_service: hydrate from db failed: {s}", .{@errorName(err)});
        };
    }

    /// Save the current workspace registry to the persistence DB. Called
    /// after every mutation in server_core. No-op if no DB is attached.
    /// Routed through the writer thread: the DB is single-writer-owned
    /// now, so callers see a clean synchronous signature but internally
    /// the write is serialized with all other DB touches.
    pub fn persistWorkspaces(self: *Service) void {
        if (self.shouldRunWriterCommandDirectly()) {
            self.persistWorkspacesImpl();
            return;
        }
        var reply: service_command.PendingReply(void) = .{};
        self.command_queue.submit(.{ .persist_workspaces = .{ .reply = &reply } }) catch return;
        reply.wait() catch {};
    }

    pub fn persistWorkspacesAsync(self: *Service) void {
        if (self.shouldRunWriterCommandDirectly()) {
            self.persistWorkspacesImpl();
            return;
        }
        self.command_queue.submit(.{ .persist_workspaces = .{} }) catch {};
    }

    fn persistWorkspacesImpl(self: *Service) void {
        const db_ref = &(self.db orelse return);
        workspace_persistence.saveRegistry(db_ref, &self.workspace_reg, self.alloc) catch |err| {
            std.log.warn("session_service: persist failed: {s}", .{@errorName(err)});
        };
    }

    /// Append a workspace lifecycle event to the history log. Called from
    /// mutation handlers (created/renamed/closed/pane_split/…). Payload is
    /// an arbitrary JSON fragment; caller is responsible for ensuring it
    /// parses as valid JSON. No-op if no DB is attached.
    pub fn appendHistory(self: *Service, workspace_id: []const u8, event_type: []const u8, payload_json: []const u8) void {
        if (self.shouldRunWriterCommandDirectly()) {
            self.appendHistoryImpl(workspace_id, event_type, payload_json);
            return;
        }
        var reply: service_command.PendingReply(void) = .{};
        self.command_queue.submit(.{ .append_history = .{
            .workspace_id = workspace_id,
            .event_type = event_type,
            .payload_json = payload_json,
            .reply = &reply,
        } }) catch return;
        reply.wait() catch {};
    }

    fn appendHistoryImpl(self: *Service, workspace_id: []const u8, event_type: []const u8, payload_json: []const u8) void {
        const db_ref = &(self.db orelse return);
        persistence.appendHistory(db_ref, .{
            .workspace_id = workspace_id,
            .event_type = event_type,
            .payload_json = payload_json,
            .at = std.time.milliTimestamp(),
        }) catch |err| {
            std.log.warn("session_service: appendHistory failed: {s}", .{@errorName(err)});
        };
    }

    /// Query the workspace history log. Routed through the writer
    /// thread. Caller owns the returned `HistoryList` and must call
    /// `deinit` when done.
    pub fn historyQuery(self: *Service, workspace_id: ?[]const u8, limit: u32, before_seq: ?i64) !persistence.HistoryList {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.historyQueryImpl(workspace_id, limit, before_seq);
        }
        var reply: service_command.PendingReply(persistence.HistoryList) = .{};
        try self.command_queue.submit(.{ .history_query = .{
            .workspace_id = workspace_id,
            .limit = limit,
            .before_seq = before_seq,
            .reply = &reply,
        } });
        return reply.wait();
    }

    fn historyQueryImpl(self: *Service, workspace_id: ?[]const u8, limit: u32, before_seq: ?i64) !persistence.HistoryList {
        const db_ref = &(self.db orelse return error.PersistenceNotEnabled);
        return persistence.queryHistory(db_ref, self.alloc, .{
            .workspace_id = workspace_id,
            .limit = limit,
            .before_seq = before_seq,
        });
    }

    /// Clear the workspace history log. Routed through the writer thread.
    pub fn historyClear(self: *Service) !void {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.historyClearImpl();
        }
        var reply: service_command.PendingReply(void) = .{};
        try self.command_queue.submit(.{ .history_clear = .{ .reply = &reply } });
        return reply.wait();
    }

    fn historyClearImpl(self: *Service) !void {
        const db_ref = &(self.db orelse return error.PersistenceNotEnabled);
        return persistence.clearHistory(db_ref);
    }

    // ========================================================================
    // Single-writer actor: scaffolding + first migrated methods.
    // ========================================================================

    /// Start the writer thread. Idempotent. Same pattern as
    /// `ensurePumpStarted` — called once per transport at daemon startup.
    pub fn ensureWriterStarted(self: *Service) void {
        self.writer_init_mutex.lock();
        defer self.writer_init_mutex.unlock();
        if (self.writer_started.load(.seq_cst)) return;
        self.writer_thread = std.Thread.spawn(.{}, serviceWriterRun, .{self}) catch |err| {
            std.log.warn("session_service: writer thread start failed: {s}", .{@errorName(err)});
            return;
        };
        self.writer_started.store(true, .seq_cst);
    }

    fn shouldRunWriterCommandDirectly(self: *Service) bool {
        if (self.isOnWriterThread()) return true;
        if (!self.writer_started.load(.seq_cst)) self.ensureWriterStarted();
        return !self.writer_started.load(.seq_cst);
    }

    /// Writer-thread main loop. Drains the command queue until shutdown
    /// is signaled and the queue is empty. Each command is processed
    /// synchronously: no other thread concurrently mutates Service
    /// state the command touches, by construction.
    fn serviceWriterRun(self: *Service) void {
        // Publish the writer's thread id so submit-and-wait shims can
        // detect re-entrancy and bypass the queue instead of deadlocking.
        self.writer_thread_id.store(std.Thread.getCurrentId(), .seq_cst);
        defer self.writer_thread_id.store(0, .seq_cst);
        while (self.command_queue.takeBlocking()) |cmd| {
            self.dispatchCommand(cmd);
        }
    }

    /// Are we currently executing on the writer thread? Used by
    /// submit-and-wait shims: if true, call the `*Impl` directly
    /// because the writer is us, and waiting for our own reply would
    /// deadlock.
    fn isOnWriterThread(self: *Service) bool {
        const wid = self.writer_thread_id.load(.seq_cst);
        if (wid == 0) return false;
        return wid == std.Thread.getCurrentId();
    }

    fn dispatchCommand(self: *Service, cmd: service_command.Command) void {
        switch (cmd) {
            .open_terminal => |c| {
                const res = self.openTerminalImpl(
                    c.maybe_session_id,
                    c.command,
                    c.cols,
                    c.rows,
                    c.options,
                ) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(.{
                    .status = res.status,
                    .attachment_id = res.attachment_id,
                    .offset = res.offset,
                });
            },
            .close_session => |c| {
                self.closeSessionImpl(c.session_id) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk({});
            },
            .attach_session => |c| {
                const res = self.attachSessionImpl(c.session_id, c.attachment_id, c.cols, c.rows) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .resize_session => |c| {
                const res = self.resizeSessionImpl(c.session_id, c.attachment_id, c.cols, c.rows) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .detach_session => |c| {
                const res = self.detachSessionImpl(c.session_id, c.attachment_id) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .session_status => |c| {
                const res = self.registry.status(c.session_id) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .list_sessions => |c| {
                const res = self.registry.list() catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .persist_workspaces => |c| {
                self.persistWorkspacesImpl();
                if (c.reply) |reply| reply.fulfillOk({});
            },
            .append_history => |c| {
                self.appendHistoryImpl(c.workspace_id, c.event_type, c.payload_json);
                c.reply.fulfillOk({});
            },
            .history_query => |c| {
                const res = self.historyQueryImpl(c.workspace_id, c.limit, c.before_seq) catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk(res);
            },
            .history_clear => |c| {
                self.historyClearImpl() catch |err| {
                    c.reply.fulfillErr(err);
                    return;
                };
                c.reply.fulfillOk({});
            },
            .unsubscribe_terminal => |c| {
                const stream: *std.net.Stream = @ptrCast(@alignCast(c.stream));
                const res = self.unsubscribeTerminalImpl(stream, c.session_id);
                c.reply.fulfillOk(res);
            },
            .unsubscribe_all_for_stream => |c| {
                const stream: *std.net.Stream = @ptrCast(@alignCast(c.stream));
                self.unsubscribeAllForStreamImpl(stream);
                c.reply.fulfillOk({});
            },
            .shutdown => {
                // Loop exit is handled by the queue returning null after
                // shutdown + drain. This variant is just an explicit
                // wake-up if a transport needs to force a check.
            },
        }
    }

    /// Start the kqueue PTY pump thread and wire up the notify trampoline.
    /// Safe to call multiple times; subsequent calls are no-ops. MUST be
    /// called with `self` at its final memory location — the pump thread
    /// and notify callback capture `self` by pointer.
    pub fn ensurePumpStarted(self: *Service) void {
        if (!pty_pump.supported) return;
        self.pump_init_mutex.lock();
        defer self.pump_init_mutex.unlock();
        if (self.pump != null) return;
        if (pty_pump.Pump.init(self.alloc)) |pump| {
            self.pump = pump;
            self.pump.?.start() catch |err| {
                std.log.warn("session_service: pump start failed: {s}", .{@errorName(err)});
                self.pump.?.deinit();
                self.pump = null;
                return;
            };
            self.pump.?.setNotify(self, pumpNotifyTrampoline);
        } else |err| {
            std.log.warn("session_service: kqueue pump unavailable: {s}", .{@errorName(err)});
        }
    }

    pub fn deinit(self: *Service) void {
        // Stop accepting new commands first. The writer drains its queue
        // and exits, after which no other thread can submit work that
        // would mutate Service state during teardown.
        if (self.writer_started.load(.seq_cst)) {
            self.command_queue.signalShutdown();
            if (self.writer_thread) |t| t.join();
            self.writer_thread = null;
            self.writer_started.store(false, .seq_cst);
        }
        self.command_queue.deinit();

        // Stop the pump first so it cannot touch sessions or subscriptions
        // while we tear them down. The pump is the only producer of new
        // remote-push jobs.
        if (self.pump) |*pump| pump.deinit();
        self.pump = null;

        // Wait for any in-flight remote-push dispatcher threads to finish
        // so they never read the config/allocator after we free them.
        self.push_shutting_down.store(true, .seq_cst);
        self.push_cv_mutex.lock();
        while (self.push_inflight.load(.seq_cst) > 0) {
            self.push_cv.wait(&self.push_cv_mutex);
        }
        self.push_cv_mutex.unlock();

        self.freeRemoteConfigLocked();

        self.sub_mutex.lock();
        for (self.terminal_subs.items) |sub| {
            if (sub.owned_session_id) |k| self.alloc.free(k);
            self.alloc.destroy(sub);
        }
        self.terminal_subs.deinit(self.alloc);
        self.sub_mutex.unlock();

        // All worker threads have been joined by this point; iterate
        // through the unsafe inner ptr to free per-entry resources.
        const inner = self.runtimes.unsafeInnerForTeardown();
        var iter = inner.iterator();
        while (iter.next()) |runtime| {
            self.alloc.free(runtime.key_ptr.*);
            runtime.value_ptr.*.deinit();
            self.alloc.destroy(runtime.value_ptr.*);
        }
        self.runtimes.deinit();
        self.proxies.deinit();
        self.registry.deinit();
        self.workspace_reg.deinit();
        self.subscriptions.deinit(self.alloc);
        if (self.db) |*db| db.close();
    }

    /// Frees the currently-stored remote notification config and resets it
    /// back to the empty state. Must be called with `notifications_lock`
    /// held OR while no other thread could be reading it (deinit, or a
    /// replace-under-lock path).
    fn freeRemoteConfigLocked(self: *Service) void {
        const cfg = &self.remote_notifications;
        // The initial default uses "" literals and an empty static slice;
        // those aren't allocator-owned but Allocator.free on a zero-length
        // slice is a no-op, so we only need to guard each inner free.
        if (cfg.endpoint.len > 0) self.alloc.free(cfg.endpoint);
        if (cfg.bearer_token.len > 0) self.alloc.free(cfg.bearer_token);
        if (cfg.device_tokens.len > 0) {
            for (cfg.device_tokens) |t| {
                if (t.len > 0) self.alloc.free(t);
            }
            self.alloc.free(cfg.device_tokens);
        }
        cfg.* = .{};
    }

    /// Replace the remote notification config. Internally dupes every
    /// slice so the caller can release / reuse its input buffers. Passing
    /// an empty `endpoint` ("") disables remote pushes entirely; passing
    /// a non-empty endpoint but an empty `device_tokens` slice disables
    /// pushes while retaining the endpoint/token strings (the next
    /// `configureNotifications` call can restore tokens without needing
    /// to send the endpoint again).
    pub fn configureNotifications(
        self: *Service,
        endpoint: []const u8,
        bearer_token: []const u8,
        device_tokens: []const []const u8,
    ) !void {
        const owned_endpoint = try self.alloc.dupe(u8, endpoint);
        errdefer self.alloc.free(owned_endpoint);

        const owned_bearer = try self.alloc.dupe(u8, bearer_token);
        errdefer self.alloc.free(owned_bearer);

        const owned_tokens = try self.alloc.alloc([]const u8, device_tokens.len);
        errdefer self.alloc.free(owned_tokens);

        var allocated: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < allocated) : (i += 1) self.alloc.free(owned_tokens[i]);
        }
        for (device_tokens) |tok| {
            owned_tokens[allocated] = try self.alloc.dupe(u8, tok);
            allocated += 1;
        }

        self.notifications_lock.lock();
        defer self.notifications_lock.unlock();
        self.freeRemoteConfigLocked();
        self.remote_notifications = .{
            .endpoint = owned_endpoint,
            .bearer_token = owned_bearer,
            .device_tokens = owned_tokens,
        };
    }

    pub fn openProxy(self: *Service, host: []const u8, port: u16) ![]const u8 {
        return self.proxies.open(host, port);
    }

    pub fn closeProxy(self: *Service, stream_id: []const u8) !void {
        try self.proxies.close(stream_id);
    }

    pub fn writeProxy(self: *Service, stream_id: []const u8, payload: []const u8) !usize {
        return self.proxies.write(stream_id, payload);
    }

    pub fn readProxy(self: *Service, stream_id: []const u8, max_bytes: usize, timeout_ms: i32) !proxy_streams.ReadResult {
        return self.proxies.read(self.alloc, stream_id, max_bytes, timeout_ms);
    }

    pub fn openSession(self: *Service, maybe_session_id: ?[]const u8) !session_registry.SessionStatus {
        const session_id = try self.registry.ensure(maybe_session_id);
        defer self.alloc.free(session_id);
        return self.registry.status(session_id);
    }

    /// Close a session. Routed through the writer thread so it never
    /// races with openTerminal or other mutators of runtimes/registry.
    pub fn closeSession(self: *Service, session_id: []const u8) !void {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.closeSessionImpl(session_id);
        }
        var reply: service_command.PendingReply(void) = .{};
        try self.command_queue.submit(.{ .close_session = .{
            .session_id = session_id,
            .reply = &reply,
        } });
        return reply.wait();
    }

    fn closeSessionImpl(self: *Service, session_id: []const u8) !void {
        try self.registry.close(session_id);
        self.removeRuntime(session_id);
    }

    /// Attach a client to an existing session. Routed through the
    /// writer thread so it cannot race with openTerminal/closeSession
    /// or other mutators.
    pub fn attachSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.attachSessionImpl(session_id, attachment_id, cols, rows);
        }
        var reply: service_command.PendingReply(session_registry.SessionStatus) = .{};
        try self.command_queue.submit(.{ .attach_session = .{
            .session_id = session_id,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
            .reply = &reply,
        } });
        return reply.wait();
    }

    fn attachSessionImpl(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.attach(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        self.broadcastViewSize(status.session_id, status.effective_cols, status.effective_rows, status.grid_generation);
        return status;
    }

    /// Resize an existing session. Routed through the writer thread.
    pub fn resizeSession(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.resizeSessionImpl(session_id, attachment_id, cols, rows);
        }
        var reply: service_command.PendingReply(session_registry.SessionStatus) = .{};
        try self.command_queue.submit(.{ .resize_session = .{
            .session_id = session_id,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
            .reply = &reply,
        } });
        return reply.wait();
    }

    fn resizeSessionImpl(self: *Service, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !session_registry.SessionStatus {
        try self.registry.resize(session_id, attachment_id, cols, rows);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        // Per-runtime dedup/rate-limit for TIOCSWINSZ lives inside
        // `resizeRuntimeIfPresent` (atomic last_resize_dims + timestamp
        // on each `RuntimeSession`). No shared hashmap — replaces the
        // removed daemon-wide debouncer that was the bug factory.
        try self.resizeRuntimeIfPresent(&status);
        self.broadcastViewSize(status.session_id, status.effective_cols, status.effective_rows, status.grid_generation);
        return status;
    }

    /// Detach a client from a session. Routed through the writer thread.
    pub fn detachSession(self: *Service, session_id: []const u8, attachment_id: []const u8) !session_registry.SessionStatus {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.detachSessionImpl(session_id, attachment_id);
        }
        var reply: service_command.PendingReply(session_registry.SessionStatus) = .{};
        try self.command_queue.submit(.{ .detach_session = .{
            .session_id = session_id,
            .attachment_id = attachment_id,
            .reply = &reply,
        } });
        return reply.wait();
    }

    pub fn detachSessionIfPresent(self: *Service, session_id: []const u8, attachment_id: []const u8) void {
        var status = self.detachSession(session_id, attachment_id) catch return;
        status.deinit(self.alloc);
    }

    fn detachSessionImpl(self: *Service, session_id: []const u8, attachment_id: []const u8) !session_registry.SessionStatus {
        try self.registry.detach(session_id, attachment_id);
        var status = try self.registry.status(session_id);
        errdefer status.deinit(self.alloc);
        try self.resizeRuntimeIfPresent(&status);
        self.broadcastViewSize(status.session_id, status.effective_cols, status.effective_rows, status.grid_generation);
        return status;
    }

    pub fn sessionStatus(self: *Service, session_id: []const u8) !session_registry.SessionStatus {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.registry.status(session_id);
        }
        var reply: service_command.PendingReply(session_registry.SessionStatus) = .{};
        try self.command_queue.submit(.{ .session_status = .{
            .session_id = session_id,
            .reply = &reply,
        } });
        return reply.wait();
    }

    pub fn listSessions(self: *Service) ![]session_registry.SessionListEntry {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.registry.list();
        }
        var reply: service_command.PendingReply([]session_registry.SessionListEntry) = .{};
        try self.command_queue.submit(.{ .list_sessions = .{
            .reply = &reply,
        } });
        return reply.wait();
    }

    /// Open a new terminal. Routed through the writer thread so it
    /// never races with closeSession or other mutators of
    /// runtimes/registry. Caller gets back the same `OpenTerminalResult`
    /// as before; ownership of `attachment_id` transfers through the
    /// reply unchanged.
    pub fn openTerminal(self: *Service, maybe_session_id: ?[]const u8, command: []const u8, cols: u16, rows: u16) !OpenTerminalResult {
        return self.openTerminalWithOptions(maybe_session_id, command, cols, rows, .{});
    }

    pub fn openTerminalWithOptions(
        self: *Service,
        maybe_session_id: ?[]const u8,
        command: []const u8,
        cols: u16,
        rows: u16,
        open_options: session_registry.Registry.OpenOptions,
    ) !OpenTerminalResult {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.openTerminalImpl(maybe_session_id, command, cols, rows, open_options);
        }
        var reply: service_command.PendingReply(service_command.OpenTerminalResult) = .{};
        try self.command_queue.submit(.{ .open_terminal = .{
            .maybe_session_id = maybe_session_id,
            .command = command,
            .cols = cols,
            .rows = rows,
            .options = open_options,
            .reply = &reply,
        } });
        const actor_res = try reply.wait();
        return .{
            .status = actor_res.status,
            .attachment_id = actor_res.attachment_id,
            .offset = actor_res.offset,
        };
    }

    fn openTerminalImpl(
        self: *Service,
        maybe_session_id: ?[]const u8,
        command: []const u8,
        cols: u16,
        rows: u16,
        open_options: session_registry.Registry.OpenOptions,
    ) !OpenTerminalResult {
        const opened = try self.registry.openWithOptions(maybe_session_id, cols, rows, open_options);
        errdefer {
            self.registry.close(opened.session_id) catch {};
            self.alloc.free(opened.session_id);
            self.alloc.free(opened.attachment_id);
        }

        var status = try self.registry.status(opened.session_id);
        errdefer status.deinit(self.alloc);

        const runtime = try self.alloc.create(RuntimeSession);
        errdefer self.alloc.destroy(runtime);
        runtime.* = try RuntimeSession.init(self.alloc, command, status.effective_cols, status.effective_rows);
        errdefer runtime.deinit();

        try self.runtimes.put(opened.session_id, runtime);
        // After a successful put, the runtime must be findable by its id.
        // Catches regressions where the map's locking or key-ownership
        // contract silently breaks.
        std.debug.assert(self.runtimes.contains(opened.session_id));

        // Register PTY master fd with the kqueue pump so output drains
        // proactively even when no client is calling terminal.read.
        if (self.pump) |*pump| {
            const entry: pty_pump.Entry = .{
                .pty = &runtime.pty,
                .terminal = &runtime.terminal,
                .lock = &runtime.lock,
                .session_id = opened.session_id,
                .in_flight = &runtime.pump_in_flight,
            };
            pump.register(runtime.pty.master_fd, entry) catch |err| {
                std.log.warn("session_service: pump.register failed: {s}", .{@errorName(err)});
            };
        }

        return .{
            .status = status,
            .attachment_id = opened.attachment_id,
            .offset = 0,
        };
    }

    /// Transport-safe runtime lookup. Increments the runtime's `users`
    /// refcount atomically with the map lookup (under the map's shared
    /// lock) so a concurrent `removeRuntime` on the writer thread cannot
    /// free the pointee between lookup and use. Caller MUST call
    /// `runtime.release()` exactly once when done. Returns null if the
    /// session does not exist.
    ///
    /// Writer-thread paths (actor-routed methods) should keep using
    /// `runtimes.get` directly; they are serialized against removal so
    /// the refcount is unnecessary.
    fn acquireRuntime(self: *Service, session_id: []const u8) ?*RuntimeSession {
        const Ctx = struct {
            sid: []const u8,
            result: ?*RuntimeSession = null,
        };
        var ctx = Ctx{ .sid = session_id };
        self.runtimes.withSharedLock(&ctx, struct {
            fn run(inner: *RuntimeMap.Inner, c: *Ctx) void {
                if (inner.get(c.sid)) |rt| {
                    rt.users.retain();
                    c.result = rt;
                }
            }
        }.run);
        return ctx.result;
    }

    pub fn readTerminal(self: *Service, session_id: []const u8, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadTerminalResult {
        const runtime = self.acquireRuntime(session_id) orelse return error.TerminalSessionNotFound;
        defer runtime.release();
        return runtime.read(self.alloc, offset, max_bytes, timeout_ms);
    }

    pub fn writeTerminal(self: *Service, session_id: []const u8, data: []const u8, write_id: ?[]const u8) !usize {
        const runtime = self.acquireRuntime(session_id) orelse return error.TerminalSessionNotFound;
        defer runtime.release();
        try runtime.writeDraining(write_id, data);
        return data.len;
    }

    pub fn history(self: *Service, session_id: []const u8, format: serialize.HistoryFormat) !TerminalHistorySnapshot {
        const runtime = self.acquireRuntime(session_id) orelse return error.TerminalSessionNotFound;
        defer runtime.release();
        return runtime.historyDump(self.alloc, format);
    }

    fn resizeRuntimeIfPresent(self: *Service, status: *const session_registry.SessionStatus) !void {
        // Skip the PTY resize if we don't have a real size yet. This avoids
        // spurious ResizeFailed errors during the bootstrap/restore window
        // when an attachment exists but hasn't reported geometry.
        if (status.effective_cols == 0 or status.effective_rows == 0) return;
        const runtime = self.runtimes.get(status.session_id) orelse return;

        // Dedupe: if cols+rows match the last ioctl we fired, do nothing.
        // During a rapid drag the mac bounces through many intermediate
        // sizes; the daemon frequently receives the same (cols, rows)
        // twice in a row because the mac's pin can flip-flop between
        // two neighboring values. Skipping identical resizes avoids
        // needless SIGWINCHes without dropping any user-visible change.
        const packed_dims: u32 = (@as(u32, status.effective_cols) << 16) | @as(u32, status.effective_rows);
        if (runtime.last_resize_dims.load(.seq_cst) == packed_dims) return;

        try runtime.resize(status.effective_cols, status.effective_rows);
        runtime.last_resize_dims.store(packed_dims, .seq_cst);
    }

    fn removeRuntime(self: *Service, session_id: []const u8) void {
        const entry = self.runtimes.fetchRemove(session_id) orelse return;
        if (self.pump) |*pump| pump.unregister(entry.value.pty.master_fd);
        // Drop any subscriptions pointing at this session_id so their
        // borrowed `session_id` pointer doesn't outlive the hashmap key.
        self.removeSubscriptionsBySessionId(entry.key);
        // Wait for any transport thread that acquired this runtime via
        // `acquireRuntime` before the map removal committed to release its
        // refcount. The map's RwLock guarantees that acquireRuntime either ran
        // entirely before fetchRemove (incremented users; we wait) or entirely
        // after (lookup returned null; no ref taken).
        entry.value.users.waitUntilZero();
        self.alloc.free(entry.key);
        entry.value.deinit();
        self.alloc.destroy(entry.value);
    }

    /// Atomically: snapshot bytes from `requested_offset` (default = current
    /// next_offset, i.e. no replay) and register `stream` for push events.
    /// Subsequent PTY output is delivered via the `terminal.output` event.
    pub fn subscribeTerminal(
        self: *Service,
        stream: *std.net.Stream,
        stream_lock: *std.Thread.Mutex,
        session_id: []const u8,
        requested_offset: ?u64,
    ) !SubscribeSnapshot {
        return self.subscribeTerminalQueued(stream, stream_lock, null, session_id, requested_offset);
    }

    /// Same as `subscribeTerminal` but routes pushes through a per-connection
    /// outbound queue (used by serve_unix; WS callers pass null).
    pub fn subscribeTerminalQueued(
        self: *Service,
        stream: *std.net.Stream,
        stream_lock: *std.Thread.Mutex,
        queue: ?*outbound_queue.OutboundQueue,
        session_id: []const u8,
        requested_offset: ?u64,
    ) !SubscribeSnapshot {
        const entry = try self.runtimes.getEntryDupedKey(self.alloc, session_id) orelse
            return error.TerminalSessionNotFound;
        errdefer self.alloc.free(entry.key);
        const runtime = entry.value;
        const canonical_session_id = entry.key;

        runtime.lock.lock();
        defer runtime.lock.unlock();

        // Best-effort: drain any pending bytes so the snapshot is fresh.
        runtime.pty.pump(&runtime.terminal) catch {};

        const window = runtime.terminal.offsetWindow();
        const start = requested_offset orelse window.next_offset;

        const max_bytes: usize = 256 * 1024;
        const raw = try runtime.terminal.readRaw(self.alloc, start, max_bytes);
        errdefer self.alloc.free(raw.data);

        const eof_now = runtime.pty.isClosed() and raw.offset >= window.next_offset;

        const sub = try self.alloc.create(TerminalSubscription);
        errdefer self.alloc.destroy(sub);
        // Invariant: subscription's `session_id` slice must be exactly
        // the `owned_session_id` allocation it just adopted. Anything
        // else means a future diff has broken the borrow→own transition
        // and is about to produce dangling pointers or double-frees.
        std.debug.assert(canonical_session_id.len > 0);
        sub.* = .{
            .session_id = canonical_session_id,
            .owned_session_id = canonical_session_id,
            .stream = stream,
            .stream_lock = stream_lock,
            .queue = queue,
            .last_offset = raw.offset,
            .seq = 0,
            .last_bell_count = runtime.terminal.bell_count,
            .last_command_seq = runtime.terminal.command_seq,
            .last_notification_seq = runtime.terminal.notification_seq,
        };

        self.sub_mutex.lock();
        self.terminal_subs.append(self.alloc, sub) catch |err| {
            self.sub_mutex.unlock();
            return err;
        };
        self.sub_mutex.unlock();

        // A new subscriber clears any "unread while idle" marker.
        const was_unread = runtime.has_unread_output.swap(false, .seq_cst);
        if (was_unread) self.fireWorkspaceChanged();

        return .{
            .data = raw.data,
            .offset = raw.offset,
            .base_offset = raw.base_offset,
            .truncated = raw.truncated,
            .eof = eof_now,
            .seq = 0,
        };
    }

    /// Clear the has_unread_output flag for `session_id`. Returns true iff
    /// the session exists. Fires on_workspace_changed when the flag
    /// transitioned from true to false so subscribers see the update.
    pub fn markRead(self: *Service, session_id: []const u8) bool {
        const runtime = self.acquireRuntime(session_id) orelse return false;
        defer runtime.release();
        const was = runtime.has_unread_output.swap(false, .seq_cst);
        if (was) self.fireWorkspaceChanged();
        return true;
    }

    /// Lock-free read of a session's has_unread_output flag. Returns false
    /// when the session is unknown.
    pub fn hasUnread(self: *Service, session_id: []const u8) bool {
        const runtime = self.acquireRuntime(session_id) orelse return false;
        defer runtime.release();
        return runtime.has_unread_output.load(.seq_cst);
    }

    /// Live count of registered terminal subscribers for a session. Useful
    /// as a deterministic readiness/quiescence signal in tests — callers
    /// can poll for this to drop to zero after a disconnect instead of
    /// sleeping a best-effort interval.
    pub fn subscriberCount(self: *Service, session_id: []const u8) usize {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        var count: usize = 0;
        for (self.terminal_subs.items) |sub| {
            if (sub.dead.load(.seq_cst)) continue;
            if (std.mem.eql(u8, sub.session_id, session_id)) count += 1;
        }
        return count;
    }

    fn fireWorkspaceChanged(self: *Service) void {
        if (self.on_workspace_changed) |cb| cb(self);
    }

    /// Remove one subscription. Routed through the writer thread so
    /// mutations to `terminal_subs` serialize with other lifecycle
    /// events (close_session's `removeSubscriptionsBySessionId`, the
    /// other subscriber routines). `sub_mutex` still guards the list
    /// against concurrent reads from the pump thread (which is not
    /// migrated — hot path).
    pub fn unsubscribeTerminal(
        self: *Service,
        stream: *std.net.Stream,
        session_id: []const u8,
    ) bool {
        if (self.shouldRunWriterCommandDirectly()) {
            return self.unsubscribeTerminalImpl(stream, session_id);
        }
        var reply: service_command.PendingReply(bool) = .{};
        self.command_queue.submit(.{ .unsubscribe_terminal = .{
            .stream = @ptrCast(stream),
            .session_id = session_id,
            .reply = &reply,
        } }) catch return false;
        return reply.wait() catch false;
    }

    fn unsubscribeTerminalImpl(
        self: *Service,
        stream: *std.net.Stream,
        session_id: []const u8,
    ) bool {
        var target: ?*TerminalSubscription = null;
        self.sub_mutex.lock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) : (i += 1) {
            const s = self.terminal_subs.items[i];
            if (s.stream == stream and std.mem.eql(u8, s.session_id, session_id)) {
                s.dead.store(true, .seq_cst);
                _ = self.terminal_subs.orderedRemove(i);
                target = s;
                break;
            }
        }
        self.sub_mutex.unlock();
        if (target) |s| {
            waitUntilQuiescent(s);
            if (s.owned_session_id) |k| self.alloc.free(k);
            self.alloc.destroy(s);
            return true;
        }
        return false;
    }

    /// Called by the WS handler when a connection closes. Routed
    /// through the writer thread.
    pub fn unsubscribeAllForStream(self: *Service, stream: *std.net.Stream) void {
        if (self.shouldRunWriterCommandDirectly()) {
            self.unsubscribeAllForStreamImpl(stream);
            return;
        }
        var reply: service_command.PendingReply(void) = .{};
        self.command_queue.submit(.{ .unsubscribe_all_for_stream = .{
            .stream = @ptrCast(stream),
            .reply = &reply,
        } }) catch return;
        reply.wait() catch {};
    }

    fn unsubscribeAllForStreamImpl(self: *Service, stream: *std.net.Stream) void {
        var collected: std.ArrayListUnmanaged(*TerminalSubscription) = .empty;
        defer collected.deinit(self.alloc);

        self.sub_mutex.lock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) {
            const s = self.terminal_subs.items[i];
            if (s.stream == stream) {
                s.dead.store(true, .seq_cst);
                _ = self.terminal_subs.orderedRemove(i);
                collected.append(self.alloc, s) catch {};
            } else i += 1;
        }
        self.sub_mutex.unlock();

        for (collected.items) |s| {
            waitUntilQuiescent(s);
            if (s.owned_session_id) |k| self.alloc.free(k);
            self.alloc.destroy(s);
        }
    }

    fn removeSubscriptionsBySessionId(self: *Service, session_id: []const u8) void {
        var collected: std.ArrayListUnmanaged(*TerminalSubscription) = .empty;
        defer collected.deinit(self.alloc);

        self.sub_mutex.lock();
        var i: usize = 0;
        while (i < self.terminal_subs.items.len) {
            const s = self.terminal_subs.items[i];
            if (std.mem.eql(u8, s.session_id, session_id)) {
                s.dead.store(true, .seq_cst);
                _ = self.terminal_subs.orderedRemove(i);
                collected.append(self.alloc, s) catch {};
            } else i += 1;
        }
        self.sub_mutex.unlock();

        for (collected.items) |s| {
            waitUntilQuiescent(s);
            if (s.owned_session_id) |k| self.alloc.free(k);
            self.alloc.destroy(s);
        }
    }

    fn pumpNotifyTrampoline(ctx: ?*anyopaque, entry: pty_pump.Entry) void {
        const self: *Service = @ptrCast(@alignCast(ctx orelse return));
        self.pump_notify_thread_id.store(std.Thread.getCurrentId(), .seq_cst);
        defer self.pump_notify_thread_id.store(0, .seq_cst);
        self.deliverTerminalPushes(entry);
    }

    pub fn isOnPumpNotifyThread(self: *Service) bool {
        const tid = self.pump_notify_thread_id.load(.seq_cst);
        if (tid == 0) return false;
        return tid == std.Thread.getCurrentId();
    }

    fn deliverTerminalPushes(self: *Service, entry: pty_pump.Entry) void {
        // Snapshot matching subscriber pointers so we don't hold sub_mutex
        // across PTY/terminal locking and network writes. Each snapshot
        // bumps the sub's `in_flight` counter while `sub_mutex` is held;
        // the per-sub loop below decrements it. Unsubscribe waits for
        // that counter to hit zero before freeing the allocation, so
        // the pointer we carry across the sub_mutex release can never
        // dangle.
        var matching: std.ArrayListUnmanaged(*TerminalSubscription) = .empty;
        defer matching.deinit(self.alloc);

        self.sub_mutex.lock();
        for (self.terminal_subs.items) |sub| {
            if (sub.dead.load(.seq_cst)) continue;
            if (std.mem.eql(u8, sub.session_id, entry.session_id)) {
                matching.append(self.alloc, sub) catch break;
                sub.retainForPush();
            }
        }
        self.sub_mutex.unlock();

        if (matching.items.len == 0) {
            // No live subscriber for this session: mark unread so the next
            // workspace.list / workspace.changed reflects it. Notify only on
            // the false→true transition to avoid spamming change events.
            if (self.runtimes.get(entry.session_id)) |runtime| {
                const was = runtime.has_unread_output.swap(true, .seq_cst);
                if (!was) self.fireWorkspaceChanged();
            }
            // If a remote endpoint is configured and an actual notification
            // event fired (bell / command_finished / OSC 99), dispatch an
            // APNs push so the owner still learns about this session.
            self.maybePushRemoteNotification(entry);
            return;
        }

        for (matching.items) |sub| {
            defer sub.releasePush();
            if (sub.dead.load(.seq_cst)) continue;
            self.pushOneSubscriber(entry, sub) catch {
                sub.dead.store(true, .seq_cst);
            };
        }
    }

    /// Wait for a retiring subscription's `in_flight` counter to drop to
    /// zero. Called by `unsubscribeTerminal` and friends after removing the
    /// sub from `terminal_subs` (so no new push can see it) and before
    /// freeing the allocation. Free-standing (not a method on Service)
    /// because it does not need the service itself.
    fn waitUntilQuiescent(sub: *TerminalSubscription) void {
        sub.in_flight_mutex.lock();
        defer sub.in_flight_mutex.unlock();
        while (sub.in_flight > 0) {
            sub.in_flight_cv.wait(&sub.in_flight_mutex);
        }
    }

    /// Fan out a `session.view_size` event to every live subscriber of
    /// `session_id`. This is the AUTHORITATIVE rendering grid — clients
    /// render at exactly these cols × rows and letterbox any remaining
    /// container area. Called from every attach/resize/detach/open path
    /// whether or not the value actually changed, so late-joining clients
    /// and clients that missed a prior broadcast always converge to the
    /// current truth on their next size-relevant RPC. Uses the same
    /// in_flight + snapshot pattern as `deliverTerminalPushes` so an
    /// unsubscribe racing with this broadcast cannot free a sub we're
    /// still writing to. Wire format:
    ///   {"event":"session.view_size","session_id":"...",
    ///    "cols":N,"rows":M,"grid_generation":G}
    fn broadcastViewSize(
        self: *Service,
        session_id: []const u8,
        cols: u16,
        rows: u16,
        grid_generation: u64,
    ) void {
        var matching: std.ArrayListUnmanaged(*TerminalSubscription) = .empty;
        defer matching.deinit(self.alloc);

        self.sub_mutex.lock();
        for (self.terminal_subs.items) |sub| {
            if (sub.dead.load(.seq_cst)) continue;
            if (std.mem.eql(u8, sub.session_id, session_id)) {
                matching.append(self.alloc, sub) catch break;
                sub.retainForPush();
            }
        }
        self.sub_mutex.unlock();

        if (matching.items.len == 0) return;

        const event = json_rpc.encodeResponse(self.alloc, .{
            .event = "session.view_size",
            .session_id = session_id,
            .cols = cols,
            .rows = rows,
            .grid_generation = grid_generation,
        }) catch {
            for (matching.items) |sub| sub.releasePush();
            return;
        };
        defer self.alloc.free(event);

        for (matching.items) |sub| {
            defer sub.releasePush();
            if (sub.dead.load(.seq_cst)) continue;
            self.sendControlFrame(sub, event) catch {
                sub.dead.store(true, .seq_cst);
            };
        }
    }

    /// Shared write path for small control-plane events (like
    /// `session.size_changed`). Mirrors the tail of `pushOneSubscriber`:
    /// routes through the per-connection `OutboundQueue` when present,
    /// falling back to a direct WS-framed write under `stream_lock`.
    /// `event` is borrowed; the queue path copies it.
    fn sendControlFrame(
        self: *Service,
        sub: *TerminalSubscription,
        event: []const u8,
    ) !void {
        if (sub.queue) |q| {
            const line = try self.alloc.alloc(u8, event.len + 1);
            @memcpy(line[0..event.len], event);
            line[event.len] = '\n';
            q.enqueueControl(line) catch |err| {
                self.alloc.free(line);
                return err;
            };
            return;
        }
        sub.stream_lock.lock();
        defer sub.stream_lock.unlock();
        try sendWsTextFrame(sub.stream, event);
    }

    /// Called from the pump's notify callback when a session just pumped
    /// and has no live subscribers. Dispatches a remote APNs push if the
    /// stored config is non-empty AND a notification-relevant counter
    /// advanced since the last remote push.
    fn maybePushRemoteNotification(self: *Service, entry: pty_pump.Entry) void {
        if (self.push_shutting_down.load(.seq_cst)) return;
        const runtime = self.runtimes.get(entry.session_id) orelse return;

        // Snapshot terminal state + advance per-session remote counters
        // atomically under the runtime lock.
        entry.lock.lock();
        const cur_bell = entry.terminal.bell_count;
        const cur_cmd_seq = entry.terminal.command_seq;
        const cur_notif_seq = entry.terminal.notification_seq;

        const new_bell = cur_bell != runtime.last_remote_bell_count;
        const new_command = cur_cmd_seq != runtime.last_remote_command_seq;
        const new_notification = cur_notif_seq != runtime.last_remote_notification_seq;

        if (!new_bell and !new_command and !new_notification) {
            entry.lock.unlock();
            return;
        }

        const exit_code_snapshot: ?i32 = if (new_command) entry.terminal.last_command_exit_code else null;
        var notif_title_copy: ?[]u8 = null;
        var notif_body_copy: ?[]u8 = null;
        if (new_notification) {
            if (entry.terminal.last_notification) |n| {
                if (n.title) |t| notif_title_copy = self.alloc.dupe(u8, t) catch null;
                if (n.body) |b| notif_body_copy = self.alloc.dupe(u8, b) catch null;
            }
        }

        runtime.last_remote_bell_count = cur_bell;
        runtime.last_remote_command_seq = cur_cmd_seq;
        runtime.last_remote_notification_seq = cur_notif_seq;
        entry.lock.unlock();

        // Must free any borrowed title/body copies if we bail early.
        var free_title: bool = true;
        var free_body: bool = true;
        defer if (free_title) {
            if (notif_title_copy) |t| self.alloc.free(t);
        };
        defer if (free_body) {
            if (notif_body_copy) |b| self.alloc.free(b);
        };

        // Build the push job via a fallible inner helper so we can use
        // `errdefer` for cleanup. The wrapper translates any allocation
        // failure into a silent drop — we already advanced the remote
        // counters, so we won't re-dispatch the same event.
        const maybe_job = self.buildPushJob(
            entry.session_id,
            new_bell,
            new_command,
            exit_code_snapshot,
            new_notification,
            notif_title_copy,
            notif_body_copy,
        ) catch |err| {
            std.log.warn(
                "session_service: build push job failed for {s}: {s}",
                .{ entry.session_id, @errorName(err) },
            );
            return;
        };
        const job = maybe_job orelse return;
        // Ownership of title/body has been transferred into the job.
        free_title = false;
        free_body = false;

        // Increment the in-flight counter BEFORE spawn. If spawn fails,
        // decrement and drop. `pushDispatchEntry` decrements+signals on
        // completion so `deinit` can wait us out.
        _ = self.push_inflight.fetchAdd(1, .seq_cst);
        const thread = std.Thread.spawn(.{}, pushDispatchEntry, .{job}) catch {
            _ = self.push_inflight.fetchSub(1, .seq_cst);
            self.pushCvBroadcast();
            freePushJob(job);
            return;
        };
        thread.detach();
    }

    /// Snapshot the remote notification config + session identity into an
    /// owned `PushJob` that the dispatcher thread can consume. Returns
    /// null when the config is currently empty (callers treat that as a
    /// "nothing to do" result, not an error). Any allocation failure
    /// along the way propagates and is logged by the caller.
    fn buildPushJob(
        self: *Service,
        session_id: []const u8,
        bell: bool,
        command_finished: bool,
        exit_code: ?i32,
        notification_present: bool,
        notif_title_in: ?[]u8,
        notif_body_in: ?[]u8,
    ) !?*PushJob {
        self.notifications_lock.lock();
        defer self.notifications_lock.unlock();

        const cfg = self.remote_notifications;
        if (cfg.endpoint.len == 0 or cfg.device_tokens.len == 0) return null;

        const endpoint_copy = try self.alloc.dupe(u8, cfg.endpoint);
        errdefer self.alloc.free(endpoint_copy);

        const bearer_copy = try self.alloc.dupe(u8, cfg.bearer_token);
        errdefer self.alloc.free(bearer_copy);

        const tokens_copy = try self.alloc.alloc([]u8, cfg.device_tokens.len);
        var tokens_filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < tokens_filled) : (i += 1) self.alloc.free(tokens_copy[i]);
            self.alloc.free(tokens_copy);
        }
        for (cfg.device_tokens) |tok| {
            tokens_copy[tokens_filled] = try self.alloc.dupe(u8, tok);
            tokens_filled += 1;
        }

        const session_id_copy = try self.alloc.dupe(u8, session_id);
        errdefer self.alloc.free(session_id_copy);

        const workspace_id_copy: ?[]u8 = self.findWorkspaceIdForSession(session_id);
        errdefer if (workspace_id_copy) |w| self.alloc.free(w);

        const job = try self.alloc.create(PushJob);
        job.* = .{
            .service = self,
            .endpoint = endpoint_copy,
            .bearer_token = bearer_copy,
            .device_tokens = tokens_copy,
            .session_id = session_id_copy,
            .workspace_id = workspace_id_copy,
            .bell = bell,
            .command_finished = command_finished,
            .exit_code = exit_code,
            .notification_present = notification_present,
            .notif_title = notif_title_in,
            .notif_body = notif_body_in,
        };
        return job;
    }

    fn pushCvBroadcast(self: *Service) void {
        self.push_cv_mutex.lock();
        self.push_cv.broadcast();
        self.push_cv_mutex.unlock();
    }

    /// Best-effort reverse lookup from `session_id` to the workspace that
    /// contains it. Returns a newly-allocated owned slice, or null if no
    /// workspace currently references the session (the daemon can still
    /// have a terminal without any workspace binding during bootstrap).
    fn findWorkspaceIdForSession(self: *Service, session_id: []const u8) ?[]u8 {
        const reg = &self.workspace_reg;
        var iter = reg.workspaces.iterator();
        while (iter.next()) |entry| {
            const ws = entry.value_ptr;
            const leaves = ws.root_pane.collectLeaves(self.alloc) catch continue;
            defer self.alloc.free(leaves);
            for (leaves) |leaf| {
                if (leaf.session_id) |sid| {
                    if (std.mem.eql(u8, sid, session_id)) {
                        return self.alloc.dupe(u8, ws.id) catch null;
                    }
                }
            }
        }
        return null;
    }

    fn pushOneSubscriber(self: *Service, entry: pty_pump.Entry, sub: *TerminalSubscription) !void {
        entry.lock.lock();
        const window = entry.terminal.offsetWindow();
        const eof_flag = entry.pty.isClosed();

        // Snapshot notification-related state under lock.
        const cur_bell = entry.terminal.bell_count;
        const cur_cmd_seq = entry.terminal.command_seq;
        const cur_notif_seq = entry.terminal.notification_seq;
        const new_bell = cur_bell != sub.last_bell_count;
        const new_command = cur_cmd_seq != sub.last_command_seq;
        const new_notification = cur_notif_seq != sub.last_notification_seq;

        const exit_code_snapshot: ?i32 = if (new_command) entry.terminal.last_command_exit_code else null;
        var notif_title: ?[]u8 = null;
        var notif_body: ?[]u8 = null;
        if (new_notification) {
            if (entry.terminal.last_notification) |n| {
                if (n.title) |t| notif_title = self.alloc.dupe(u8, t) catch null;
                if (n.body) |b| notif_body = self.alloc.dupe(u8, b) catch null;
            }
        }
        defer if (notif_title) |t| self.alloc.free(t);
        defer if (notif_body) |b| self.alloc.free(b);

        var start = sub.last_offset;
        var truncated = false;
        if (start < window.base_offset) {
            start = window.base_offset;
            truncated = true;
        }
        const has_new_bytes = start < window.next_offset;
        const has_new_notifications = new_bell or new_command or new_notification;
        // Emit exactly one eof=true push after the PTY closes and all
        // bytes have been delivered. Tracked via `sub.eof_sent` so
        // subsequent pumps don't spam empty eof frames.
        const eof_to_announce = eof_flag and !sub.eof_sent and start >= window.next_offset;

        if (!has_new_bytes and !has_new_notifications and !eof_to_announce) {
            entry.lock.unlock();
            return;
        }

        var raw_data_owned: ?[]u8 = null;
        var raw_offset = sub.last_offset;
        var raw_base_offset = window.base_offset;
        var raw_truncated_flag = false;
        if (has_new_bytes) {
            const want = window.next_offset - start;
            const max_chunk: usize = 256 * 1024;
            const take: usize = if (want > max_chunk) max_chunk else @as(usize, @intCast(want));
            const raw = entry.terminal.readRaw(self.alloc, start, take) catch |err| {
                entry.lock.unlock();
                return err;
            };
            raw_data_owned = raw.data;
            raw_offset = raw.offset;
            raw_base_offset = raw.base_offset;
            raw_truncated_flag = raw.truncated;
        }

        sub.last_offset = raw_offset;
        sub.last_bell_count = cur_bell;
        sub.last_command_seq = cur_cmd_seq;
        sub.last_notification_seq = cur_notif_seq;
        sub.seq += 1;
        const seq_now = sub.seq;
        const eof_now = eof_flag and raw_offset >= window.next_offset;
        if (eof_now) sub.eof_sent = true;
        entry.lock.unlock();

        defer if (raw_data_owned) |d| self.alloc.free(d);

        const data_bytes: []const u8 = if (raw_data_owned) |d| d else "";
        const enc_len = std.base64.standard.Encoder.calcSize(data_bytes.len);
        const enc = try self.alloc.alloc(u8, enc_len);
        defer self.alloc.free(enc);
        _ = std.base64.standard.Encoder.encode(enc, data_bytes);

        const NotificationsPayload = struct {
            bell: bool,
            command_finished: ?struct { exit_code: ?i32 },
            notification: ?struct { title: ?[]const u8, body: ?[]const u8 },
        };

        const notifications_payload: ?NotificationsPayload = if (has_new_notifications) .{
            .bell = new_bell,
            .command_finished = if (new_command) .{ .exit_code = exit_code_snapshot } else null,
            .notification = if (new_notification) .{
                .title = if (notif_title) |t| t else null,
                .body = if (notif_body) |b| b else null,
            } else null,
        } else null;

        const event = try json_rpc.encodeResponse(self.alloc, .{
            .event = "terminal.output",
            .seq = seq_now,
            .session_id = sub.session_id,
            .data = enc,
            .offset = raw_offset,
            .base_offset = raw_base_offset,
            .truncated = truncated or raw_truncated_flag,
            .eof = eof_now,
            .notifications = notifications_payload,
        });

        if (sub.queue) |q| {
            // Newline-frame for line-delimited Unix transport. enqueue takes
            // ownership of `line` on success.
            const line = try self.alloc.alloc(u8, event.len + 1);
            @memcpy(line[0..event.len], event);
            line[event.len] = '\n';
            self.alloc.free(event);
            q.enqueueTerminal(line) catch |err| {
                self.alloc.free(line);
                return err;
            };
            return;
        }

        defer self.alloc.free(event);
        sub.stream_lock.lock();
        defer sub.stream_lock.unlock();
        try sendWsTextFrame(sub.stream, event);
    }
};

fn sendWsTextFrame(stream: *std.net.Stream, data: []const u8) !void {
    var header: [10]u8 = undefined;
    header[0] = 0x81; // FIN + text
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
    if (data.len > 0) _ = try stream.write(data);
}

fn freePushJob(job: *PushJob) void {
    const alloc = job.service.alloc;
    alloc.free(job.endpoint);
    alloc.free(job.bearer_token);
    for (job.device_tokens) |t| alloc.free(t);
    alloc.free(job.device_tokens);
    alloc.free(job.session_id);
    if (job.workspace_id) |w| alloc.free(w);
    if (job.notif_title) |t| alloc.free(t);
    if (job.notif_body) |b| alloc.free(b);
    alloc.destroy(job);
}

/// Encode the push payload as a single JSON object matching the contract
/// documented in `docs/daemon-push-protocol.md` phase 4.3. Caller owns the
/// returned bytes.
fn encodePushBody(alloc: std.mem.Allocator, job: *const PushJob) ![]u8 {
    const CommandFinished = struct { exit_code: ?i32 };
    const NotificationFields = struct { title: ?[]const u8, body: ?[]const u8 };
    const Notifications = struct {
        bell: bool,
        command_finished: ?CommandFinished,
        notification: ?NotificationFields,
    };

    // Convert the job's owned `[][]u8` tokens into the `[]const []const u8`
    // shape that std.json.Stringify expects for an array-of-strings field.
    const tokens_const = try alloc.alloc([]const u8, job.device_tokens.len);
    defer alloc.free(tokens_const);
    for (job.device_tokens, 0..) |t, i| tokens_const[i] = t;

    const notifications: Notifications = .{
        .bell = job.bell,
        .command_finished = if (job.command_finished) .{ .exit_code = job.exit_code } else null,
        .notification = if (job.notification_present) .{
            .title = if (job.notif_title) |t| t else null,
            .body = if (job.notif_body) |b| b else null,
        } else null,
    };

    const payload = .{
        .device_tokens = tokens_const,
        .session_id = @as([]const u8, job.session_id),
        .workspace_id = if (job.workspace_id) |w| @as(?[]const u8, w) else @as(?[]const u8, null),
        .notifications = notifications,
    };

    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(payload, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Detached worker: runs on its own thread, posts the push body, frees
/// the job, decrements the service's in-flight counter, and signals any
/// waiter in `deinit`. Errors are logged and dropped (no retry — the
/// endpoint is responsible for APNs retry).
fn pushDispatchEntry(job: *PushJob) void {
    const service = job.service;
    defer {
        _ = service.push_inflight.fetchSub(1, .seq_cst);
        service.pushCvBroadcast();
    }
    defer freePushJob(job);

    postPushBody(job) catch |err| {
        std.log.warn(
            "session_service: remote push to {s} failed: {s}",
            .{ job.endpoint, @errorName(err) },
        );
    };
}

fn postPushBody(job: *PushJob) !void {
    const alloc = job.service.alloc;
    const body = try encodePushBody(alloc, job);
    defer alloc.free(body);

    // Scheme dispatch:
    //   http://   -> hand-rolled HTTP/1.1 over std.net.Stream (in-process,
    //                no fork, fastest path; see `simpleHttpPost`).
    //   https://  -> shell out to `curl`. zig 0.15.2's std.http.Client
    //                cannot be cleanly time-boxed: its ConnectionPool.resize
    //                helper has a latent compile-time error (DoublyLinkedList
    //                .Node.data) that trips whenever any code path
    //                instantiates it, making the usual std.http path
    //                unbuildable, and std.crypto.tls + root-store loading
    //                is more plumbing than this push path warrants. `curl`
    //                handles both TLS and the 5s timeout via --max-time.
    //                See `curlHttpsPost`.
    //   anything else: log + drop.
    const uri = std.Uri.parse(job.endpoint) catch {
        std.log.warn(
            "session_service: remote push dropped, invalid endpoint URI: {s}",
            .{job.endpoint},
        );
        return error.InvalidUri;
    };
    const scheme = uri.scheme;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) {
        return simpleHttpPost(alloc, job.endpoint, uri, job.bearer_token, body);
    }
    if (std.ascii.eqlIgnoreCase(scheme, "https")) {
        return curlHttpsPost(alloc, job.endpoint, job.bearer_token, body);
    }
    std.log.warn(
        "session_service: remote push dropped, unsupported scheme '{s}' (endpoint={s})",
        .{ scheme, job.endpoint },
    );
    return error.UnsupportedScheme;
}

/// Latched-on first miss so we don't spam logs every push when curl is
/// missing on PATH. HTTPS pushes still get dropped on every attempt; we
/// just stop logging after the first one.
var curl_missing_logged: std.atomic.Value(bool) = .init(false);

/// HTTPS push path: pipe the JSON body to `curl --data-binary @-` and let
/// curl handle TLS, redirects (we don't follow), and the 5s timeout via
/// `--max-time 5`. Stderr is inherited so curl's diagnostics surface in
/// daemon logs in dev. Stdout is discarded; we only care about the exit
/// code (0 on 2xx + transport success).
fn curlHttpsPost(
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) !void {
    const auth_header = try std.fmt.allocPrint(
        alloc,
        "Authorization: Bearer {s}",
        .{bearer_token},
    );
    defer alloc.free(auth_header);

    const argv = [_][]const u8{
        "curl",
        "-sS",
        "--fail",
        "--max-time",
        "5",
        "-X",
        "POST",
        "-H",
        auth_header,
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        "@-",
        endpoint,
    };

    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => {
            const already = curl_missing_logged.swap(true, .seq_cst);
            if (!already) {
                std.log.warn(
                    "session_service: remote push dropped, `curl` not found on PATH; HTTPS pushes will be silently dropped (endpoint={s})",
                    .{endpoint},
                );
            }
            return error.CurlNotFound;
        },
        else => return err,
    };

    // Stream the body in. If curl exits early (e.g. resolution failure),
    // writes hit EPIPE; treat that as a soft error and proceed to wait()
    // so we still observe the real exit code.
    if (child.stdin) |stdin| {
        stdin.writeAll(body) catch |err| {
            std.log.warn(
                "session_service: remote push curl stdin write failed: {s}",
                .{@errorName(err)},
            );
        };
        stdin.close();
        child.stdin = null;
    }

    const term = child.wait() catch |err| {
        std.log.warn(
            "session_service: remote push curl wait failed: {s}",
            .{@errorName(err)},
        );
        return err;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.warn(
                    "session_service: remote push to {s} failed, curl exit {d}",
                    .{ endpoint, code },
                );
                return error.RemotePushNon2xx;
            }
        },
        .Signal => |sig| {
            std.log.warn(
                "session_service: remote push to {s} failed, curl killed by signal {d}",
                .{ endpoint, sig },
            );
            return error.RemotePushCurlSignaled;
        },
        else => {
            std.log.warn(
                "session_service: remote push to {s} failed, curl terminated abnormally",
                .{endpoint},
            );
            return error.RemotePushCurlAbnormal;
        },
    }
}

/// Minimal HTTP/1.1 POST helper with a 5-second total timeout. Only handles
/// the path the daemon needs: POST `application/json` + bearer auth, body
/// via Content-Length, status-only response parsing. Plain `http://` only;
/// `https://` is routed through `curlHttpsPost` upstream.
fn simpleHttpPost(
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    uri: std.Uri,
    bearer_token: []const u8,
    body: []const u8,
) !void {
    const host_component = uri.host orelse return error.InvalidUri;
    const host = switch (host_component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    const port: u16 = uri.port orelse 80;

    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer path_buf.deinit(alloc);
    const path_component = uri.path;
    switch (path_component) {
        .raw => |s| try path_buf.appendSlice(alloc, if (s.len == 0) "/" else s),
        .percent_encoded => |s| try path_buf.appendSlice(alloc, if (s.len == 0) "/" else s),
    }
    if (uri.query) |q| {
        const q_str = switch (q) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        };
        if (q_str.len > 0) {
            try path_buf.append(alloc, '?');
            try path_buf.appendSlice(alloc, q_str);
        }
    }

    const addr_list = try std.net.getAddressList(alloc, host, port);
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return error.HostNotFound;

    const stream = try std.net.tcpConnectToAddress(addr_list.addrs[0]);
    defer stream.close();

    // Apply SO_RCVTIMEO / SO_SNDTIMEO = 5s. Both sides of the socket get a
    // deterministic upper bound independent of the HTTP client state.
    const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};

    const request = try std.fmt.allocPrint(
        alloc,
        "POST {s} HTTP/1.1\r\nHost: {s}\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ path_buf.items, host, bearer_token, body.len },
    );
    defer alloc.free(request);

    try writeAll(stream, request);
    try writeAll(stream, body);

    // Read just enough to find the status line; discard the rest.
    var head_buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < head_buf.len) {
        const n = stream.read(head_buf[total..]) catch |err| switch (err) {
            error.WouldBlock => return error.RemotePushTimeout,
            else => return err,
        };
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, head_buf[0..total], "\r\n") != null) break;
    }
    if (total == 0) return error.RemotePushEmptyResponse;

    const slice = head_buf[0..total];
    const first_space = std.mem.indexOfScalar(u8, slice, ' ') orelse return error.RemotePushBadResponse;
    const tail = slice[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const status_str = tail[0..second_space];
    const status = std.fmt.parseInt(u16, status_str, 10) catch return error.RemotePushBadResponse;
    if (status < 200 or status >= 300) {
        std.log.warn(
            "session_service: remote push to {s} returned status {d}",
            .{ endpoint, status },
        );
        return error.RemotePushNon2xx;
    }
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const n = stream.write(remaining) catch |err| switch (err) {
            error.WouldBlock => return error.RemotePushTimeout,
            else => return err,
        };
        if (n == 0) return error.RemotePushShortWrite;
        remaining = remaining[n..];
    }
}

test "open terminal returns named session when requested" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    try std.testing.expectEqualStrings("dev", opened.status.session_id);
    try std.testing.expectEqualStrings("att-1", opened.attachment_id);
}

test "terminal read returns subprocess output" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(null, "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const read = try service.readTerminal(opened.status.session_id, 0, 32, 1000);
    defer std.testing.allocator.free(read.data);

    try std.testing.expect(std.mem.indexOf(u8, read.data, "READY") != null);
}

test "terminal write_id suppresses duplicate retry" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("write-dedupe", "stty -echo; printf READY; cat", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const ready = try service.readTerminal(opened.status.session_id, 0, 4096, 1000);
    defer std.testing.allocator.free(ready.data);
    try std.testing.expect(std.mem.indexOf(u8, ready.data, "READY") != null);

    const token = "CMUX_WRITE_DEDUPE_ONCE\n";
    try std.testing.expectEqual(token.len, try service.writeTerminal(opened.status.session_id, token, "write-id-1"));
    try std.testing.expectEqual(token.len, try service.writeTerminal(opened.status.session_id, token, "write-id-1"));

    const read = try service.readTerminal(opened.status.session_id, ready.offset, 4096, 1000);
    defer std.testing.allocator.free(read.data);

    var occurrences: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, read.data[search_from..], "CMUX_WRITE_DEDUPE_ONCE")) |relative| {
        occurrences += 1;
        search_from += relative + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), occurrences);
}

test "list sessions retains last known size after final detach" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 120, 40);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const initial = try service.listSessions();
    defer {
        for (initial) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(initial);
    }

    try std.testing.expectEqual(@as(usize, 1), initial.len);
    try std.testing.expectEqual(@as(usize, 1), initial[0].attachment_count);
    try std.testing.expectEqual(@as(u16, 120), initial[0].effective_cols);
    try std.testing.expectEqual(@as(u16, 40), initial[0].effective_rows);

    var detached = try service.detachSession("dev", opened.attachment_id);
    defer detached.deinit(std.testing.allocator);

    const listed = try service.listSessions();
    defer {
        for (listed) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }

    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(usize, 0), listed[0].attachment_count);
    try std.testing.expectEqual(@as(u16, 120), listed[0].effective_cols);
    try std.testing.expectEqual(@as(u16, 40), listed[0].effective_rows);
}

test "terminal.subscribe snapshot + pump pushes terminal.output" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(
        "sub-smoke",
        "printf INITIAL; sleep 0.2; printf LATER",
        80,
        24,
    );
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    // Give the first printf time to land before subscribing so we can verify
    // subscribing at the current offset returns no replay (snap.data empty).
    std.Thread.sleep(80 * std.time.ns_per_ms);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    // Make the read side non-blocking so the polling loop below doesn't wedge.
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var write_mutex: std.Thread.Mutex = .{};

    const snap = try service.subscribeTerminal(&stream, &write_mutex, "sub-smoke", null);
    std.testing.allocator.free(snap.data);

    // Wait until the pump pushes a terminal.output frame containing LATER.
    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 3000;
    var got_event = false;
    var got_later = false;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(15 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"event\":\"terminal.output\"") != null) {
            got_event = true;
        }
        if (std.mem.indexOf(u8, accum.items, "TEFURVI=") != null or // base64("LATER")
            std.mem.indexOf(u8, accum.items, "TEFURVI") != null)
        {
            got_later = true;
        }
        if (got_event and got_later) break;
    }
    try std.testing.expect(got_event);
    try std.testing.expect(got_later);

    _ = service.unsubscribeTerminal(&stream, "sub-smoke");
}

test "queued terminal.subscribe routes pushes through OutboundQueue" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal(
        "queued-smoke",
        "printf INITIAL; sleep 0.2; printf LATER",
        80,
        24,
    );
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    std.Thread.sleep(80 * std.time.ns_per_ms);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var queue = outbound_queue.OutboundQueue.init(std.testing.allocator, fds[0]);
    try queue.start();
    defer queue.shutdown();

    var write_mutex: std.Thread.Mutex = .{};
    const snap = try service.subscribeTerminalQueued(&stream, &write_mutex, &queue, "queued-smoke", null);
    std.testing.allocator.free(snap.data);

    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 3000;
    var got_event = false;
    var got_later = false;
    var got_newline = false;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(15 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"event\":\"terminal.output\"") != null) got_event = true;
        if (std.mem.indexOf(u8, accum.items, "TEFURVI") != null) got_later = true;
        if (std.mem.indexOfScalar(u8, accum.items, '\n') != null) got_newline = true;
        if (got_event and got_later and got_newline) break;
    }
    try std.testing.expect(got_event);
    try std.testing.expect(got_later);
    try std.testing.expect(got_newline);

    _ = service.unsubscribeTerminal(&stream, "queued-smoke");
}

test "kqueue pump drains PTY without explicit read" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();
    service.ensurePumpStarted();

    var opened = try service.openTerminal("pump-smoke", "printf 'hello-from-pump\\n'", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    // Spin briefly waiting for the pump thread to drain output. We never
    // call readTerminal/history; if next_offset grows the pump did its job.
    const runtime_ptr = service.runtimes.get("pump-smoke") orelse return error.MissingRuntime;
    const deadline = std.time.milliTimestamp() + 2000;
    var grew = false;
    while (std.time.milliTimestamp() < deadline) {
        runtime_ptr.lock.lock();
        const window = runtime_ptr.terminal.offsetWindow();
        runtime_ptr.lock.unlock();
        if (window.next_offset > 0) {
            grew = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(grew);
}

test "close session removes terminal runtime" {
    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("dev", "printf READY", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    try service.closeSession("dev");

    try std.testing.expectError(error.SessionNotFound, service.sessionStatus("dev"));
    try std.testing.expectError(error.TerminalSessionNotFound, service.readTerminal("dev", 0, 32, 0));
    try std.testing.expectError(error.TerminalSessionNotFound, service.writeTerminal("dev", "hello", null));
    try std.testing.expectError(error.TerminalSessionNotFound, service.history("dev", .plain));
}

test "terminal.output carries notifications:{bell:true} once then null" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("notif-smoke", "sleep 5", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    const flags = try std.posix.fcntl(fds[1], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(fds[1], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    var write_mutex: std.Thread.Mutex = .{};

    const snap = try service.subscribeTerminal(&stream, &write_mutex, "notif-smoke", null);
    std.testing.allocator.free(snap.data);

    const runtime = service.runtimes.get("notif-smoke") orelse return error.MissingRuntime;
    const entry: pty_pump.Entry = .{
        .pty = &runtime.pty,
        .terminal = &runtime.terminal,
        .lock = &runtime.lock,
        .session_id = "notif-smoke",
        .in_flight = &runtime.pump_in_flight,
    };

    // Inject a BEL + printable byte, so the push has both a notification and new bytes.
    runtime.lock.lock();
    try runtime.terminal.feed("\x07x");
    runtime.lock.unlock();

    service.deliverTerminalPushes(entry);

    var buf: [4096]u8 = undefined;
    var accum: std.ArrayListUnmanaged(u8) = .empty;
    defer accum.deinit(std.testing.allocator);

    const deadline = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"bell\":true") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"bell\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"notifications\":null") == null);

    accum.clearRetainingCapacity();
    runtime.lock.lock();
    try runtime.terminal.feed("y");
    runtime.lock.unlock();

    service.deliverTerminalPushes(entry);

    const deadline2 = std.time.milliTimestamp() + 1000;
    while (std.time.milliTimestamp() < deadline2) {
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        try accum.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, accum.items, "\"notifications\":null") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"notifications\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, accum.items, "\"bell\":true") == null);

    _ = service.unsubscribeTerminal(&stream, "notif-smoke");
}

test "session has_unread_output flips true when pump fires without subscribers" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("unread-smoke", "printf hi", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    // Wait for the pump to drain output and notify with no subscribers.
    const deadline = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline) {
        if (service.hasUnread("unread-smoke")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(service.hasUnread("unread-smoke"));
}

test "markRead clears has_unread_output" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("markread-smoke", "printf hi", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const deadline = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline) {
        if (service.hasUnread("markread-smoke")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(service.hasUnread("markread-smoke"));

    try std.testing.expect(service.markRead("markread-smoke"));
    try std.testing.expect(!service.hasUnread("markread-smoke"));
    try std.testing.expect(!service.markRead("no-such-session"));
}

test "subscribeTerminal clears has_unread_output" {
    if (!pty_pump.supported) return error.SkipZigTest;

    var service = Service.init(std.testing.allocator);
    defer service.deinit();

    var opened = try service.openTerminal("sub-clears", "printf hi; sleep 5", 80, 24);
    defer opened.status.deinit(std.testing.allocator);
    defer std.testing.allocator.free(opened.attachment_id);

    const deadline = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline) {
        if (service.hasUnread("sub-clears")) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(service.hasUnread("sub-clears"));

    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }
    defer std.posix.close(fds[1]);
    var stream = std.net.Stream{ .handle = fds[0] };
    var write_mutex: std.Thread.Mutex = .{};

    const snap = try service.subscribeTerminal(&stream, &write_mutex, "sub-clears", null);
    std.testing.allocator.free(snap.data);

    try std.testing.expect(!service.hasUnread("sub-clears"));

    _ = service.unsubscribeTerminal(&stream, "sub-clears");
}

const RemotePushTestCapture = struct {
    server: *std.net.Server,
    alloc: std.mem.Allocator,
    received: std.ArrayListUnmanaged(u8) = .empty,
    got_request: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},

    fn run(self: *RemotePushTestCapture) void {
        const conn = self.server.accept() catch {
            self.done.store(true, .seq_cst);
            return;
        };
        defer conn.stream.close();

        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        var saw_headers_end: ?usize = null;
        var content_length: ?usize = null;

        while (total < buf.len) {
            const n = conn.stream.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (saw_headers_end == null) {
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                    saw_headers_end = idx + 4;
                    // Parse content-length from the header block.
                    const header_block = buf[0..idx];
                    var it = std.mem.splitSequence(u8, header_block, "\r\n");
                    while (it.next()) |line| {
                        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                        const name = std.mem.trim(u8, line[0..colon], " ");
                        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                            content_length = std.fmt.parseInt(usize, value, 10) catch null;
                        }
                    }
                }
            }
            if (saw_headers_end) |hdr_end| {
                if (content_length) |cl| {
                    if (total - hdr_end >= cl) break;
                } else break;
            }
        }

        self.mutex.lock();
        self.received.appendSlice(self.alloc, buf[0..total]) catch {};
        self.mutex.unlock();
        self.got_request.store(true, .seq_cst);

        // Reply with 204 No Content so the daemon sees a 2xx.
        const reply = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
        _ = conn.stream.write(reply) catch {};
        self.done.store(true, .seq_cst);
    }
};

test "daemon.configure_notifications + bell with no subscribers POSTs to endpoint" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // Bind a local TCP listener on an ephemeral port.
    const any_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try any_addr.listen(.{ .reuse_address = true });
    const listen_port = server.listen_address.getPort();

    var capture = RemotePushTestCapture{
        .server = &server,
        .alloc = alloc,
    };
    capture.thread = try std.Thread.spawn(.{}, RemotePushTestCapture.run, .{&capture});

    // Teardown order: close the listener first (unblocks any still-blocked
    // accept() with an error), then join the capture thread, then free
    // buffers. Declaring in reverse here gets us that order.
    defer {
        capture.mutex.lock();
        capture.received.deinit(alloc);
        capture.mutex.unlock();
    }
    defer if (capture.thread) |t| t.join();
    defer server.deinit();

    var service = Service.init(alloc);
    defer service.deinit();

    const endpoint = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}/push",
        .{listen_port},
    );
    defer alloc.free(endpoint);

    const token_a: []const u8 = "abc123";
    const token_b: []const u8 = "deadbeef";
    const tokens = [_][]const u8{ token_a, token_b };

    try service.configureNotifications(endpoint, "shhh-secret", &tokens);

    var opened = try service.openTerminal("remote-smoke", "sleep 5", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);

    // Inject a BEL byte into the runtime's terminal state machine so
    // bell_count advances. We do NOT subscribe; this is the whole point.
    const runtime = service.runtimes.get("remote-smoke") orelse return error.MissingRuntime;
    runtime.lock.lock();
    try runtime.terminal.feed("\x07");
    runtime.lock.unlock();

    // Simulate the pump's notify callback firing for this session.
    const entry: pty_pump.Entry = .{
        .pty = &runtime.pty,
        .terminal = &runtime.terminal,
        .lock = &runtime.lock,
        .session_id = "remote-smoke",
        .in_flight = &runtime.pump_in_flight,
    };
    service.deliverTerminalPushes(entry);

    // Wait up to 2 seconds for the capture thread to receive the POST.
    const deadline = std.time.milliTimestamp() + 2_000;
    while (std.time.milliTimestamp() < deadline) {
        if (capture.got_request.load(.seq_cst)) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(capture.got_request.load(.seq_cst));

    capture.mutex.lock();
    const got = try alloc.dupe(u8, capture.received.items);
    capture.mutex.unlock();
    defer alloc.free(got);

    // Request line.
    try std.testing.expect(std.mem.indexOf(u8, got, "POST /push HTTP/1.1") != null);
    // Bearer header, case-insensitive match on the header name.
    try std.testing.expect(
        std.mem.indexOf(u8, got, "Authorization: Bearer shhh-secret") != null or
            std.mem.indexOf(u8, got, "authorization: Bearer shhh-secret") != null,
    );
    // Content-Type + body assertions.
    try std.testing.expect(
        std.mem.indexOf(u8, got, "Content-Type: application/json") != null or
            std.mem.indexOf(u8, got, "content-type: application/json") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, got, "\"session_id\":\"remote-smoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"bell\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"device_tokens\":[\"abc123\",\"deadbeef\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"notifications\":") != null);
    // Session has no binding workspace, so workspace_id should be null.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"workspace_id\":null") != null);
}

test "daemon.configure_notifications disables remote push on empty endpoint" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var service = Service.init(alloc);
    defer service.deinit();

    // Start with a valid-looking config, then overwrite with endpoint="".
    const tokens = [_][]const u8{"abcd"};
    try service.configureNotifications("http://127.0.0.1:1/push", "x", &tokens);
    try service.configureNotifications("", "", &[_][]const u8{});

    var opened = try service.openTerminal("disabled-smoke", "sleep 5", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);

    const runtime = service.runtimes.get("disabled-smoke") orelse return error.MissingRuntime;
    runtime.lock.lock();
    try runtime.terminal.feed("\x07");
    runtime.lock.unlock();

    const entry: pty_pump.Entry = .{
        .pty = &runtime.pty,
        .terminal = &runtime.terminal,
        .lock = &runtime.lock,
        .session_id = "disabled-smoke",
        .in_flight = &runtime.pump_in_flight,
    };
    // Should return fast without spawning a push thread. We can't easily
    // observe "no push" other than the test completing and deinit not
    // blocking on any in-flight dispatcher.
    service.deliverTerminalPushes(entry);

    // Give any (non-)thread time to land before deinit.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), service.push_inflight.load(.seq_cst));
}

test "https remote push spawns curl, fails fast on unreachable, releases push_inflight" {
    if (!pty_pump.supported) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var service = Service.init(alloc);
    defer service.deinit();

    // Point at an unreachable HTTPS endpoint. Port 1 is in the IANA
    // reserved range and almost universally closed, so curl gets
    // connection-refused (or fails the TLS handshake) well within
    // --max-time 5 and exits non-zero. We only care that the dispatcher
    // path went through curlHttpsPost (push_inflight bumped) and that
    // the worker thread cleaned up (push_inflight back to zero, deinit
    // doesn't hang).
    const tokens = [_][]const u8{"abcd"};
    try service.configureNotifications(
        "https://127.0.0.1:1/never",
        "shhh-secret",
        &tokens,
    );

    var opened = try service.openTerminal("https-smoke", "sleep 5", 80, 24);
    defer opened.status.deinit(alloc);
    defer alloc.free(opened.attachment_id);

    const runtime = service.runtimes.get("https-smoke") orelse return error.MissingRuntime;
    runtime.lock.lock();
    try runtime.terminal.feed("\x07");
    runtime.lock.unlock();

    const entry: pty_pump.Entry = .{
        .pty = &runtime.pty,
        .terminal = &runtime.terminal,
        .lock = &runtime.lock,
        .session_id = "https-smoke",
        .in_flight = &runtime.pump_in_flight,
    };
    service.deliverTerminalPushes(entry);

    // Wait for the dispatcher worker to finish. Cap at 6s to account for
    // the worst-case curl --max-time 5 plus spawn/wait overhead. Most
    // platforms drop port-1 connection attempts in under a millisecond.
    const deadline = std.time.milliTimestamp() + 6_000;
    while (std.time.milliTimestamp() < deadline) {
        if (service.push_inflight.load(.seq_cst) == 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), service.push_inflight.load(.seq_cst));
}
