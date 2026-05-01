const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    CannotOpenDatabase,
    MigrationFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ExecFailed,
    UnexpectedColumnType,
    OutOfMemory,
};

pub const SCHEMA_VERSION: u32 = 1;

const SCHEMA_SQL =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA foreign_keys = ON;
    \\
    \\CREATE TABLE IF NOT EXISTS workspaces (
    \\  id TEXT PRIMARY KEY,
    \\  title TEXT NOT NULL,
    \\  custom_title TEXT,
    \\  directory TEXT NOT NULL DEFAULT '',
    \\  color TEXT,
    \\  pinned INTEGER NOT NULL DEFAULT 0,
    \\  order_index INTEGER NOT NULL,
    \\  focused_pane_id TEXT,
    \\  created_at INTEGER NOT NULL,
    \\  last_activity_at INTEGER NOT NULL,
    \\  closed_at INTEGER,
    \\  pane_tree_json TEXT NOT NULL DEFAULT '{}'
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspace_history (
    \\  seq INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  workspace_id TEXT NOT NULL,
    \\  event_type TEXT NOT NULL,
    \\  payload_json TEXT NOT NULL,
    \\  at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS selection (
    \\  k TEXT PRIMARY KEY,
    \\  v TEXT
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_history_workspace ON workspace_history(workspace_id, seq);
    \\CREATE INDEX IF NOT EXISTS idx_workspaces_open ON workspaces(closed_at) WHERE closed_at IS NULL;
;

pub const Db = struct {
    handle: *c.sqlite3,
    alloc: std.mem.Allocator,

    /// Open or create the database at `path`. Runs schema migrations.
    pub fn open(alloc: std.mem.Allocator, path: []const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const path_z = alloc.dupeZ(u8, path) catch return Error.OutOfMemory;
        defer alloc.free(path_z);
        const rc = c.sqlite3_open(path_z.ptr, &handle);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return Error.CannotOpenDatabase;
        }
        var db = Db{ .handle = handle.?, .alloc = alloc };
        migrate(&db) catch |err| {
            _ = c.sqlite3_close(db.handle);
            return err;
        };
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn exec(self: *Db, sql: []const u8) Error!void {
        const sql_z = self.alloc.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.alloc.free(sql_z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) c.sqlite3_free(errmsg);
            return Error.ExecFailed;
        }
    }

    fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        const sql_z = self.alloc.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.alloc.free(sql_z);
        var handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z.ptr, -1, &handle, null);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_finalize(h);
            return Error.PrepareFailed;
        }
        return Stmt{ .handle = handle.?, .db = self };
    }

    pub fn beginTransaction(self: *Db) Error!void {
        try self.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(self: *Db) Error!void {
        try self.exec("COMMIT");
    }

    pub fn rollback(self: *Db) Error!void {
        try self.exec("ROLLBACK");
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db: *Db,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindText(self: *Stmt, index: c_int, value: []const u8) Error!void {
        // Pass NULL destructor (SQLITE_STATIC): sqlite does not copy. Callers
        // must keep `value` alive until execOnce/step completes. That's the
        // case everywhere in this module because we prepare/bind/step/finalize
        // synchronously in one function, against caller-owned buffers that
        // outlive the call.
        const rc = c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), null);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindTextOpt(self: *Stmt, index: c_int, value: ?[]const u8) Error!void {
        if (value) |v| return self.bindText(index, v);
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt64(self: *Stmt, index: c_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.handle, index, value);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt64Opt(self: *Stmt, index: c_int, value: ?i64) Error!void {
        if (value) |v| return self.bindInt64(index, v);
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindDouble(self: *Stmt, index: c_int, value: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.handle, index, value);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindDoubleOpt(self: *Stmt, index: c_int, value: ?f64) Error!void {
        if (value) |v| return self.bindDouble(index, v);
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindBool(self: *Stmt, index: c_int, value: bool) Error!void {
        return self.bindInt64(index, if (value) 1 else 0);
    }

    /// Execute statement expecting no rows (INSERT/UPDATE/DELETE).
    pub fn execOnce(self: *Stmt) Error!void {
        const rc = c.sqlite3_step(self.handle);
        if (rc != c.SQLITE_DONE) return Error.StepFailed;
    }

    /// Step and return true if a row is available.
    pub fn step(self: *Stmt) Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return Error.StepFailed;
    }

    pub fn columnText(self: *Stmt, index: c_int, alloc: std.mem.Allocator) Error!?[]u8 {
        const ctype = c.sqlite3_column_type(self.handle, index);
        if (ctype == c.SQLITE_NULL) return null;
        const ptr_opt = c.sqlite3_column_text(self.handle, index);
        const ptr = ptr_opt orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, index));
        const slice = ptr[0..len];
        return alloc.dupe(u8, slice) catch Error.OutOfMemory;
    }

    pub fn columnInt64(self: *Stmt, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnInt64Opt(self: *Stmt, index: c_int) ?i64 {
        const ctype = c.sqlite3_column_type(self.handle, index);
        if (ctype == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.handle, index);
    }

    pub fn columnDouble(self: *Stmt, index: c_int) f64 {
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn columnDoubleOpt(self: *Stmt, index: c_int) ?f64 {
        const ctype = c.sqlite3_column_type(self.handle, index);
        if (ctype == c.SQLITE_NULL) return null;
        return c.sqlite3_column_double(self.handle, index);
    }

    pub fn columnBool(self: *Stmt, index: c_int) bool {
        return self.columnInt64(index) != 0;
    }
};

fn migrate(db: *Db) Error!void {
    // Pragmas + CREATE TABLE IF NOT EXISTS. Idempotent.
    try db.exec(SCHEMA_SQL);

    // Track schema_version via user_version pragma for future migrations.
    // (Empty today; on bump we'll branch on current_version.)
    var stmt = try db.prepare("PRAGMA user_version;");
    defer stmt.deinit();
    var current: i64 = 0;
    if (try stmt.step()) {
        current = stmt.columnInt64(0);
    }
    if (current < @as(i64, SCHEMA_VERSION)) {
        // Future: apply incremental migrations here when SCHEMA_VERSION > current.
        const set_sql = std.fmt.allocPrint(db.alloc, "PRAGMA user_version = {d};", .{SCHEMA_VERSION}) catch return Error.OutOfMemory;
        defer db.alloc.free(set_sql);
        try db.exec(set_sql);
    }
}

// ---------------------------------------------------------------------------
// Workspace + pane persistence.
//
// saveOpenWorkspaces writes the full open-workspaces set to disk. Called
// after every mutation so a daemon restart rehydrates correctly. The pane
// tree is stored as a JSON blob per workspace: matches the shape of
// workspace_registry.PaneNode (leaf/split union) without requiring a
// normalized-table rewrite of the existing in-memory registry.
// ---------------------------------------------------------------------------

pub const PersistedWorkspace = struct {
    id: []const u8,
    title: []const u8,
    custom_title: ?[]const u8 = null,
    directory: []const u8 = "",
    color: ?[]const u8 = null,
    pinned: bool = false,
    order_index: i64,
    focused_pane_id: ?[]const u8 = null,
    created_at: i64,
    last_activity_at: i64,
    closed_at: ?i64 = null,
    /// Serialized pane tree. Caller is responsible for JSON encoding/decoding
    /// against workspace_registry.PaneNode via serialize.zig.
    pane_tree_json: []const u8 = "{}",
};

/// Replace the full set of open workspaces in the DB. Preserves closed
/// workspaces (closed_at IS NOT NULL) so they remain queryable for history
/// and reopen.
pub fn saveOpenWorkspaces(db: *Db, workspaces: []const PersistedWorkspace, selected_id: ?[]const u8) Error!void {
    try db.beginTransaction();
    errdefer db.rollback() catch {};

    try db.exec("DELETE FROM workspaces WHERE closed_at IS NULL");

    const ws_sql =
        \\INSERT INTO workspaces (id, title, custom_title, directory, color, pinned, order_index, focused_pane_id, created_at, last_activity_at, closed_at, pane_tree_json)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
    ;
    for (workspaces) |ws| {
        var stmt = try db.prepare(ws_sql);
        defer stmt.deinit();
        try stmt.bindText(1, ws.id);
        try stmt.bindText(2, ws.title);
        try stmt.bindTextOpt(3, ws.custom_title);
        try stmt.bindText(4, ws.directory);
        try stmt.bindTextOpt(5, ws.color);
        try stmt.bindBool(6, ws.pinned);
        try stmt.bindInt64(7, ws.order_index);
        try stmt.bindTextOpt(8, ws.focused_pane_id);
        try stmt.bindInt64(9, ws.created_at);
        try stmt.bindInt64(10, ws.last_activity_at);
        try stmt.bindText(11, ws.pane_tree_json);
        try stmt.execOnce();
    }

    {
        var stmt = try db.prepare("INSERT INTO selection (k, v) VALUES ('selected_workspace_id', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v");
        defer stmt.deinit();
        try stmt.bindTextOpt(1, selected_id);
        try stmt.execOnce();
    }

    try db.commit();
}

pub const LoadedState = struct {
    workspaces: []PersistedWorkspace,
    selected_id: ?[]const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *LoadedState) void {
        for (self.workspaces) |ws| {
            self.alloc.free(ws.id);
            self.alloc.free(ws.title);
            if (ws.custom_title) |v| self.alloc.free(v);
            self.alloc.free(ws.directory);
            if (ws.color) |v| self.alloc.free(v);
            if (ws.focused_pane_id) |v| self.alloc.free(v);
            self.alloc.free(ws.pane_tree_json);
        }
        self.alloc.free(self.workspaces);
        if (self.selected_id) |v| self.alloc.free(v);
    }
};

/// Load all open workspaces (closed_at IS NULL) ordered by order_index.
/// Returns an owned allocation; caller must call deinit.
pub fn loadOpenWorkspaces(db: *Db, alloc: std.mem.Allocator) Error!LoadedState {
    var ws_list: std.ArrayList(PersistedWorkspace) = .empty;
    errdefer {
        for (ws_list.items) |ws| {
            alloc.free(ws.id);
            alloc.free(ws.title);
            if (ws.custom_title) |v| alloc.free(v);
            alloc.free(ws.directory);
            if (ws.color) |v| alloc.free(v);
            if (ws.focused_pane_id) |v| alloc.free(v);
            alloc.free(ws.pane_tree_json);
        }
        ws_list.deinit(alloc);
    }

    var stmt = try db.prepare(
        \\SELECT id, title, custom_title, directory, color, pinned, order_index, focused_pane_id, created_at, last_activity_at, closed_at, pane_tree_json
        \\FROM workspaces WHERE closed_at IS NULL ORDER BY order_index ASC
    );
    defer stmt.deinit();
    while (try stmt.step()) {
        const id = (try stmt.columnText(0, alloc)) orelse return Error.UnexpectedColumnType;
        const title = (try stmt.columnText(1, alloc)) orelse return Error.UnexpectedColumnType;
        const custom_title = try stmt.columnText(2, alloc);
        const directory = (try stmt.columnText(3, alloc)) orelse try alloc.dupe(u8, "");
        const color = try stmt.columnText(4, alloc);
        const pinned = stmt.columnBool(5);
        const order_index = stmt.columnInt64(6);
        const focused_pane_id = try stmt.columnText(7, alloc);
        const created_at = stmt.columnInt64(8);
        const last_activity_at = stmt.columnInt64(9);
        const closed_at = stmt.columnInt64Opt(10);
        const pane_tree_json = (try stmt.columnText(11, alloc)) orelse try alloc.dupe(u8, "{}");
        try ws_list.append(alloc, .{
            .id = id,
            .title = title,
            .custom_title = custom_title,
            .directory = directory,
            .color = color,
            .pinned = pinned,
            .order_index = order_index,
            .focused_pane_id = focused_pane_id,
            .created_at = created_at,
            .last_activity_at = last_activity_at,
            .closed_at = closed_at,
            .pane_tree_json = pane_tree_json,
        });
    }

    var selected_id: ?[]const u8 = null;
    {
        var sel_stmt = try db.prepare("SELECT v FROM selection WHERE k = 'selected_workspace_id'");
        defer sel_stmt.deinit();
        if (try sel_stmt.step()) {
            selected_id = try sel_stmt.columnText(0, alloc);
        }
    }

    return LoadedState{
        .workspaces = try ws_list.toOwnedSlice(alloc),
        .selected_id = selected_id,
        .alloc = alloc,
    };
}

// ---------------------------------------------------------------------------
// History log.
// ---------------------------------------------------------------------------

pub const HistoryEvent = struct {
    workspace_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    at: i64,
};

pub fn appendHistory(db: *Db, event: HistoryEvent) Error!void {
    var stmt = try db.prepare("INSERT INTO workspace_history (workspace_id, event_type, payload_json, at) VALUES (?, ?, ?, ?)");
    defer stmt.deinit();
    try stmt.bindText(1, event.workspace_id);
    try stmt.bindText(2, event.event_type);
    try stmt.bindText(3, event.payload_json);
    try stmt.bindInt64(4, event.at);
    try stmt.execOnce();
}

pub const HistoryQuery = struct {
    workspace_id: ?[]const u8 = null,
    limit: i64 = 100,
    before_seq: ?i64 = null,
};

pub const HistoryRow = struct {
    seq: i64,
    workspace_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    at: i64,
};

pub const HistoryList = struct {
    rows: []HistoryRow,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *HistoryList) void {
        for (self.rows) |row| {
            self.alloc.free(row.workspace_id);
            self.alloc.free(row.event_type);
            self.alloc.free(row.payload_json);
        }
        self.alloc.free(self.rows);
    }
};

