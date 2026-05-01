const std = @import("std");
const outbound_queue = @import("outbound_queue.zig");

pub const PaneType = enum {
    terminal,
    browser,

    pub fn jsonStringify(self: PaneType, options: anytype, writer: anytype) !void {
        _ = options;
        try writer.print("\"{s}\"", .{@tagName(self)});
    }
};

pub const SplitDirection = enum {
    horizontal,
    vertical,

    pub fn jsonStringify(self: SplitDirection, options: anytype, writer: anytype) !void {
        _ = options;
        try writer.print("\"{s}\"", .{@tagName(self)});
    }
};

pub const PaneLeaf = struct {
    id: []const u8,
    pane_type: PaneType,
    session_id: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: []const u8 = "",
    directory: []const u8 = "",
};

pub const PaneSplit = struct {
    direction: SplitDirection,
    ratio: f32,
    first: *PaneNode,
    second: *PaneNode,
};

pub const PaneNode = union(enum) {
    leaf: PaneLeaf,
    split: PaneSplit,

    pub fn deinit(self: *PaneNode, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => |leaf| {
                alloc.free(leaf.id);
                if (leaf.session_id) |s| alloc.free(s);
                if (leaf.url) |u| alloc.free(u);
                if (leaf.title.len > 0) alloc.free(leaf.title);
                if (leaf.directory.len > 0) alloc.free(leaf.directory);
            },
            .split => |*s| {
                s.first.deinit(alloc);
                alloc.destroy(s.first);
                s.second.deinit(alloc);
                alloc.destroy(s.second);
            },
        }
    }

    pub fn findLeaf(self: *PaneNode, pane_id: []const u8) ?*PaneLeaf {
        switch (self.*) {
            .leaf => |*leaf| {
                if (std.mem.eql(u8, leaf.id, pane_id)) return leaf;
                return null;
            },
            .split => |*s| {
                if (s.first.findLeaf(pane_id)) |found| return found;
                return s.second.findLeaf(pane_id);
            },
        }
    }

    pub fn collectLeaves(self: *const PaneNode, alloc: std.mem.Allocator) ![]PaneLeaf {
        var list: std.ArrayList(PaneLeaf) = .empty;
        try self.collectLeavesInto(&list, alloc);
        return try list.toOwnedSlice(alloc);
    }

    fn collectLeavesInto(self: *const PaneNode, list: *std.ArrayList(PaneLeaf), alloc: std.mem.Allocator) !void {
        switch (self.*) {
            .leaf => |leaf| try list.append(alloc, leaf),
            .split => |s| {
                try s.first.collectLeavesInto(list, alloc);
                try s.second.collectLeavesInto(list, alloc);
            },
        }
    }
};

pub const WorkspaceOrigin = enum {
    daemon_created,
    mac_sync,
};

