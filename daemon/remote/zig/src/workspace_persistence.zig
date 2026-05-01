//! Bridge between the in-memory `workspace_registry.Registry` and the
//! on-disk `persistence.Db`. Keeps the tree-shaped `PaneNode` union out of
//! the persistence layer's schema: we emit/parse the tree as JSON stored
//! in a single column per workspace row.
//!
//! Called by `server_core.zig` after every mutation (save) and at daemon
//! startup (load).

const std = @import("std");
const persistence = @import("persistence.zig");
const workspace_registry = @import("workspace_registry.zig");

const PaneNode = workspace_registry.PaneNode;
const PaneLeaf = workspace_registry.PaneLeaf;
const PaneSplit = workspace_registry.PaneSplit;
const PaneType = workspace_registry.PaneType;
const SplitDirection = workspace_registry.SplitDirection;
const Registry = workspace_registry.Registry;
const Workspace = workspace_registry.Workspace;

pub const Error = error{
    InvalidJson,
    MissingField,
    OutOfMemory,
} || persistence.Error;

// ---------------------------------------------------------------------------
// PaneNode <-> JSON.
// ---------------------------------------------------------------------------

pub fn serializePaneTree(alloc: std.mem.Allocator, root: *const PaneNode) Error![]u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    writeNode(&builder.writer, root) catch return Error.OutOfMemory;
    return alloc.dupe(u8, builder.writer.buffered()) catch Error.OutOfMemory;
}

