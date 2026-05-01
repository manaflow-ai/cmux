const std = @import("std");

pub const AttachmentStatus = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub const SessionStatus = struct {
    session_id: []const u8,
    attachments: []AttachmentStatus,
    effective_cols: u16,
    effective_rows: u16,
    last_known_cols: u16,
    last_known_rows: u16,
    /// Monotonic counter incremented whenever `effective_cols` or
    /// `effective_rows` changes. Lets clients order resize events
    /// received out of sequence (RPC response vs. broadcast, multi-
    /// attach races). Scoped per connection: daemon bumps it on every
    /// effective-size change; clients reset on new connection.
    grid_generation: u64,

    pub fn deinit(self: *SessionStatus, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.attachments);
    }
};

pub const EffectiveSize = struct {
    cols: u16,
    rows: u16,
};

pub const SessionListEntry = struct {
    session_id: []const u8,
    attachment_count: usize,
    effective_cols: u16,
    effective_rows: u16,

    pub fn deinit(self: *SessionListEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
    }
};

const AttachmentState = struct {
    cols: u16,
    rows: u16,
    updated_seq: u64 = 0,
};

const SessionState = struct {
    attachments: std.StringHashMap(AttachmentState),
    effective_cols: u16 = 0,
    effective_rows: u16 = 0,
    last_known_cols: u16 = 0,
    last_known_rows: u16 = 0,
    /// See SessionStatus.grid_generation. Bumped in `recomputeEffective`
    /// whenever the computed (cols, rows) change.
    grid_generation: u64 = 0,
    /// Monotonic per-session attachment update clock. Effective PTY size is
    /// still computed from the smallest live attachment so every renderer can
    /// display the shared grid.
    next_attachment_update_seq: u64 = 1,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    next_attachment_id: u64 = 1,
    sessions: std.StringHashMap(SessionState),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .alloc = alloc,
            .sessions = std.StringHashMap(SessionState).init(alloc),
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            // Free attachment keys owned by this session. Without this,
            // the bootstrap attachment created in `openWithOptions` (and
            // any explicit `attach` entries) leak their duped key strings
            // on teardown. ReleaseSafe + GPA caught this as a per-test
            // leak; ReleaseFast was hiding it.
            var attach_iter = entry.value_ptr.attachments.iterator();
            while (attach_iter.next()) |a| {
                self.alloc.free(a.key_ptr.*);
            }
            entry.value_ptr.attachments.deinit();
            self.alloc.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub const OpenOptions = struct {
        /// When true (legacy default, matches `terminal.open` callers),
        /// `open` registers a bootstrap attachment at the requested
        /// cols/rows. Callers that intend to have a real client attach
        /// separately (like `workspace.open_pane` followed by a
        /// client-minted `session.attach`) should pass false: the session
        /// and PTY are sized via `last_known_cols/rows` from the requested
        /// size, but no `attachments` entry is created. Without this,
        /// the bootstrap can become an invisible size constraint and keep
        /// the PTY smaller than real clients need after they attach.
        create_bootstrap_attachment: bool = true,
    };

    pub const OpenResult = struct {
        session_id: []const u8,
        attachment_id: []const u8,
    };

    pub fn open(
        self: *Registry,
        maybe_session_id: ?[]const u8,
        cols: u16,
        rows: u16,
    ) !OpenResult {
        return self.openWithOptions(maybe_session_id, cols, rows, .{});
    }

    pub fn openWithOptions(
        self: *Registry,
        maybe_session_id: ?[]const u8,
        cols: u16,
        rows: u16,
        options: OpenOptions,
    ) !OpenResult {
        const size = normalizeSize(cols, rows);
        const session_id = if (maybe_session_id) |requested| blk: {
            if (self.sessions.contains(requested)) return error.SessionAlreadyExists;
            break :blk try self.alloc.dupe(u8, requested);
        } else blk: {
            // Session ids are opaque UUIDs. The previous `sess-{counter}`
            // scheme was a split-ownership bug waiting to happen: the
            // counter resets on daemon restart, whereas explicit-id
            // sessions (created by `terminal.open` on behalf of a mac
            // surface that restored a saved id) never touch the counter.
            // Result: after a restart, auto-generating `sess-1` collided
            // with a restored `sess-1` and silently overwrote it, merging
            // two user-visible terminals into one (cmd+N bug). UUIDs
            // remove the collision class by construction; no counter,
            // no cross-run state to reconcile, and the id carries no
            // implicit ordering semantics for any reader to rely on.
            break :blk try generateUuidSessionId(self.alloc);
        };
        errdefer self.alloc.free(session_id);
        // Invariants enforced by both allocation paths; assert so that a
        // future regression surfaces as a named panic under ReleaseSafe
        // rather than silent downstream corruption.
        std.debug.assert(session_id.len > 0);
        std.debug.assert(!self.sessions.contains(session_id));

        var session = SessionState{
            .attachments = std.StringHashMap(AttachmentState).init(self.alloc),
            // Seed last_known so `effective` is non-zero until the first
            // real client attaches. Matters for the zero-bootstrap path:
            // openTerminal reads effective_cols/rows to size the PTY, and
            // a 0×0 PTY fails `posix_openpt + ioctl(TIOCSWINSZ)`.
            .last_known_cols = size.cols,
            .last_known_rows = size.rows,
        };

        var bootstrap_attachment_id: ?[]const u8 = null;
        if (options.create_bootstrap_attachment) {
            const attachment_id = try std.fmt.allocPrint(self.alloc, "att-{d}", .{self.next_attachment_id});
            self.next_attachment_id += 1;
            try session.attachments.put(attachment_id, .{
                .cols = size.cols,
                .rows = size.rows,
                .updated_seq = nextAttachmentUpdateSeq(&session),
            });
            bootstrap_attachment_id = attachment_id;
        }
        recompute(&session);
        try self.sessions.put(session_id, session);

        return .{
            .session_id = try self.alloc.dupe(u8, session_id),
            .attachment_id = try self.alloc.dupe(u8, bootstrap_attachment_id orelse ""),
        };
    }

    pub fn ensure(self: *Registry, maybe_session_id: ?[]const u8) ![]const u8 {
        if (maybe_session_id) |session_id| {
            if (self.sessions.contains(session_id)) {
                return try self.alloc.dupe(u8, session_id);
            }

            const owned = try self.alloc.dupe(u8, session_id);
            const session = SessionState{
                .attachments = std.StringHashMap(AttachmentState).init(self.alloc),
            };
            try self.sessions.put(owned, session);
            return try self.alloc.dupe(u8, owned);
        }

        const opened = try self.open(null, 0, 0);
        defer self.alloc.free(opened.attachment_id);
        self.detach(opened.session_id, opened.attachment_id) catch {};
        return opened.session_id;
    }

    pub fn attach(self: *Registry, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !void {
        const size = normalizeSize(cols, rows);
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_attachment = if (session.attachments.contains(attachment_id))
            null
        else
            try self.alloc.dupe(u8, attachment_id);
        errdefer if (owned_attachment) |value| self.alloc.free(value);

        try session.attachments.put(owned_attachment orelse attachment_id, .{
            .cols = size.cols,
            .rows = size.rows,
            .updated_seq = nextAttachmentUpdateSeq(session),
        });
        recompute(session);
    }

    pub fn resize(self: *Registry, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !void {
        const size = normalizeSize(cols, rows);
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const attachment = session.attachments.getPtr(attachment_id) orelse return error.AttachmentNotFound;
        attachment.* = .{
            .cols = size.cols,
            .rows = size.rows,
            .updated_seq = nextAttachmentUpdateSeq(session),
        };
        recompute(session);
    }

    pub fn detach(self: *Registry, session_id: []const u8, attachment_id: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_attachment = session.attachments.fetchRemove(attachment_id) orelse return error.AttachmentNotFound;
        self.alloc.free(owned_attachment.key);
        recompute(session);
    }

    pub fn close(self: *Registry, session_id: []const u8) !void {
        const removed = self.sessions.fetchRemove(session_id) orelse return error.SessionNotFound;
        var session = removed.value;

        var iter = session.attachments.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        session.attachments.deinit();
        self.alloc.free(removed.key);
    }

    pub fn status(self: *Registry, session_id: []const u8) !SessionStatus {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;

        var attachments = std.ArrayList(AttachmentStatus).empty;
        defer attachments.deinit(self.alloc);

        var iter = session.attachments.iterator();
        while (iter.next()) |entry| {
            try attachments.append(self.alloc, .{
                .attachment_id = entry.key_ptr.*,
                .cols = entry.value_ptr.cols,
                .rows = entry.value_ptr.rows,
            });
        }
        std.mem.sort(AttachmentStatus, attachments.items, {}, struct {
            fn lessThan(_: void, a: AttachmentStatus, b: AttachmentStatus) bool {
                return std.mem.order(u8, a.attachment_id, b.attachment_id) == .lt;
            }
        }.lessThan);

        return .{
            .session_id = try self.alloc.dupe(u8, session_id),
            .attachments = try attachments.toOwnedSlice(self.alloc),
            .effective_cols = session.effective_cols,
            .effective_rows = session.effective_rows,
            .last_known_cols = session.last_known_cols,
            .last_known_rows = session.last_known_rows,
            .grid_generation = session.grid_generation,
        };
    }

    /// Snapshot of the current effective size for a session, or null when
    /// the session is unknown. Callers pair this with a subsequent mutation
    /// (attach/resize/detach → status) to detect when `recompute` produced
    /// a new value and needs to be broadcast to subscribers.
    pub fn effectiveSize(self: *Registry, session_id: []const u8) ?EffectiveSize {
        const session = self.sessions.getPtr(session_id) orelse return null;
        return .{
            .cols = session.effective_cols,
            .rows = session.effective_rows,
        };
    }

    pub fn list(self: *Registry) ![]SessionListEntry {
        var sessions = std.ArrayList(SessionListEntry).empty;
        defer sessions.deinit(self.alloc);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try sessions.append(self.alloc, .{
                .session_id = try self.alloc.dupe(u8, entry.key_ptr.*),
                .attachment_count = entry.value_ptr.attachments.count(),
                .effective_cols = entry.value_ptr.effective_cols,
                .effective_rows = entry.value_ptr.effective_rows,
            });
        }

        std.mem.sort(SessionListEntry, sessions.items, {}, struct {
            fn lessThan(_: void, a: SessionListEntry, b: SessionListEntry) bool {
                return std.mem.order(u8, a.session_id, b.session_id) == .lt;
            }
        }.lessThan);

        return sessions.toOwnedSlice(self.alloc);
    }
};

fn recompute(session: *SessionState) void {
    const prev_cols = session.effective_cols;
    const prev_rows = session.effective_rows;

    if (session.attachments.count() == 0) {
        session.effective_cols = session.last_known_cols;
        session.effective_rows = session.last_known_rows;
        if (session.effective_cols != prev_cols or session.effective_rows != prev_rows) {
            session.grid_generation += 1;
        }
        return;
    }

    // Compute the shared size every live attachment can display.
    // Attachments with cols==0/rows==0 (e.g. the bootstrap attachment from
    // terminal.open, or legacy attachments that never got a size) are
    // ignored so they don't drag effective_cols/rows to zero and trip the
    // PTY resize ioctl. A larger desktop client letterboxes around a phone-
    // sized PTY rather than forcing an impossible desktop-sized grid onto iOS.
    var iter = session.attachments.iterator();
    var min_cols: u16 = 0;
    var min_rows: u16 = 0;
    while (iter.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value.cols == 0 or value.rows == 0) continue;
        if (min_cols == 0 or value.cols < min_cols) {
            min_cols = value.cols;
        }
        if (min_rows == 0 or value.rows < min_rows) {
            min_rows = value.rows;
        }
    }

    // Fall back to the last known size if no attachment has a real size yet.
    if (min_cols == 0) min_cols = session.last_known_cols;
    if (min_rows == 0) min_rows = session.last_known_rows;

    session.effective_cols = min_cols;
    session.effective_rows = min_rows;
    if (min_cols > 0) session.last_known_cols = min_cols;
    if (min_rows > 0) session.last_known_rows = min_rows;

    // Bump grid_generation only on an actual change so clients can ignore
    // stale out-of-order deliveries by strict monotonicity.
    if (session.effective_cols != prev_cols or session.effective_rows != prev_rows) {
        session.grid_generation += 1;
    }
}