pub const Workspace = struct {
    id: []const u8,
    title: []const u8,
    custom_title: ?[]const u8 = null,
    color: ?[]const u8 = null,
    directory: []const u8 = "",
    preview: []const u8 = "",
    phase: []const u8 = "idle",
    unread_count: u32 = 0,
    pinned: bool = false,
    session_id: ?[]const u8 = null,
    root_pane: *PaneNode,
    focused_pane_id: ?[]const u8 = null,
    created_at: i64,
    last_activity_at: i64,
    origin: WorkspaceOrigin = .daemon_created,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    workspaces: std.StringHashMap(Workspace),
    order: std.ArrayList([]const u8),
    selected_id: ?[]const u8 = null,
    change_seq: u64 = 0,
    next_pane_num: u64 = 1,
    next_workspace_num: u64 = 1,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .alloc = alloc,
            .workspaces = std.StringHashMap(Workspace).init(alloc),
            .order = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.workspaces.iterator();
        while (iter.next()) |entry| {
            freeWorkspace(self.alloc, entry.value_ptr);
        }
        self.workspaces.deinit();
        for (self.order.items) |id| self.alloc.free(id);
        self.order.deinit(self.alloc);
        if (self.selected_id) |s| self.alloc.free(s);
    }

    pub fn create(self: *Registry, title: ?[]const u8, directory: ?[]const u8) ![]const u8 {
        return self.createWithId(null, title, directory);
    }

    pub fn createWithId(self: *Registry, explicit_id: ?[]const u8, title: ?[]const u8, directory: ?[]const u8) ![]const u8 {
        const id = if (explicit_id) |eid| try self.alloc.dupe(u8, eid) else try self.generateId("ws");
        errdefer self.alloc.free(id);

        const pane_id = try self.generatePaneId();
        errdefer self.alloc.free(pane_id);

        const root = try self.alloc.create(PaneNode);
        errdefer self.alloc.destroy(root);

        const resolved_title = if (title) |t|
            try self.alloc.dupe(u8, t)
        else blk: {
            const num = self.next_workspace_num;
            self.next_workspace_num += 1;
            break :blk try std.fmt.allocPrint(self.alloc, "Workspace {d}", .{num});
        };
        errdefer self.alloc.free(resolved_title);

        const dir = if (directory) |d| try self.alloc.dupe(u8, d) else try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(dir);

        root.* = .{ .leaf = .{
            .id = pane_id,
            .pane_type = .terminal,
            .title = try self.alloc.dupe(u8, ""),
            .directory = try self.alloc.dupe(u8, ""),
        } };

        const now = std.time.milliTimestamp();
        const ws = Workspace{
            .id = id,
            .title = resolved_title,
            .directory = dir,
            .preview = try self.alloc.dupe(u8, ""),
            .phase = try self.alloc.dupe(u8, "idle"),
            .root_pane = root,
            .focused_pane_id = try self.alloc.dupe(u8, pane_id),
            .created_at = now,
            .last_activity_at = now,
            .origin = .daemon_created,
        };

        const order_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(order_id);
        try self.order.append(self.alloc, order_id);
        try self.workspaces.put(id, ws);

        if (self.selected_id == null) {
            self.selected_id = try self.alloc.dupe(u8, id);
        }

        self.change_seq += 1;
        return id;
    }

    pub fn rename(self: *Registry, workspace_id: []const u8, title: []const u8) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        const new_title = try self.alloc.dupe(u8, title);
        self.alloc.free(ws.title);
        ws.title = new_title;
        ws.last_activity_at = std.time.milliTimestamp();
        self.change_seq += 1;
    }

    pub fn setPin(self: *Registry, workspace_id: []const u8, pinned: bool) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        ws.pinned = pinned;
        self.change_seq += 1;
    }

    pub fn setColor(self: *Registry, workspace_id: []const u8, color: []const u8) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        if (ws.color) |old| self.alloc.free(old);
        if (color.len == 0) {
            ws.color = null;
        } else {
            ws.color = try self.alloc.dupe(u8, color);
        }
        self.change_seq += 1;
    }

    pub fn close(self: *Registry, workspace_id: []const u8) !void {
        var ws = self.workspaces.fetchRemove(workspace_id) orelse return error.WorkspaceNotFound;
        freeWorkspace(self.alloc, &ws.value);

        // Remove from order
        for (self.order.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, workspace_id)) {
                self.alloc.free(id);
                _ = self.order.orderedRemove(i);
                break;
            }
        }

        // Update selection
        if (self.selected_id) |sel| {
            if (std.mem.eql(u8, sel, workspace_id)) {
                self.alloc.free(sel);
                self.selected_id = if (self.order.items.len > 0)
                    try self.alloc.dupe(u8, self.order.items[0])
                else
                    null;
            }
        }

        self.change_seq += 1;
    }

    pub fn select(self: *Registry, workspace_id: []const u8) !void {
        if (!self.workspaces.contains(workspace_id)) return error.WorkspaceNotFound;
        if (self.selected_id) |old| self.alloc.free(old);
        self.selected_id = try self.alloc.dupe(u8, workspace_id);
        self.change_seq += 1;
    }

    pub fn get(self: *Registry, workspace_id: []const u8) ?*Workspace {
        return self.workspaces.getPtr(workspace_id);
    }

    pub fn splitPane(self: *Registry, workspace_id: []const u8, pane_id: []const u8, direction: SplitDirection, pane_type: PaneType) ![]const u8 {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        const target = ws.root_pane.findLeaf(pane_id) orelse return error.PaneNotFound;

        const new_pane_id = try self.generatePaneId();
        errdefer self.alloc.free(new_pane_id);

        // Create new leaf
        const new_leaf = try self.alloc.create(PaneNode);
        errdefer self.alloc.destroy(new_leaf);
        new_leaf.* = .{ .leaf = .{
            .id = new_pane_id,
            .pane_type = pane_type,
            .title = try self.alloc.dupe(u8, ""),
            .directory = try self.alloc.dupe(u8, ""),
        } };

        // Move existing leaf to a new node
        const old_leaf = try self.alloc.create(PaneNode);
        errdefer self.alloc.destroy(old_leaf);
        old_leaf.* = .{ .leaf = target.* };

        // Replace the target with a split
        // We need to find the parent pointer. Since target is a pointer to the leaf
        // data inside a PaneNode, we find the PaneNode that contains it.
        const target_node = self.findPaneNode(ws.root_pane, pane_id) orelse return error.PaneNotFound;
        target_node.* = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = old_leaf,
            .second = new_leaf,
        } };

        ws.last_activity_at = std.time.milliTimestamp();
        self.change_seq += 1;
        return new_pane_id;
    }

    pub fn closePane(self: *Registry, workspace_id: []const u8, pane_id: []const u8) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;

        // If root is the target leaf, close the entire workspace
        switch (ws.root_pane.*) {
            .leaf => |leaf| {
                if (std.mem.eql(u8, leaf.id, pane_id)) {
                    return self.close(workspace_id);
                }
                return error.PaneNotFound;
            },
            .split => {},
        }

        // Find and remove the pane from the tree
        try self.removePaneFromTree(ws.root_pane, pane_id);

        // Update focused pane if needed
        if (ws.focused_pane_id) |fid| {
            if (std.mem.eql(u8, fid, pane_id)) {
                self.alloc.free(fid);
                const leaves = try ws.root_pane.collectLeaves(self.alloc);
                defer self.alloc.free(leaves);
                ws.focused_pane_id = if (leaves.len > 0)
                    try self.alloc.dupe(u8, leaves[0].id)
                else
                    null;
            }
        }

        ws.last_activity_at = std.time.milliTimestamp();
        self.change_seq += 1;
    }

    pub fn focusPane(self: *Registry, workspace_id: []const u8, pane_id: []const u8) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        if (ws.root_pane.findLeaf(pane_id) == null) return error.PaneNotFound;
        if (ws.focused_pane_id) |old| self.alloc.free(old);
        ws.focused_pane_id = try self.alloc.dupe(u8, pane_id);
        self.change_seq += 1;
    }

    pub fn resizePane(self: *Registry, workspace_id: []const u8, pane_id: []const u8, ratio: f32) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        if (!adjustSplitRatioForChild(ws.root_pane, pane_id, ratio)) return error.PaneNotFound;
        ws.last_activity_at = std.time.milliTimestamp();
        self.change_seq += 1;
    }

    pub fn bindSession(self: *Registry, workspace_id: []const u8, pane_id: []const u8, session_id: []const u8) !void {
        const ws = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        const leaf = ws.root_pane.findLeaf(pane_id) orelse return error.PaneNotFound;
        if (leaf.session_id) |old| self.alloc.free(old);
        leaf.session_id = try self.alloc.dupe(u8, session_id);
        self.change_seq += 1;
    }

    // --- Helpers ---

    fn findPaneNode(self: *Registry, root: *PaneNode, pane_id: []const u8) ?*PaneNode {
        _ = self;
        return findPaneNodeRecursive(root, pane_id);
    }

    fn findPaneNodeRecursive(node: *PaneNode, pane_id: []const u8) ?*PaneNode {
        switch (node.*) {
            .leaf => |leaf| {
                if (std.mem.eql(u8, leaf.id, pane_id)) return node;
                return null;
            },
            .split => |*s| {
                if (findPaneNodeRecursive(s.first, pane_id)) |found| return found;
                return findPaneNodeRecursive(s.second, pane_id);
            },
        }
    }

    fn adjustSplitRatioForChild(node: *PaneNode, pane_id: []const u8, ratio: f32) bool {
        switch (node.*) {
            .leaf => return false,
            .split => |*s| {
                if (isLeafWithId(s.first, pane_id)) {
                    s.ratio = std.math.clamp(ratio, 0.05, 0.95);
                    return true;
                }
                if (isLeafWithId(s.second, pane_id)) {
                    s.ratio = std.math.clamp(1.0 - ratio, 0.05, 0.95);
                    return true;
                }
                return adjustSplitRatioForChild(s.first, pane_id, ratio) or
                    adjustSplitRatioForChild(s.second, pane_id, ratio);
            },
        }
    }

    fn removePaneFromTree(self: *Registry, node: *PaneNode, pane_id: []const u8) !void {
        switch (node.*) {
            .leaf => return error.PaneNotFound,
            .split => |*s| {
                // Check if first child is the target
                if (isLeafWithId(s.first, pane_id)) {
                    var old = s.first;
                    const survivor = s.second.*;
                    old.deinit(self.alloc);
                    self.alloc.destroy(old);
                    self.alloc.destroy(s.second);
                    node.* = survivor;
                    return;
                }
                // Check if second child is the target
                if (isLeafWithId(s.second, pane_id)) {
                    var old = s.second;
                    const survivor = s.first.*;
                    old.deinit(self.alloc);
                    self.alloc.destroy(old);
                    self.alloc.destroy(s.first);
                    node.* = survivor;
                    return;
                }
                // Recurse
                self.removePaneFromTree(s.first, pane_id) catch {};
                self.removePaneFromTree(s.second, pane_id) catch {};
            },
        }
    }

    fn isLeafWithId(node: *const PaneNode, pane_id: []const u8) bool {
        switch (node.*) {
            .leaf => |leaf| return std.mem.eql(u8, leaf.id, pane_id),
            .split => return false,
        }
    }

    fn freeWorkspace(alloc: std.mem.Allocator, ws: *Workspace) void {
        alloc.free(ws.id);
        alloc.free(ws.title);
        if (ws.custom_title) |t| alloc.free(t);
        if (ws.color) |c| alloc.free(c);
        if (ws.directory.len > 0) alloc.free(ws.directory);
        alloc.free(ws.preview);
        alloc.free(ws.phase);
        if (ws.session_id) |s| alloc.free(s);
        if (ws.focused_pane_id) |f| alloc.free(f);
        ws.root_pane.deinit(alloc);
        alloc.destroy(ws.root_pane);
    }

    fn generateId(self: *Registry, prefix: []const u8) ![]const u8 {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const hex = std.fmt.bytesToHex(buf, .lower);
        return try std.fmt.allocPrint(self.alloc, "{s}-{s}", .{ prefix, hex[0..12] });
    }

    pub fn generatePaneId(self: *Registry) ![]const u8 {
        const num = self.next_pane_num;
        self.next_pane_num += 1;
        return try std.fmt.allocPrint(self.alloc, "pane-{d}", .{num});
    }

    /// Upsert workspaces from a mac-side sync payload. Historical behavior
    /// was destructive (full replace), which caused iOS session bindings
    /// to disappear every time mac's surfaces lacked `savedDaemonSessionID`
    /// (Exec mode or daemon not yet ready). Now:
    ///
    ///   * If a workspace already exists, we update its metadata in place
    ///     (title, color, pinned, directory, phase, preview, unread).
    ///     When the payload carries per-pane session_ids we rebuild the
    ///     pane tree; when it doesn't, we preserve the existing tree so
    ///     daemon-owned session bindings survive.
    ///   * Workspaces in the payload that aren't in the registry are
    ///     created.
    ///   * Daemon-created workspaces missing from the payload are preserved
    ///     when they own distinct sessions, which protects iOS-created
    ///     workspaces that have not round-tripped to mac's TabManager yet.
    ///     Mac-synced workspaces missing from an authoritative sync are
    ///     pruned, so stale pre-restart mac workspaces cannot live forever.
    ///   * Missing workspaces that duplicate incoming session ids are pruned.
    ///     This handles mac relaunch/session-restore cases where the same
    ///     shells are synced back under freshly minted workspace ids.
    ///
    /// This aligns `workspace.sync` with the SSOT direction where the
    /// daemon owns pane/session state and mac just pushes metadata.
    pub fn syncAll(
        self: *Registry,
        workspaces_data: []const SyncWorkspace,
        selected_id: ?[]const u8,
        prune_sessionless_missing: bool,
    ) !void {
        var incoming_ids = std.StringHashMap(void).init(self.alloc);
        defer incoming_ids.deinit();
        var incoming_session_ids = std.StringHashMap(void).init(self.alloc);
        defer incoming_session_ids.deinit();

        for (workspaces_data) |ws_data| {
            try incoming_ids.put(ws_data.id, {});
            try addIncomingSessionId(&incoming_session_ids, ws_data.session_id);
            for (ws_data.session_ids) |sid| {
                try addIncomingSessionId(&incoming_session_ids, sid);
            }
            for (ws_data.panes) |pane| {
                try addIncomingSessionId(&incoming_session_ids, pane.session_id);
            }
        }

        var ids_to_prune: std.ArrayList([]const u8) = .empty;
        defer {
            for (ids_to_prune.items) |id| self.alloc.free(id);
            ids_to_prune.deinit(self.alloc);
        }

        const now_ms = std.time.milliTimestamp();
        for (self.order.items) |existing_id| {
            if (incoming_ids.contains(existing_id)) continue;
            const existing = self.workspaces.getPtr(existing_id) orelse continue;
            if (!shouldPruneMissingWorkspace(existing, &incoming_session_ids, now_ms, prune_sessionless_missing)) continue;

            const id_copy = try self.alloc.dupe(u8, existing_id);
            errdefer self.alloc.free(id_copy);
            try ids_to_prune.append(self.alloc, id_copy);
        }

        for (ids_to_prune.items) |id| {
            try self.close(id);
        }

        // Insert new workspaces in order
        for (workspaces_data) |ws_data| {
            // Build pane tree from per-pane metadata (preferred) or session_ids.
            const sync_panes = ws_data.panes;
            const all_sids = ws_data.session_ids;

            // UPSERT PATH: if this workspace already exists, update its
            // metadata in place. Only rebuild the pane tree when the
            // payload carries session ids; otherwise preserve daemon-owned
            // panes so iOS-bound shells don't vanish when mac's surfaces
            // happen to lack savedDaemonSessionID (Exec mode, daemon-not-ready).
            if (self.workspaces.getPtr(ws_data.id)) |existing| {
                // Replace string-valued fields in place.
                self.alloc.free(existing.title);
                existing.title = try self.alloc.dupe(u8, ws_data.title);
                self.alloc.free(existing.directory);
                existing.directory = try self.alloc.dupe(u8, ws_data.directory);
                self.alloc.free(existing.preview);
                existing.preview = try self.alloc.dupe(u8, ws_data.preview);
                self.alloc.free(existing.phase);
                existing.phase = try self.alloc.dupe(u8, ws_data.phase);
                if (existing.color) |old| self.alloc.free(old);
                existing.color = if (ws_data.color.len > 0) try self.alloc.dupe(u8, ws_data.color) else null;
                existing.unread_count = ws_data.unread_count;
                existing.pinned = ws_data.pinned;
                existing.origin = .mac_sync;
                if (ws_data.session_id) |s| {
                    if (existing.session_id) |old| self.alloc.free(old);
                    existing.session_id = try self.alloc.dupe(u8, s);
                }
                existing.last_activity_at = std.time.milliTimestamp();

                // Pane-tree policy: rebuild only when payload has real data.
                if (sync_panes.len > 0 or all_sids.len > 0) {
                    existing.root_pane.deinit(self.alloc);
                    self.alloc.destroy(existing.root_pane);
                    existing.root_pane = try self.buildPaneTreeFromSync(ws_data);
                }
                continue;
            }

            // NEW WORKSPACE PATH: original full build.
            const id = try self.alloc.dupe(u8, ws_data.id);
            errdefer self.alloc.free(id);

            const root: *PaneNode = root: {
                if (sync_panes.len > 0) {
                    // Rich pane data from macOS sync (has title + directory per pane).
                    if (sync_panes.len == 1) {
                        const pane_id = try self.generatePaneId();
                        const node = try self.alloc.create(PaneNode);
                        node.* = .{ .leaf = .{
                            .id = pane_id,
                            .pane_type = .terminal,
                            .session_id = try self.alloc.dupe(u8, sync_panes[0].session_id),
                            .title = try self.alloc.dupe(u8, sync_panes[0].title),
                            .directory = try self.alloc.dupe(u8, sync_panes[0].directory),
                        } };
                        break :root node;
                    }
                    var current: *PaneNode = try self.alloc.create(PaneNode);
                    const first_id = try self.generatePaneId();
                    current.* = .{ .leaf = .{
                        .id = first_id,
                        .pane_type = .terminal,
                        .session_id = try self.alloc.dupe(u8, sync_panes[0].session_id),
                        .title = try self.alloc.dupe(u8, sync_panes[0].title),
                        .directory = try self.alloc.dupe(u8, sync_panes[0].directory),
                    } };
                    for (sync_panes[1..]) |pane| {
                        const right_id = try self.generatePaneId();
                        const right = try self.alloc.create(PaneNode);
                        right.* = .{ .leaf = .{
                            .id = right_id,
                            .pane_type = .terminal,
                            .session_id = try self.alloc.dupe(u8, pane.session_id),
                            .title = try self.alloc.dupe(u8, pane.title),
                            .directory = try self.alloc.dupe(u8, pane.directory),
                        } };
                        const split = try self.alloc.create(PaneNode);
                        split.* = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .first = current, .second = right } };
                        current = split;
                    }
                    break :root current;
                } else if (all_sids.len > 1) {
                    // Fallback: bare session_ids without per-pane metadata.
                    var current: *PaneNode = try self.alloc.create(PaneNode);
                    const first_id = try self.generatePaneId();
                    current.* = .{ .leaf = .{
                        .id = first_id,
                        .pane_type = .terminal,
                        .session_id = try self.alloc.dupe(u8, all_sids[0]),
                        .directory = try self.alloc.dupe(u8, ws_data.directory),
                    } };
                    for (all_sids[1..]) |sid| {
                        const right_id = try self.generatePaneId();
                        const right = try self.alloc.create(PaneNode);
                        right.* = .{ .leaf = .{
                            .id = right_id,
                            .pane_type = .terminal,
                            .session_id = try self.alloc.dupe(u8, sid),
                            .directory = try self.alloc.dupe(u8, ws_data.directory),
                        } };
                        const split = try self.alloc.create(PaneNode);
                        split.* = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .first = current, .second = right } };
                        current = split;
                    }
                    break :root current;
                } else {
                    const pane_id = try self.generatePaneId();
                    const node = try self.alloc.create(PaneNode);
                    const sid = ws_data.session_id orelse
                        (if (all_sids.len == 1) all_sids[0] else null);
                    node.* = .{ .leaf = .{
                        .id = pane_id,
                        .pane_type = .terminal,
                        .session_id = if (sid) |s| try self.alloc.dupe(u8, s) else null,
                        .directory = try self.alloc.dupe(u8, ws_data.directory),
                    } };
                    break :root node;
                }
            };

            const ws = Workspace{
                .id = id,
                .title = try self.alloc.dupe(u8, ws_data.title),
                .directory = try self.alloc.dupe(u8, ws_data.directory),
                .preview = try self.alloc.dupe(u8, ws_data.preview),
                .phase = try self.alloc.dupe(u8, ws_data.phase),
                .color = if (ws_data.color.len > 0) try self.alloc.dupe(u8, ws_data.color) else null,
                .unread_count = ws_data.unread_count,
                .pinned = ws_data.pinned,
                .session_id = if (ws_data.session_id) |s| try self.alloc.dupe(u8, s) else null,
                .root_pane = root,
                .created_at = std.time.milliTimestamp(),
                .last_activity_at = std.time.milliTimestamp(),
                .origin = .mac_sync,
            };

            const order_id = try self.alloc.dupe(u8, id);
            try self.order.append(self.alloc, order_id);
            try self.workspaces.put(id, ws);
        }

        // Update selection
        if (self.selected_id) |old| self.alloc.free(old);
        self.selected_id = if (selected_id) |s| try self.alloc.dupe(u8, s) else null;

        self.change_seq += 1;
    }

    const sessionless_missing_workspace_prune_grace_ms: i64 = 10_000;

    fn addIncomingSessionId(set: *std.StringHashMap(void), maybe_session_id: ?[]const u8) !void {
        const session_id = maybe_session_id orelse return;
        if (session_id.len == 0) return;
        try set.put(session_id, {});
    }

    fn shouldPruneMissingWorkspace(
        ws: *const Workspace,
        incoming_session_ids: *const std.StringHashMap(void),
        now_ms: i64,
        prune_sessionless_missing: bool,
    ) bool {
        if (workspaceHasOverlappingSession(ws, incoming_session_ids)) return true;
        if (prune_sessionless_missing and ws.origin == .mac_sync) return true;
        if (!workspaceHasAnySession(ws)) {
            if (prune_sessionless_missing) return true;
            return now_ms - ws.last_activity_at >= sessionless_missing_workspace_prune_grace_ms;
        }
        return false;
    }

    fn workspaceHasAnySession(ws: *const Workspace) bool {
        if (ws.session_id) |session_id| {
            if (session_id.len > 0) return true;
        }
        return paneTreeHasAnySession(ws.root_pane);
    }

    fn paneTreeHasAnySession(node: *const PaneNode) bool {
        switch (node.*) {
            .leaf => |leaf| {
                if (leaf.session_id) |session_id| {
                    return session_id.len > 0;
                }
                return false;
            },
            .split => |split| {
                return paneTreeHasAnySession(split.first) or paneTreeHasAnySession(split.second);
            },
        }
    }

    fn workspaceHasOverlappingSession(ws: *const Workspace, incoming_session_ids: *const std.StringHashMap(void)) bool {
        if (incoming_session_ids.count() == 0) return false;
        if (ws.session_id) |session_id| {
            if (session_id.len > 0 and incoming_session_ids.contains(session_id)) return true;
        }
        return paneTreeHasOverlappingSession(ws.root_pane, incoming_session_ids);
    }

    fn paneTreeHasOverlappingSession(node: *const PaneNode, incoming_session_ids: *const std.StringHashMap(void)) bool {
        switch (node.*) {
            .leaf => |leaf| {
                if (leaf.session_id) |session_id| {
                    return session_id.len > 0 and incoming_session_ids.contains(session_id);
                }
                return false;
            },
            .split => |split| {
                return paneTreeHasOverlappingSession(split.first, incoming_session_ids) or
                    paneTreeHasOverlappingSession(split.second, incoming_session_ids);
            },
        }
    }

    /// Build a pane tree from sync data. Prefers per-pane metadata; falls
    /// back to bare session_ids; else single leaf with (maybe) a session.
    fn buildPaneTreeFromSync(self: *Registry, ws_data: SyncWorkspace) !*PaneNode {
        const sync_panes = ws_data.panes;
        const all_sids = ws_data.session_ids;
        if (sync_panes.len > 0) {
            if (sync_panes.len == 1) {
                const pane_id = try self.generatePaneId();
                const node = try self.alloc.create(PaneNode);
                node.* = .{ .leaf = .{
                    .id = pane_id,
                    .pane_type = .terminal,
                    .session_id = try self.alloc.dupe(u8, sync_panes[0].session_id),
                    .title = try self.alloc.dupe(u8, sync_panes[0].title),
                    .directory = try self.alloc.dupe(u8, sync_panes[0].directory),
                } };
                return node;
            }
            var current: *PaneNode = try self.alloc.create(PaneNode);
            const first_id = try self.generatePaneId();
            current.* = .{ .leaf = .{
                .id = first_id,
                .pane_type = .terminal,
                .session_id = try self.alloc.dupe(u8, sync_panes[0].session_id),
                .title = try self.alloc.dupe(u8, sync_panes[0].title),
                .directory = try self.alloc.dupe(u8, sync_panes[0].directory),
            } };
            for (sync_panes[1..]) |pane| {
                const right_id = try self.generatePaneId();
                const right = try self.alloc.create(PaneNode);
                right.* = .{ .leaf = .{
                    .id = right_id,
                    .pane_type = .terminal,
                    .session_id = try self.alloc.dupe(u8, pane.session_id),
                    .title = try self.alloc.dupe(u8, pane.title),
                    .directory = try self.alloc.dupe(u8, pane.directory),
                } };
                const split = try self.alloc.create(PaneNode);
                split.* = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .first = current, .second = right } };
                current = split;
            }
            return current;
        } else if (all_sids.len > 1) {
            var current: *PaneNode = try self.alloc.create(PaneNode);
            const first_id = try self.generatePaneId();
            current.* = .{ .leaf = .{
                .id = first_id,
                .pane_type = .terminal,
                .session_id = try self.alloc.dupe(u8, all_sids[0]),
                .title = try self.alloc.dupe(u8, ""),
                .directory = try self.alloc.dupe(u8, ws_data.directory),
            } };
            for (all_sids[1..]) |sid| {
                const right_id = try self.generatePaneId();
                const right = try self.alloc.create(PaneNode);
                right.* = .{ .leaf = .{
                    .id = right_id,
                    .pane_type = .terminal,
                    .session_id = try self.alloc.dupe(u8, sid),
                    .title = try self.alloc.dupe(u8, ""),
                    .directory = try self.alloc.dupe(u8, ws_data.directory),
                } };
                const split = try self.alloc.create(PaneNode);
                split.* = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .first = current, .second = right } };
                current = split;
            }
            return current;
        } else {
            const pane_id = try self.generatePaneId();
            const node = try self.alloc.create(PaneNode);
            const sid = ws_data.session_id orelse
                (if (all_sids.len == 1) all_sids[0] else null);
            node.* = .{ .leaf = .{
                .id = pane_id,
                .pane_type = .terminal,
                .session_id = if (sid) |s| try self.alloc.dupe(u8, s) else null,
                .title = try self.alloc.dupe(u8, ""),
                .directory = try self.alloc.dupe(u8, ws_data.directory),
            } };
            return node;
        }
    }

    pub const SyncPane = struct {
        session_id: []const u8,
        title: []const u8 = "",
        directory: []const u8 = "",
    };

    pub const SyncWorkspace = struct {
        id: []const u8,
        title: []const u8,
        directory: []const u8,
        preview: []const u8 = "",
        phase: []const u8 = "idle",
        color: []const u8 = "",
        unread_count: u32 = 0,
        pinned: bool = false,
        session_id: ?[]const u8 = null,
        /// Additional session IDs for multi-pane workspaces.
        session_ids: []const []const u8 = &.{},
        /// Per-pane metadata (title, directory). Preferred over session_ids
        /// when present, because it carries richer info.
        panes: []const SyncPane = &.{},
    };
};

