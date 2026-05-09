const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");
const ghostty_contract = @import("ghostty-contract");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const MaxPanes = 8;
const MaxTitle = 80;
const MaxURL = 512;
const initial_browser_url = "https://zero-native.dev";

const PaneKind = enum {
    terminal,
    browser,

    fn jsonName(self: PaneKind) []const u8 {
        return switch (self) {
            .terminal => "terminal",
            .browser => "browser",
        };
    }
};

const Pane = struct {
    id: u32 = 0,
    kind: PaneKind = .terminal,
    host: []const u8 = "ghostty",
    title: [MaxTitle]u8 = undefined,
    title_len: usize = 0,
    url: [MaxURL]u8 = undefined,
    url_len: usize = 0,
    cwd: []const u8 = "~",

    fn titleSlice(self: *const Pane) []const u8 {
        return self.title[0..self.title_len];
    }

    fn urlSlice(self: *const Pane) []const u8 {
        return self.url[0..self.url_len];
    }

    fn setTitle(self: *Pane, value: []const u8) void {
        self.title_len = copyBounded(&self.title, value);
    }

    fn setURL(self: *Pane, value: []const u8) void {
        self.url_len = copyBounded(&self.url, value);
    }
};

const NavigatePayload = struct {
    paneId: u32 = 0,
    url: []const u8 = "",
};

const bridge_policies = [_]zero_native.BridgeCommandPolicy{
    .{ .name = "workbench.snapshot" },
    .{ .name = "workbench.addTerminal" },
    .{ .name = "workbench.addBrowser" },
    .{ .name = "workbench.focusPane" },
    .{ .name = "workbench.navigateBrowser" },
};

const allowed_origins = [_][]const u8{ "zero://inline", "zero://app", "https://zero-native.dev" };