fn nextAttachmentUpdateSeq(session: *SessionState) u64 {
    const seq = session.next_attachment_update_seq;
    session.next_attachment_update_seq += 1;
    return seq;
}

fn normalizeSize(cols: u16, rows: u16) AttachmentState {
    return .{
        .cols = if (cols == 0) 0 else @max(@as(u16, 2), cols),
        .rows = if (rows == 0) 0 else @max(@as(u16, 1), rows),
    };
}

/// Generate an opaque, globally-unique session id. Uses 16 random bytes
/// (128 bits) rendered as lowercase hex, prefixed with `sess-` so logs
/// and RPC traces still filter cleanly. No counter, no per-run state,
/// no cross-run collisions.
fn generateUuidSessionId(alloc: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const hex = std.fmt.bytesToHex(buf, .lower);
    return try std.fmt.allocPrint(alloc, "sess-{s}", .{&hex});
}

test "open allocates session and attachment ids" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(null, 120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    // Session ids are opaque UUID-prefixed strings; assert only the
    // stable prefix + length shape, not a counter-based value.
    try std.testing.expect(std.mem.startsWith(u8, opened.session_id, "sess-"));
    try std.testing.expectEqual(@as(usize, "sess-".len + 32), opened.session_id.len);
    try std.testing.expectEqualStrings("att-1", opened.attachment_id);
}