// --- Subscription support ---

/// Thread-safe list of subscriber streams for workspace change events.
/// Each subscriber is a WebSocket stream that receives push events.
pub const Subscriber = struct {
    stream: *std.net.Stream,
    /// If set, control frames are enqueued (line-framed) into the
    /// per-connection outbound queue. Otherwise the WS sync framing path
    /// is used and the manager prunes failed connections.
    queue: ?*outbound_queue.OutboundQueue = null,
};

pub const SubscriptionManager = struct {
    mutex: std.Thread.Mutex = .{},
    streams: std.ArrayList(Subscriber) = .empty,

    pub fn add(self: *SubscriptionManager, alloc: std.mem.Allocator, stream: *std.net.Stream) !void {
        return self.addQueued(alloc, stream, null);
    }

    pub fn addQueued(
        self: *SubscriptionManager,
        alloc: std.mem.Allocator,
        stream: *std.net.Stream,
        queue: ?*outbound_queue.OutboundQueue,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.streams.append(alloc, .{ .stream = stream, .queue = queue });
    }

    pub fn remove(self: *SubscriptionManager, stream: *std.net.Stream) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items, 0..) |s, i| {
            if (s.stream == stream) {
                _ = self.streams.orderedRemove(i);
                return;
            }
        }
    }

    pub fn notifyAll(self: *SubscriptionManager, message: []const u8) void {
        self.notifyAllAlloc(null, message);
    }

    /// `alloc` is required when any subscriber uses the queued path (it
    /// owns the duplicated payload). May be null if all subscribers use
    /// the WS sync path.
    pub fn notifyAllAlloc(
        self: *SubscriptionManager,
        alloc: ?std.mem.Allocator,
        message: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.streams.items.len) {
            const sub = self.streams.items[i];
            if (sub.queue) |q| {
                const a = alloc orelse {
                    _ = self.streams.orderedRemove(i);
                    continue;
                };
                // Newline frame for line-delimited transport.
                const line = a.alloc(u8, message.len + 1) catch {
                    _ = self.streams.orderedRemove(i);
                    continue;
                };
                @memcpy(line[0..message.len], message);
                line[message.len] = '\n';
                q.enqueueControl(line) catch {
                    a.free(line);
                    _ = self.streams.orderedRemove(i);
                    continue;
                };
                i += 1;
            } else {
                sendWsText(sub.stream, message) catch {
                    _ = self.streams.orderedRemove(i);
                    continue;
                };
                i += 1;
            }
        }
    }

    pub fn deinit(self: *SubscriptionManager, alloc: std.mem.Allocator) void {
        self.streams.deinit(alloc);
    }

    fn sendWsText(stream: *std.net.Stream, data: []const u8) !void {
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
};