pub fn queryHistory(db: *Db, alloc: std.mem.Allocator, q: HistoryQuery) Error!HistoryList {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(alloc);
    sql.appendSlice(alloc, "SELECT seq, workspace_id, event_type, payload_json, at FROM workspace_history WHERE 1=1") catch return Error.OutOfMemory;
    if (q.workspace_id != null) sql.appendSlice(alloc, " AND workspace_id = ?") catch return Error.OutOfMemory;
    if (q.before_seq != null) sql.appendSlice(alloc, " AND seq < ?") catch return Error.OutOfMemory;
    sql.appendSlice(alloc, " ORDER BY seq DESC LIMIT ?") catch return Error.OutOfMemory;

    var stmt = try db.prepare(sql.items);
    defer stmt.deinit();
    var idx: c_int = 1;
    if (q.workspace_id) |wid| {
        try stmt.bindText(idx, wid);
        idx += 1;
    }
    if (q.before_seq) |bs| {
        try stmt.bindInt64(idx, bs);
        idx += 1;
    }
    try stmt.bindInt64(idx, q.limit);

    var list: std.ArrayList(HistoryRow) = .empty;
    errdefer {
        for (list.items) |row| {
            alloc.free(row.workspace_id);
            alloc.free(row.event_type);
            alloc.free(row.payload_json);
        }
        list.deinit(alloc);
    }
    while (try stmt.step()) {
        const seq = stmt.columnInt64(0);
        const wid = (try stmt.columnText(1, alloc)) orelse return Error.UnexpectedColumnType;
        const etype = (try stmt.columnText(2, alloc)) orelse return Error.UnexpectedColumnType;
        const payload = (try stmt.columnText(3, alloc)) orelse return Error.UnexpectedColumnType;
        const at = stmt.columnInt64(4);
        try list.append(alloc, .{
            .seq = seq,
            .workspace_id = wid,
            .event_type = etype,
            .payload_json = payload,
            .at = at,
        });
    }

    return HistoryList{ .rows = try list.toOwnedSlice(alloc), .alloc = alloc };
}