test "attach and resize keep the smallest live attachment as the effective size" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(null, 120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.resize(opened.session_id, opened.attachment_id, 100, 30);
    try registry.attach(opened.session_id, "att-2", 80, 24);

    var after_attach = try registry.status(opened.session_id);
    defer after_attach.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 80), after_attach.effective_cols);
    try std.testing.expectEqual(@as(u16, 24), after_attach.effective_rows);

    try registry.resize(opened.session_id, opened.attachment_id, 100, 30);

    var after_owner_resize = try registry.status(opened.session_id);
    defer after_owner_resize.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 80), after_owner_resize.effective_cols);
    try std.testing.expectEqual(@as(u16, 24), after_owner_resize.effective_rows);
}

test "tiny attachment widths are clamped for effective dimensions" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open("dev", 1, 1);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), status.effective_cols);
    try std.testing.expectEqual(@as(u16, 1), status.effective_rows);
    try std.testing.expectEqual(@as(u16, 2), status.attachments[0].cols);
    try std.testing.expectEqual(@as(u16, 1), status.attachments[0].rows);
}

test "detach preserves last known size" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(null, 120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.detach(opened.session_id, opened.attachment_id);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 120), status.last_known_cols);
    try std.testing.expectEqual(@as(u16, 40), status.last_known_rows);
    try std.testing.expectEqual(@as(u16, 120), status.effective_cols);
    try std.testing.expectEqual(@as(u16, 40), status.effective_rows);
}