// --- Tests ---

test "create workspace" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const id = try reg.create("test", "/tmp");
    try std.testing.expect(reg.workspaces.count() == 1);
    const ws = reg.get(id).?;
    try std.testing.expectEqualStrings("test", ws.title);
    try std.testing.expect(ws.root_pane.* == .leaf);
}

test "rename workspace" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const id = try reg.create("old", null);
    try reg.rename(id, "new");
    const ws = reg.get(id).?;
    try std.testing.expectEqualStrings("new", ws.title);
}

test "close workspace" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const id = try reg.create("test", null);
    try reg.close(id);
    try std.testing.expect(reg.workspaces.count() == 0);
}

test "split pane creates tree" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ws_id = try reg.create("test", null);
    const ws = reg.get(ws_id).?;
    const first_pane_id = ws.root_pane.leaf.id;

    _ = try reg.splitPane(ws_id, first_pane_id, .horizontal, .terminal);

    try std.testing.expect(ws.root_pane.* == .split);
    try std.testing.expect(ws.root_pane.split.first.* == .leaf);
    try std.testing.expect(ws.root_pane.split.second.* == .leaf);
}

test "resize pane updates containing split ratio" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ws_id = try reg.create("test", null);
    const ws = reg.get(ws_id).?;
    const first_pane_id = ws.root_pane.leaf.id;
    const second_pane_id = try reg.splitPane(ws_id, first_pane_id, .horizontal, .terminal);

    try reg.resizePane(ws_id, first_pane_id, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), ws.root_pane.split.ratio, 0.0001);

    try reg.resizePane(ws_id, second_pane_id, 0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), ws.root_pane.split.ratio, 0.0001);
}