fn writeNode(w: *std.Io.Writer, node: *const PaneNode) !void {
    switch (node.*) {
        .leaf => |leaf| {
            try w.writeAll("{\"kind\":\"leaf\",\"id\":");
            try writeJsonString(w, leaf.id);
            try w.writeAll(",\"pane_type\":\"");
            try w.writeAll(@tagName(leaf.pane_type));
            try w.writeAll("\"");
            if (leaf.session_id) |s| {
                try w.writeAll(",\"session_id\":");
                try writeJsonString(w, s);
            }
            if (leaf.url) |u| {
                try w.writeAll(",\"url\":");
                try writeJsonString(w, u);
            }
            if (leaf.title.len > 0) {
                try w.writeAll(",\"title\":");
                try writeJsonString(w, leaf.title);
            }
            if (leaf.directory.len > 0) {
                try w.writeAll(",\"directory\":");
                try writeJsonString(w, leaf.directory);
            }
            try w.writeAll("}");
        },
        .split => |split| {
            try w.writeAll("{\"kind\":\"split\",\"direction\":\"");
            try w.writeAll(@tagName(split.direction));
            try w.print("\",\"ratio\":{d},\"first\":", .{split.ratio});
            try writeNode(w, split.first);
            try w.writeAll(",\"second\":");
            try writeNode(w, split.second);
            try w.writeAll("}");
        },
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

pub fn parsePaneTree(alloc: std.mem.Allocator, json: []const u8) Error!*PaneNode {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return Error.InvalidJson;
    defer parsed.deinit();
    return try buildNode(alloc, parsed.value);
}

fn buildNode(alloc: std.mem.Allocator, value: std.json.Value) Error!*PaneNode {
    const obj = switch (value) {
        .object => |o| o,
        else => return Error.InvalidJson,
    };
    const kind_val = obj.get("kind") orelse return Error.MissingField;
    const kind = switch (kind_val) {
        .string => |s| s,
        else => return Error.InvalidJson,
    };

    const node = alloc.create(PaneNode) catch return Error.OutOfMemory;
    errdefer alloc.destroy(node);

    if (std.mem.eql(u8, kind, "leaf")) {
        const id_val = obj.get("id") orelse return Error.MissingField;
        const id = try dupeJsonString(alloc, id_val);
        errdefer alloc.free(id);

        var pane_type: PaneType = .terminal;
        if (obj.get("pane_type")) |ptv| switch (ptv) {
            .string => |s| {
                if (std.mem.eql(u8, s, "browser")) pane_type = .browser;
            },
            else => {},
        };

        const session_id: ?[]const u8 = try maybeDupeJsonString(alloc, obj.get("session_id"));
        const url: ?[]const u8 = try maybeDupeJsonString(alloc, obj.get("url"));
        const title = try maybeDupeJsonStringOrEmpty(alloc, obj.get("title"));
        const directory = try maybeDupeJsonStringOrEmpty(alloc, obj.get("directory"));

        node.* = .{ .leaf = .{
            .id = id,
            .pane_type = pane_type,
            .session_id = session_id,
            .url = url,
            .title = title,
            .directory = directory,
        } };
        return node;
    } else if (std.mem.eql(u8, kind, "split")) {
        var direction: SplitDirection = .horizontal;
        if (obj.get("direction")) |dv| switch (dv) {
            .string => |s| {
                if (std.mem.eql(u8, s, "vertical")) direction = .vertical;
            },
            else => {},
        };
        const ratio = switch (obj.get("ratio") orelse std.json.Value{ .float = 0.5 }) {
            .float => |f| @as(f32, @floatCast(f)),
            .integer => |i| @as(f32, @floatFromInt(i)),
            else => 0.5,
        };
        const first_val = obj.get("first") orelse return Error.MissingField;
        const second_val = obj.get("second") orelse return Error.MissingField;
        const first = try buildNode(alloc, first_val);
        errdefer {
            first.deinit(alloc);
            alloc.destroy(first);
        }
        const second = try buildNode(alloc, second_val);
        node.* = .{ .split = .{
            .direction = direction,
            .ratio = ratio,
            .first = first,
            .second = second,
        } };
        return node;
    } else return Error.InvalidJson;
}

fn dupeJsonString(alloc: std.mem.Allocator, value: std.json.Value) Error![]const u8 {
    switch (value) {
        .string => |s| return alloc.dupe(u8, s) catch Error.OutOfMemory,
        else => return Error.InvalidJson,
    }
}

fn maybeDupeJsonString(alloc: std.mem.Allocator, value: ?std.json.Value) Error!?[]const u8 {
    const v = value orelse return null;
    switch (v) {
        .null => return null,
        .string => |s| return alloc.dupe(u8, s) catch Error.OutOfMemory,
        else => return null,
    }
}

fn maybeDupeJsonStringOrEmpty(alloc: std.mem.Allocator, value: ?std.json.Value) Error![]const u8 {
    const v = value orelse return alloc.dupe(u8, "") catch Error.OutOfMemory;
    switch (v) {
        .string => |s| return alloc.dupe(u8, s) catch Error.OutOfMemory,
        else => return alloc.dupe(u8, "") catch Error.OutOfMemory,
    }
}

// ---------------------------------------------------------------------------
// Registry <-> sqlite.
// ---------------------------------------------------------------------------

/// Persist every open workspace in the registry. Closed workspaces in the DB
/// are preserved. Called after each mutation handler.
pub fn saveRegistry(db: *persistence.Db, reg: *const Registry, alloc: std.mem.Allocator) Error!void {
    var list: std.ArrayList(persistence.PersistedWorkspace) = .empty;
    defer {
        for (list.items) |ws| alloc.free(ws.pane_tree_json);
        list.deinit(alloc);
    }

    for (reg.order.items, 0..) |id, idx| {
        const ws = reg.workspaces.get(id) orelse continue;
        const tree_json = try serializePaneTree(alloc, ws.root_pane);
        try list.append(alloc, .{
            .id = ws.id,
            .title = ws.title,
            .custom_title = ws.custom_title,
            .directory = ws.directory,
            .color = ws.color,
            .pinned = ws.pinned,
            .order_index = @intCast(idx),
            .focused_pane_id = ws.focused_pane_id,
            .created_at = ws.created_at,
            .last_activity_at = ws.last_activity_at,
            .pane_tree_json = tree_json,
        });
    }

    try persistence.saveOpenWorkspaces(db, list.items, reg.selected_id);
}

/// Replace the registry's in-memory state with whatever is in the DB.
/// Called once at daemon startup before the accept loop begins.
pub fn hydrateRegistry(db: *persistence.Db, reg: *Registry, alloc: std.mem.Allocator) Error!void {
    var loaded = try persistence.loadOpenWorkspaces(db, alloc);
    defer loaded.deinit();

    // Clear any existing state (fresh boot should already have an empty
    // registry; defensive here in case we ever call reload).
    clearRegistry(reg);

    for (loaded.workspaces) |pws| {
        const id = reg.alloc.dupe(u8, pws.id) catch return Error.OutOfMemory;
        errdefer reg.alloc.free(id);

        const root: *PaneNode = blk: {
            if (parsePaneTree(reg.alloc, pws.pane_tree_json)) |ok| {
                break :blk ok;
            } else |err| switch (err) {
                Error.InvalidJson, Error.MissingField => {
                    // Fall back to an empty leaf so the workspace isn't lost.
                    const leaf = reg.alloc.create(PaneNode) catch return Error.OutOfMemory;
                    const pane_id = reg.generatePaneId() catch return Error.OutOfMemory;
                    leaf.* = .{ .leaf = .{
                        .id = pane_id,
                        .pane_type = .terminal,
                        .title = reg.alloc.dupe(u8, "") catch return Error.OutOfMemory,
                        .directory = reg.alloc.dupe(u8, "") catch return Error.OutOfMemory,
                    } };
                    break :blk leaf;
                },
                else => return err,
            }
        };

        const title = reg.alloc.dupe(u8, pws.title) catch return Error.OutOfMemory;
        const dir = reg.alloc.dupe(u8, pws.directory) catch return Error.OutOfMemory;
        const custom_title: ?[]const u8 = if (pws.custom_title) |ct| reg.alloc.dupe(u8, ct) catch return Error.OutOfMemory else null;
        const color: ?[]const u8 = if (pws.color) |c| reg.alloc.dupe(u8, c) catch return Error.OutOfMemory else null;
        const focused: ?[]const u8 = if (pws.focused_pane_id) |f| reg.alloc.dupe(u8, f) catch return Error.OutOfMemory else null;

        const ws = Workspace{
            .id = id,
            .title = title,
            .custom_title = custom_title,
            .color = color,
            .directory = dir,
            .preview = reg.alloc.dupe(u8, "") catch return Error.OutOfMemory,
            .phase = reg.alloc.dupe(u8, "idle") catch return Error.OutOfMemory,
            .pinned = pws.pinned,
            .root_pane = root,
            .focused_pane_id = focused,
            .created_at = pws.created_at,
            .last_activity_at = pws.last_activity_at,
            .origin = .mac_sync,
        };

        const order_id = reg.alloc.dupe(u8, id) catch return Error.OutOfMemory;
        reg.order.append(reg.alloc, order_id) catch return Error.OutOfMemory;
        reg.workspaces.put(id, ws) catch return Error.OutOfMemory;
    }

    if (loaded.selected_id) |sel| {
        reg.selected_id = reg.alloc.dupe(u8, sel) catch return Error.OutOfMemory;
    }

    reg.change_seq += 1;
}

fn clearRegistry(reg: *Registry) void {
    var iter = reg.workspaces.iterator();
    while (iter.next()) |entry| {
        freeWorkspaceOwned(reg.alloc, entry.value_ptr);
    }
    reg.workspaces.clearRetainingCapacity();
    for (reg.order.items) |id| reg.alloc.free(id);
    reg.order.clearRetainingCapacity();
    if (reg.selected_id) |s| {
        reg.alloc.free(s);
        reg.selected_id = null;
    }
}

fn freeWorkspaceOwned(alloc: std.mem.Allocator, ws: *Workspace) void {
    alloc.free(ws.id);
    alloc.free(ws.title);
    if (ws.custom_title) |v| alloc.free(v);
    if (ws.color) |v| alloc.free(v);
    alloc.free(ws.directory);
    alloc.free(ws.preview);
    alloc.free(ws.phase);
    if (ws.session_id) |v| alloc.free(v);
    if (ws.focused_pane_id) |v| alloc.free(v);
    ws.root_pane.deinit(alloc);
    alloc.destroy(ws.root_pane);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "serialize + parse leaf roundtrip" {
    const alloc = std.testing.allocator;
    const leaf = try alloc.create(PaneNode);
    defer {
        leaf.deinit(alloc);
        alloc.destroy(leaf);
    }
    leaf.* = .{ .leaf = .{
        .id = try alloc.dupe(u8, "pane-1"),
        .pane_type = .terminal,
        .session_id = try alloc.dupe(u8, "sess-a"),
        .title = try alloc.dupe(u8, "hello \"world\""),
        .directory = try alloc.dupe(u8, "/tmp"),
    } };

    const json = try serializePaneTree(alloc, leaf);
    defer alloc.free(json);

    const parsed = try parsePaneTree(alloc, json);
    defer {
        parsed.deinit(alloc);
        alloc.destroy(parsed);
    }
    try std.testing.expect(parsed.* == .leaf);
    try std.testing.expectEqualStrings("pane-1", parsed.leaf.id);
    try std.testing.expectEqualStrings("sess-a", parsed.leaf.session_id.?);
    try std.testing.expectEqualStrings("hello \"world\"", parsed.leaf.title);
    try std.testing.expectEqualStrings("/tmp", parsed.leaf.directory);
}

test "serialize + parse nested split roundtrip" {
    const alloc = std.testing.allocator;
    const leaf_a = try alloc.create(PaneNode);
    leaf_a.* = .{ .leaf = .{
        .id = try alloc.dupe(u8, "pane-a"),
        .pane_type = .terminal,
        .title = try alloc.dupe(u8, ""),
        .directory = try alloc.dupe(u8, ""),
    } };
    const leaf_b = try alloc.create(PaneNode);
    leaf_b.* = .{ .leaf = .{
        .id = try alloc.dupe(u8, "pane-b"),
        .pane_type = .terminal,
        .title = try alloc.dupe(u8, ""),
        .directory = try alloc.dupe(u8, ""),
    } };
    const root = try alloc.create(PaneNode);
    defer {
        root.deinit(alloc);
        alloc.destroy(root);
    }
    root.* = .{ .split = .{
        .direction = .vertical,
        .ratio = 0.3,
        .first = leaf_a,
        .second = leaf_b,
    } };

    const json = try serializePaneTree(alloc, root);
    defer alloc.free(json);

    const parsed = try parsePaneTree(alloc, json);
    defer {
        parsed.deinit(alloc);
        alloc.destroy(parsed);
    }
    try std.testing.expect(parsed.* == .split);
    try std.testing.expect(parsed.split.direction == .vertical);
    try std.testing.expectEqual(@as(f32, 0.3), parsed.split.ratio);
    try std.testing.expect(parsed.split.first.* == .leaf);
    try std.testing.expectEqualStrings("pane-a", parsed.split.first.leaf.id);
    try std.testing.expectEqualStrings("pane-b", parsed.split.second.leaf.id);
}

test "saveRegistry + hydrateRegistry roundtrip" {
    const alloc = std.testing.allocator;
    var reg = Registry.init(alloc);
    defer reg.deinit();

    const ws1 = try reg.create("alpha", "/Users/me");
    _ = ws1;
    const ws2 = try reg.create("beta", "/tmp");
    try reg.setPin(ws2, true);

    var db = try persistence.Db.open(alloc, ":memory:");
    defer db.close();

    try saveRegistry(&db, &reg, alloc);

    // Fresh registry, hydrate from DB.
    var reg2 = Registry.init(alloc);
    defer reg2.deinit();
    try hydrateRegistry(&db, &reg2, alloc);

    try std.testing.expectEqual(@as(usize, 2), reg2.order.items.len);
    const loaded_first = reg2.workspaces.get(reg2.order.items[0]).?;
    try std.testing.expectEqualStrings("alpha", loaded_first.title);
    const loaded_second = reg2.workspaces.get(reg2.order.items[1]).?;
    try std.testing.expectEqualStrings("beta", loaded_second.title);
    try std.testing.expect(loaded_second.pinned);
}

test "saveRegistry + hydrateRegistry preserves session bindings across a split tree" {
    // Guards the PR 1 + 4 contract: when the mac daemon dies and restarts,
    // hydrating from sqlite must bring back both the split layout and any
    // session_id bindings that survived. Without this, iOS would observe
    // bare panes and fall back to spawning fresh shells.
    const alloc = std.testing.allocator;

    var reg = Registry.init(alloc);
    defer reg.deinit();

    const ws_id = try reg.create("split-ws", "/Users/me");
    const ws = reg.get(ws_id).?;
    const first_pane_id = ws.root_pane.leaf.id;

    // Simulate mac calling open_pane twice: bind a session to the first,
    // then split and bind a session to the new leaf.
    try reg.bindSession(ws_id, first_pane_id, "sess-left");
    const second_pane_id = try reg.splitPane(ws_id, first_pane_id, .vertical, .terminal);
    try reg.bindSession(ws_id, second_pane_id, "sess-right");

    var db = try persistence.Db.open(alloc, ":memory:");
    defer db.close();
    try saveRegistry(&db, &reg, alloc);

    var reg2 = Registry.init(alloc);
    defer reg2.deinit();
    try hydrateRegistry(&db, &reg2, alloc);

    try std.testing.expectEqual(@as(usize, 1), reg2.order.items.len);
    const hydrated = reg2.workspaces.get(reg2.order.items[0]).?;
    try std.testing.expect(hydrated.root_pane.* == .split);
    try std.testing.expect(hydrated.root_pane.split.direction == .vertical);

    // Collect leaves and verify both session_ids survived.
    const leaves = try hydrated.root_pane.collectLeaves(alloc);
    defer alloc.free(leaves);
    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    var found_left = false;
    var found_right = false;
    for (leaves) |leaf| {
        const sid = leaf.session_id orelse continue;
        if (std.mem.eql(u8, sid, "sess-left")) found_left = true;
        if (std.mem.eql(u8, sid, "sess-right")) found_right = true;
    }
    try std.testing.expect(found_left);
    try std.testing.expect(found_right);
}