test "status attachments are sorted by id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(null, 120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.attach(opened.session_id, "att-9", 90, 30);
    try registry.attach(opened.session_id, "att-2", 80, 24);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("att-1", status.attachments[0].attachment_id);
    try std.testing.expectEqualStrings("att-2", status.attachments[1].attachment_id);
    try std.testing.expectEqualStrings("att-9", status.attachments[2].attachment_id);
}

test "close removes session from registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(null, 120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.close(opened.session_id);
    try std.testing.expectError(error.SessionNotFound, registry.status(opened.session_id));
}

test "ensure without id leaves session attachable" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const session_id = try registry.ensure(null);
    defer std.testing.allocator.free(session_id);

    try registry.attach(session_id, "att-fixture", 120, 40);

    var status = try registry.status(session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), status.attachments.len);
    try std.testing.expectEqualStrings("att-fixture", status.attachments[0].attachment_id);
}

test "open with create_bootstrap_attachment=false skips phantom attachment cap" {
    // Regression: previously `workspace.open_pane` created a session-scoped
    // bootstrap attachment at the requested cols/rows. When a real client
    // later attached via `session.attach` with its own id, the session had
    // TWO attachments and the invisible bootstrap could keep steering the
    // PTY. The fix: allow open to skip creating the bootstrap; size the PTY
    // via `last_known_cols/rows` so the first real client's attach drives
    // `effective` cleanly.
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    // Open at 100x30 with no bootstrap attachment.
    const opened = try registry.openWithOptions("test-session", 100, 30, .{
        .create_bootstrap_attachment = false,
    });
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    // No attachment created; effective = last_known = 100x30.
    var initial = try registry.status(opened.session_id);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), initial.attachments.len);
    try std.testing.expectEqual(@as(u16, 100), initial.effective_cols);
    try std.testing.expectEqual(@as(u16, 30), initial.effective_rows);

    // Client attaches at 150x50. With no phantom attachment, effective = 150x50.
    try registry.attach(opened.session_id, "bridge-xyz", 150, 50);
    var after_attach = try registry.status(opened.session_id);
    defer after_attach.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 150), after_attach.effective_cols);
    try std.testing.expectEqual(@as(u16, 50), after_attach.effective_rows);
    // Generation incremented (100x30 -> 150x50 is a real change).
    try std.testing.expect(after_attach.grid_generation > initial.grid_generation);
}