test "close pane collapses tree" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const ws_id = try reg.create("test", null);
    const ws = reg.get(ws_id).?;
    const first_pane_id = ws.root_pane.leaf.id;

    const second_pane_id = try reg.splitPane(ws_id, first_pane_id, .horizontal, .terminal);
    try std.testing.expect(ws.root_pane.* == .split);

    try reg.closePane(ws_id, second_pane_id);
    try std.testing.expect(ws.root_pane.* == .leaf);
}

test "change_seq increments on mutations" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(u64, 0), reg.change_seq);
    _ = try reg.create("test", null);
    try std.testing.expectEqual(@as(u64, 1), reg.change_seq);
}

test "syncAll preserves existing pane session_ids when payload has none" {
    // Regression: workspace.sync used to atomically replace every workspace,
    // so when mac's surface lacked savedDaemonSessionID (Exec mode, daemon
    // not ready at session restore) the sync would ship panes=[] and blow
    // away the daemon's session bindings created earlier via workspace.open_pane.
    // After the upsert rewrite, panes=[] preserves existing bindings.
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    // Seed: one workspace with a pane that has a session_id (simulating the
    // state after a prior workspace.open_pane from iOS or mac daemon mode).
    const workspaces_with_session = [_]Registry.SyncWorkspace{
        .{
            .id = "ws-a",
            .title = "seeded",
            .directory = "/tmp",
            .panes = &[_]Registry.SyncPane{
                .{ .session_id = "sess-established", .title = "t", .directory = "/tmp" },
            },
        },
    };
    try reg.syncAll(&workspaces_with_session, null, false);
    const seeded = reg.get("ws-a").?;
    try std.testing.expect(seeded.root_pane.* == .leaf);
    try std.testing.expectEqualStrings("sess-established", seeded.root_pane.leaf.session_id.?);

    // Mac pushes a sync without pane data (panes=[], no session_ids). The
    // pane tree must be preserved.
    const workspaces_metadata_only = [_]Registry.SyncWorkspace{
        .{
            .id = "ws-a",
            .title = "renamed",
            .directory = "/Users/me",
            .pinned = true,
        },
    };
    try reg.syncAll(&workspaces_metadata_only, null, false);
    const after = reg.get("ws-a").?;
    try std.testing.expectEqualStrings("renamed", after.title);
    try std.testing.expectEqualStrings("/Users/me", after.directory);
    try std.testing.expect(after.pinned);
    try std.testing.expect(after.root_pane.* == .leaf);
    try std.testing.expectEqualStrings(
        "sess-established",
        after.root_pane.leaf.session_id.?,
    );
}