/// Mark a workspace as closed; its row persists with closed_at set. Called
/// when a workspace is closed so it survives in history for reopen.
pub fn markWorkspaceClosed(db: *Db, workspace_id: []const u8, at: i64) Error!void {
    var stmt = try db.prepare("UPDATE workspaces SET closed_at = ? WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindInt64(1, at);
    try stmt.bindText(2, workspace_id);
    try stmt.execOnce();
}

pub fn clearHistory(db: *Db) Error!void {
    try db.exec("DELETE FROM workspace_history");
    try db.exec("VACUUM");
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "open + close in-memory db runs migrations" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    // Second open on the same handle is idempotent via IF NOT EXISTS.
    try migrate(&db);
}

test "saveOpenWorkspaces + loadOpenWorkspaces roundtrip" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    const tree =
        \\{"leaf":{"id":"pane-1","pane_type":"terminal","session_id":"sess-a","title":"tab one","directory":"/tmp"}}
    ;
    const workspaces = [_]PersistedWorkspace{
        .{
            .id = "ws-a",
            .title = "alpha",
            .directory = "/Users/me",
            .pinned = true,
            .order_index = 0,
            .focused_pane_id = "pane-1",
            .created_at = 1000,
            .last_activity_at = 2000,
            .pane_tree_json = tree,
        },
    };
    try saveOpenWorkspaces(&db, &workspaces, "ws-a");

    var loaded = try loadOpenWorkspaces(&db, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.workspaces.len);
    try std.testing.expectEqualStrings("ws-a", loaded.workspaces[0].id);
    try std.testing.expectEqualStrings("alpha", loaded.workspaces[0].title);
    try std.testing.expect(loaded.workspaces[0].pinned);
    try std.testing.expectEqualStrings(tree, loaded.workspaces[0].pane_tree_json);
    try std.testing.expect(loaded.selected_id != null);
    try std.testing.expectEqualStrings("ws-a", loaded.selected_id.?);
}