const WorkbenchApp = struct {
    panes: [MaxPanes]Pane = undefined,
    pane_count: usize = 0,
    next_pane_id: u32 = 1,
    selected_pane_id: u32 = 0,
    bridge_handlers: [bridge_policies.len]zero_native.BridgeHandler = undefined,

    fn init() WorkbenchApp {
        var self = WorkbenchApp{};
        self.addPane(.terminal, "Ghostty", "") catch unreachable;
        self.addPane(.browser, "Zero Native", "https://zero-native.dev") catch unreachable;
        return self;
    }

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "zero-cmux",
            .source = zero_native.WebViewSource.url(initial_browser_url),
        };
    }

    fn bridge(self: *@This()) zero_native.BridgeDispatcher {
        self.bridge_handlers = .{
            .{ .name = "workbench.snapshot", .context = self, .invoke_fn = snapshot },
            .{ .name = "workbench.addTerminal", .context = self, .invoke_fn = addTerminal },
            .{ .name = "workbench.addBrowser", .context = self, .invoke_fn = addBrowser },
            .{ .name = "workbench.focusPane", .context = self, .invoke_fn = focusPane },
            .{ .name = "workbench.navigateBrowser", .context = self, .invoke_fn = navigateBrowser },
        };
        return .{
            .policy = .{ .enabled = true, .commands = &bridge_policies },
            .registry = .{ .handlers = &self.bridge_handlers },
        };
    }

    fn addPane(self: *@This(), kind: PaneKind, title: []const u8, url: []const u8) !void {
        if (self.pane_count >= MaxPanes) return error.TooManyPanes;
        var pane = Pane{
            .id = self.next_pane_id,
            .kind = kind,
            .host = if (kind == .terminal) "ghostty" else "chromium-cef",
        };
        pane.setTitle(title);
        pane.setURL(url);
        self.panes[self.pane_count] = pane;
        self.pane_count += 1;
        self.next_pane_id += 1;
        self.selected_pane_id = pane.id;
    }

    fn findPane(self: *@This(), pane_id: u32) ?*Pane {
        for (self.panes[0..self.pane_count]) |*pane| {
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    fn snapshot(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.writeSnapshot(output);
    }

    fn addTerminal(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        var title_buffer: [MaxTitle]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buffer, "Terminal {d}", .{self.next_pane_id});
        try self.addPane(.terminal, title, "");
        return self.writeSnapshot(output);
    }

    fn addBrowser(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        var title_buffer: [MaxTitle]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buffer, "Browser {d}", .{self.next_pane_id});
        try self.addPane(.browser, title, "https://zero-native.dev");
        return self.writeSnapshot(output);
    }

    fn focusPane(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const pane_id = std.json.parseFromSlice(struct { paneId: u32 = 0 }, std.heap.page_allocator, invocation.request.payload, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidPane;
        defer pane_id.deinit();
        if (self.findPane(pane_id.value.paneId) == null) return error.InvalidPane;
        self.selected_pane_id = pane_id.value.paneId;
        return self.writeSnapshot(output);
    }

    fn navigateBrowser(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const parsed = try std.json.parseFromSlice(NavigatePayload, std.heap.page_allocator, invocation.request.payload, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const pane = self.findPane(parsed.value.paneId) orelse return error.InvalidPane;
        if (pane.kind != .browser) return error.InvalidPane;
        var normalized_buffer: [MaxURL]u8 = undefined;
        const normalized = try normalizeURL(parsed.value.url, &normalized_buffer);
        pane.setURL(normalized);
        pane.setTitle(normalized);
        self.selected_pane_id = pane.id;
        return self.writeSnapshot(output);
    }

    fn writeSnapshot(self: *@This(), output: []u8) ![]const u8 {
        const contract = ghostty_contract.current();
        var writer = std.Io.Writer.fixed(output);
        try writer.writeAll("{\"browserEngine\":\"chromium-cef\",\"layoutOwner\":\"appkit-native\",\"terminalEngine\":");
        try writeJsonString(&writer, contract.terminal_engine);
        try writer.writeAll(",\"ghostty\":{\"hostPlatform\":");
        try writeJsonString(&writer, contract.host_platform);
        try writer.writeAll(",\"surfaceContext\":");
        try writeJsonString(&writer, contract.surface_context);
        try writer.writeAll(",\"ioMode\":");
        try writeJsonString(&writer, contract.io_mode);
        try writer.writeAll("},\"selectedPaneId\":");
        try writer.print("{d}", .{self.selected_pane_id});
        try writer.writeAll(",\"panes\":[");
        for (self.panes[0..self.pane_count], 0..) |*pane, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try writer.print("{d}", .{pane.id});
            try writer.writeAll(",\"kind\":");
            try writeJsonString(&writer, pane.kind.jsonName());
            try writer.writeAll(",\"host\":");
            try writeJsonString(&writer, pane.host);
            try writer.writeAll(",\"title\":");
            try writeJsonString(&writer, pane.titleSlice());
            try writer.writeAll(",\"url\":");
            try writeJsonString(&writer, pane.urlSlice());
            try writer.writeAll(",\"cwd\":");
            try writeJsonString(&writer, pane.cwd);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
        return writer.buffered();
    }
};

pub fn main(init_value: std.process.Init) !void {
    ghostty_contract.assertCompileTimeSurfaceContract();
    var workbench = WorkbenchApp.init();
    try runner.runWithOptions(workbench.app(), .{
        .app_name = "cmux Zero Native",
        .window_title = "cmux Zero Native",
        .bundle_id = "com.cmux.zero-native",
        .bridge = workbench.bridge(),
        .security = .{
            .navigation = .{ .allowed_origins = &allowed_origins },
        },
    }, init_value);
}

fn normalizeURL(input: []const u8, output: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \n\r\t");
    if (trimmed.len == 0) return error.InvalidURL;
    if (std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "file://") or
        std.mem.startsWith(u8, trimmed, "about:"))
    {
        return trimmed;
    }
    return std.fmt.bufPrint(output, "https://{s}", .{trimmed});
}

fn copyBounded(destination: []u8, source: []const u8) usize {
    const count = @min(destination.len, source.len);
    @memcpy(destination[0..count], source[0..count]);
    return count;
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

test "snapshot declares chromium browser panes and Ghostty terminal host" {
    var app = WorkbenchApp.init();
    var dispatcher = app.bridge();
    var output: [4096]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"workbench.snapshot","payload":{}}
    , .{ .origin = "zero://inline" }, &output);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "appkit-native") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "chromium-cef") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "ghostty") != null);
}

test "app loads the Chromium browser URL instead of a terminal HTML shell" {
    var app_state = WorkbenchApp.init();
    const app_value = app_state.app();

    try std.testing.expectEqual(zero_native.WebViewSourceKind.url, app_value.source.kind);
    try std.testing.expectEqualStrings(initial_browser_url, app_value.source.bytes);
}

test "browser navigation normalizes hostnames" {
    var app = WorkbenchApp.init();
    var dispatcher = app.bridge();
    var output: [4096]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"workbench.navigateBrowser","payload":{"paneId":2,"url":"example.com"}}
    , .{ .origin = "zero://inline" }, &output);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "https://example.com") != null);
}