test "syncAll upsert-in-place: metadata-only update keeps existing pane tree" {
    // Exercises the realistic mac scenario: surfaces open_pane'd at boot
    // establish session bindings, then mac does a rename. The rename's
    // workspace.sync payload carries new title but no pane details (mac
    // hasn't attached surface session_ids to this particular push) —
    // daemon must keep the bound pane tree intact.
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const initial = [_]Registry.SyncWorkspace{
        .{
            .id = "ws-ren",
            .title = "original",
            .directory = "/tmp",
            .panes = &[_]Registry.SyncPane{
                .{ .session_id = "sess-stable", .title = "t", .directory = "/tmp" },
            },
        },
    };
    try reg.syncAll(&initial, null, false);
    const before = reg.get("ws-ren").?;
    try std.testing.expect(before.root_pane.* == .leaf);
    try std.testing.expectEqualStrings("sess-stable", before.root_pane.leaf.session_id.?);

    // Mac pushes rename with no pane data.
    const rename = [_]Registry.SyncWorkspace{
        .{ .id = "ws-ren", .title = "renamed", .directory = "/tmp" },
    };
    try reg.syncAll(&rename, null, false);
    const after = reg.get("ws-ren").?;
    try std.testing.expectEqualStrings("renamed", after.title);
    try std.testing.expect(after.root_pane.* == .leaf);
    try std.testing.expectEqualStrings("sess-stable", after.root_pane.leaf.session_id.?);
}