test "appendHistory + queryHistory" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    try appendHistory(&db, .{ .workspace_id = "ws-a", .event_type = "created", .payload_json = "{}", .at = 100 });
    try appendHistory(&db, .{ .workspace_id = "ws-a", .event_type = "renamed", .payload_json = "{\"new\":\"x\"}", .at = 200 });
    try appendHistory(&db, .{ .workspace_id = "ws-b", .event_type = "created", .payload_json = "{}", .at = 300 });

    var all = try queryHistory(&db, std.testing.allocator, .{});
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 3), all.rows.len);
    // Newest first.
    try std.testing.expectEqualStrings("ws-b", all.rows[0].workspace_id);

    var only_a = try queryHistory(&db, std.testing.allocator, .{ .workspace_id = "ws-a" });
    defer only_a.deinit();
    try std.testing.expectEqual(@as(usize, 2), only_a.rows.len);
    try std.testing.expectEqualStrings("renamed", only_a.rows[0].event_type);
}

test "markWorkspaceClosed keeps row out of loadOpenWorkspaces" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    const workspaces = [_]PersistedWorkspace{
        .{ .id = "ws-closed", .title = "old", .order_index = 0, .created_at = 1, .last_activity_at = 1 },
        .{ .id = "ws-open", .title = "still here", .order_index = 1, .created_at = 2, .last_activity_at = 2 },
    };
    try saveOpenWorkspaces(&db, &workspaces, null);
    try markWorkspaceClosed(&db, "ws-closed", 500);

    var loaded = try loadOpenWorkspaces(&db, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.workspaces.len);
    try std.testing.expectEqualStrings("ws-open", loaded.workspaces[0].id);

    // Closed workspace survives for history queries / reopen.
    // (Tested indirectly: saveOpenWorkspaces only touches closed_at IS NULL rows.)
}