test "open with create_bootstrap_attachment=true keeps legacy behavior" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open("legacy", 80, 24);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), status.attachments.len);
    try std.testing.expectEqualStrings(opened.attachment_id, status.attachments[0].attachment_id);
    try std.testing.expectEqual(@as(u16, 80), status.effective_cols);
    try std.testing.expectEqual(@as(u16, 24), status.effective_rows);
}

test "list returns sessions sorted by id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const zebra = try registry.open("zebra", 80, 24);
    defer std.testing.allocator.free(zebra.session_id);
    defer std.testing.allocator.free(zebra.attachment_id);

    const alpha = try registry.open("alpha", 90, 30);
    defer std.testing.allocator.free(alpha.session_id);
    defer std.testing.allocator.free(alpha.attachment_id);

    const sessions = try registry.list();
    defer {
        for (sessions) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqualStrings("alpha", sessions[0].session_id);
    try std.testing.expectEqualStrings("zebra", sessions[1].session_id);
}

test "auto-generated session ids are uuid-shaped and unique at scale" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    // Generate many sessions through the null-id path and assert each
    // one is a fresh "sess-<32hex>" string. Catches regression to the
    // old `sess-{counter}` scheme where restart resets collided with
    // explicit-id sessions. Closes each session as it goes so the
    // bootstrap attachment allocations don't accumulate across the loop.
    const n: usize = 512;
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| std.testing.allocator.free(key.*);
        seen.deinit();
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const opened = try registry.open(null, 80, 24);
        try std.testing.expect(std.mem.startsWith(u8, opened.session_id, "sess-"));
        try std.testing.expectEqual(@as(usize, "sess-".len + 32), opened.session_id.len);
        const owned_id = try std.testing.allocator.dupe(u8, opened.session_id);
        const put = try seen.getOrPut(owned_id);
        if (put.found_existing) {
            std.testing.allocator.free(owned_id);
            try std.testing.expect(false);
        }
        try registry.close(opened.session_id);
        std.testing.allocator.free(opened.session_id);
        std.testing.allocator.free(opened.attachment_id);
    }
    try std.testing.expectEqual(n, seen.count());
}

test "auto-generated id does not collide with pre-existing explicit id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    // Pre-seed an explicit sess-1 as the old mac-restore path did.
    // The UUID generator must not produce this string, so no
    // SessionAlreadyExists and no silent overwrite.
    const seeded = try registry.open("sess-1", 80, 24);
    defer std.testing.allocator.free(seeded.session_id);
    defer std.testing.allocator.free(seeded.attachment_id);

    const auto = try registry.open(null, 80, 24);
    defer std.testing.allocator.free(auto.session_id);
    defer std.testing.allocator.free(auto.attachment_id);

    try std.testing.expect(!std.mem.eql(u8, auto.session_id, "sess-1"));
}