test "syncAll preserves missing daemon-created workspace with distinct session" {
    // Regression: workspace.sync used to delete every workspace not in the
    // payload. iOS-created workspaces that hadn't yet round-tripped to mac's
    // TabManager could therefore vanish on the next mac sync. Post-upsert,
    // missing daemon-created workspaces with distinct live sessions must survive.
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const mac_seed = [_]Registry.SyncWorkspace{
        .{ .id = "ws-keep", .title = "keep", .directory = "", .session_id = "sess-keep" },
    };
    try reg.syncAll(&mac_seed, null, false);

    const phone_id = try reg.createWithId("ws-only-on-phone", "phone", "");
    const phone = reg.get(phone_id).?;
    try reg.bindSession(phone_id, phone.focused_pane_id.?, "sess-phone");

    try std.testing.expect(reg.get("ws-keep") != null);
    try std.testing.expect(reg.get("ws-only-on-phone") != null);

    // Mac sync only mentions ws-keep. ws-only-on-phone must survive.
    const partial = [_]Registry.SyncWorkspace{
        .{ .id = "ws-keep", .title = "keep", .directory = "", .session_id = "sess-keep" },
    };
    try reg.syncAll(&partial, null, false);
    try std.testing.expect(reg.get("ws-keep") != null);
    try std.testing.expect(reg.get("ws-only-on-phone") != null);
}