test "clearHistory wipes the table" {
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    try appendHistory(&db, .{ .workspace_id = "ws-a", .event_type = "created", .payload_json = "{}", .at = 100 });
    try clearHistory(&db);
    var all = try queryHistory(&db, std.testing.allocator, .{});
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 0), all.rows.len);
}

test "user-controlled strings are SQL-injection safe" {
    // Attempting classic SQL injection via a workspace title. Because every
    // user string is bound via sqlite3_bind_text rather than concatenated
    // into SQL, the payload should be stored verbatim and have no effect
    // on the schema. This test is a regression marker: if anyone ever
    // introduces string concatenation into the SQL body, this will break
    // (because the DROP would succeed or syntax would break).
    var db = try Db.open(std.testing.allocator, ":memory:");
    defer db.close();

    const injection = "'); DROP TABLE workspaces; --";
    const workspaces = [_]PersistedWorkspace{
        .{
            .id = "ws-a",
            .title = injection,
            .directory = injection,
            .order_index = 0,
            .created_at = 1,
            .last_activity_at = 1,
        },
    };
    try saveOpenWorkspaces(&db, &workspaces, null);

    var loaded = try loadOpenWorkspaces(&db, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.workspaces.len);
    try std.testing.expectEqualStrings(injection, loaded.workspaces[0].title);
    try std.testing.expectEqualStrings(injection, loaded.workspaces[0].directory);

    // History append is also bind-backed. Hostile workspace_id and
    // payload must round-trip verbatim.
    try appendHistory(&db, .{
        .workspace_id = injection,
        .event_type = injection,
        .payload_json = injection,
        .at = 42,
    });
    var hist = try queryHistory(&db, std.testing.allocator, .{ .workspace_id = injection });
    defer hist.deinit();
    try std.testing.expectEqual(@as(usize, 1), hist.rows.len);
    try std.testing.expectEqualStrings(injection, hist.rows[0].workspace_id);
    try std.testing.expectEqualStrings(injection, hist.rows[0].event_type);
}