test "syncAll authoritative sync prunes missing mac-synced workspace with distinct session" {
    // Mac-created workspaces are authoritative after they have appeared in a
    // mac sync. If a later authoritative mac sync omits one, it is stale and
    // should not keep showing on iOS just because it still has a daemon session.
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const initial = [_]Registry.SyncWorkspace{
        .{ .id = "ws-keep", .title = "keep", .directory = "", .session_id = "sess-keep" },
        .{ .id = "ws-stale", .title = "stale", .directory = "", .session_id = "sess-stale" },
    };
    try reg.syncAll(&initial, null, false);
    try std.testing.expect(reg.get("ws-keep") != null);
    try std.testing.expect(reg.get("ws-stale") != null);

    const restored = [_]Registry.SyncWorkspace{
        .{ .id = "ws-keep", .title = "keep", .directory = "", .session_id = "sess-keep" },
    };
    try reg.syncAll(&restored, "ws-keep", true);

    try std.testing.expect(reg.get("ws-keep") != null);
    try std.testing.expect(reg.get("ws-stale") == null);
    try std.testing.expectEqual(@as(u32, 1), reg.workspaces.count());
}

test "syncAll prunes missing workspace with duplicate incoming session" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const initial = [_]Registry.SyncWorkspace{
        .{
            .id = "ws-old",
            .title = "old",
            .directory = "",
            .panes = &[_]Registry.SyncPane{
                .{ .session_id = "sess-shared", .title = "old shell", .directory = "" },
            },
        },
    };
    try reg.syncAll(&initial, null, false);
    try std.testing.expect(reg.get("ws-old") != null);

    const relaunched = [_]Registry.SyncWorkspace{
        .{
            .id = "ws-new",
            .title = "new",
            .directory = "",
            .panes = &[_]Registry.SyncPane{
                .{ .session_id = "sess-shared", .title = "same shell", .directory = "" },
            },
        },
    };
    try reg.syncAll(&relaunched, null, false);

    try std.testing.expect(reg.get("ws-old") == null);
    try std.testing.expect(reg.get("ws-new") != null);
    try std.testing.expectEqual(@as(usize, 1), reg.order.items.len);
    try std.testing.expectEqual(@as(u32, 1), reg.workspaces.count());
}

test "syncAll prunes stale missing sessionless workspace" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const initial = [_]Registry.SyncWorkspace{
        .{ .id = "ws-empty", .title = "empty", .directory = "" },
    };
    try reg.syncAll(&initial, null, false);
    const empty = reg.get("ws-empty").?;
    empty.last_activity_at -= Registry.sessionless_missing_workspace_prune_grace_ms + 1;

    const live = [_]Registry.SyncWorkspace{
        .{ .id = "ws-live", .title = "live", .directory = "", .session_id = "sess-live" },
    };
    try reg.syncAll(&live, null, false);

    try std.testing.expect(reg.get("ws-empty") == null);
    try std.testing.expect(reg.get("ws-live") != null);
}

test "syncAll authoritative sync prunes fresh missing sessionless workspace" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const initial = [_]Registry.SyncWorkspace{
        .{ .id = "ws-bootstrap", .title = "bootstrap", .directory = "" },
    };
    try reg.syncAll(&initial, null, false);
    try std.testing.expect(reg.get("ws-bootstrap") != null);

    const restored = [_]Registry.SyncWorkspace{
        .{ .id = "ws-restored", .title = "restored", .directory = "", .session_id = "sess-restored" },
    };
    try reg.syncAll(&restored, "ws-restored", true);

    try std.testing.expect(reg.get("ws-bootstrap") == null);
    try std.testing.expect(reg.get("ws-restored") != null);
    try std.testing.expectEqualStrings("ws-restored", reg.selected_id.?);
    try std.testing.expectEqual(@as(usize, 1), reg.order.items.len);
}
