const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");
const ghostty_contract = @import("ghostty-contract");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const html =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self' zero://inline zero://app https: data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-src https: http: data:;">
    \\  <style>
    \\    :root { color-scheme: light dark; --bg:#f6f7f8; --panel:#ffffff; --ink:#17191c; --muted:#68707a; --line:#d9dde3; --active:#1463ff; --terminal:#101214; --terminal-ink:#e8edf2; }
    \\    @media (prefers-color-scheme: dark) { :root { --bg:#111316; --panel:#191c20; --ink:#eff2f5; --muted:#99a1ad; --line:#2a3038; --active:#6ba4ff; --terminal:#08090a; --terminal-ink:#dfe7ee; } }
    \\    * { box-sizing: border-box; }
    \\    body { margin:0; height:100vh; overflow:hidden; background:var(--bg); color:var(--ink); font:13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; letter-spacing:0; }
    \\    button, input { font:inherit; }
    \\    .app { height:100vh; display:grid; grid-template-columns:230px 1fr; grid-template-rows:40px 1fr; }
    \\    .top { grid-column:1 / -1; display:flex; align-items:center; gap:10px; padding:0 12px; border-bottom:1px solid var(--line); background:var(--panel); }
    \\    .brand { font-weight:650; }
    \\    .pill { border:1px solid var(--line); border-radius:999px; padding:3px 8px; color:var(--muted); white-space:nowrap; }
    \\    .spacer { flex:1; }
    \\    .sidebar { border-right:1px solid var(--line); background:var(--panel); padding:10px; overflow:auto; }
    \\    .workspace { width:100%; border:1px solid var(--line); border-radius:7px; background:var(--bg); color:var(--ink); padding:9px 10px; text-align:left; }
    \\    .workspace + .workspace { margin-top:8px; }
    \\    .main { min-width:0; min-height:0; display:grid; grid-template-rows:38px 1fr; }
    \\    .tabs { display:flex; gap:6px; align-items:center; padding:6px 8px; border-bottom:1px solid var(--line); background:var(--panel); overflow:auto; }
    \\    .tab { height:26px; border:1px solid var(--line); border-radius:7px; background:transparent; color:var(--ink); padding:0 10px; display:flex; align-items:center; gap:7px; white-space:nowrap; }
    \\    .tab.active { border-color:color-mix(in srgb, var(--active) 45%, var(--line)); background:color-mix(in srgb, var(--active) 11%, transparent); }
    \\    .tool { height:26px; width:30px; border:1px solid var(--line); border-radius:7px; background:transparent; color:var(--ink); }
    \\    .content { min-width:0; min-height:0; display:grid; grid-template-columns:minmax(360px, 0.95fr) minmax(420px, 1.05fr); gap:1px; background:var(--line); }
    \\    .pane { min-width:0; min-height:0; background:var(--panel); display:grid; grid-template-rows:34px 1fr; }
    \\    .pane-head { display:flex; align-items:center; gap:8px; min-width:0; padding:0 8px; border-bottom:1px solid var(--line); }
    \\    .pane-title { font-weight:600; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    \\    .address { flex:1; min-width:80px; height:24px; border:1px solid var(--line); border-radius:7px; background:var(--bg); color:var(--ink); padding:0 8px; }
    \\    .go { height:24px; border:1px solid var(--line); border-radius:7px; background:var(--bg); color:var(--ink); padding:0 9px; }
    \\    .terminal { background:var(--terminal); color:var(--terminal-ink); padding:14px; font:12px ui-monospace, SFMono-Regular, Menlo, monospace; overflow:auto; }
    \\    .terminal .muted { color:#8f9aa5; }
    \\    iframe { width:100%; height:100%; border:0; background:white; }
    \\    .empty { display:grid; place-items:center; color:var(--muted); }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="app">
    \\    <div class="top">
    \\      <div class="brand">cmux zero</div>
    \\      <div class="pill" id="browser-engine">browser</div>
    \\      <div class="pill" id="terminal-engine">terminal</div>
    \\      <div class="spacer"></div>
    \\      <button class="tool" id="new-terminal" title="New terminal">+</button>
    \\      <button class="tool" id="new-browser" title="New browser">B</button>
    \\    </div>
    \\    <aside class="sidebar" id="workspaces"></aside>
    \\    <main class="main">
    \\      <div class="tabs" id="tabs"></div>
    \\      <div class="content" id="content"></div>
    \\    </main>
    \\  </div>
    \\  <script>
    \\    const state = { panes: [], selectedPaneId: 0 };
    \\    const q = (s) => document.querySelector(s);
    \\    async function invoke(command, payload = {}) {
    \\      return await window.zero.invoke(command, payload);
    \\    }
    \\    function paneIcon(kind) { return kind === "terminal" ? "T" : "B"; }
    \\    function browserPane() { return state.panes.find((p) => p.kind === "browser") || state.panes[0]; }
    \\    function terminalPane() { return state.panes.find((p) => p.kind === "terminal") || state.panes[0]; }
    \\    function render() {
    \\      q("#browser-engine").textContent = state.browserEngine;
    \\      q("#terminal-engine").textContent = state.terminalEngine;
    \\      q("#workspaces").innerHTML = `<button class="workspace">main<br><span style="color:var(--muted)">${state.panes.length} panes</span></button>`;
    \\      q("#tabs").innerHTML = state.panes.map((p) => `<button class="tab ${p.id === state.selectedPaneId ? "active" : ""}" data-pane="${p.id}"><span>${paneIcon(p.kind)}</span><span>${p.title}</span></button>`).join("");
    \\      for (const tab of document.querySelectorAll(".tab")) {
    \\        tab.onclick = async () => {
    \\          Object.assign(state, await invoke("workbench.focusPane", { paneId: Number(tab.dataset.pane) }));
    \\          render();
    \\        };
    \\      }
    \\      const terminal = terminalPane();
    \\      const browser = browserPane();
    \\      q("#content").innerHTML = `
    \\        <section class="pane">
    \\          <div class="pane-head"><div class="pane-title">${terminal ? terminal.title : "Terminal"}</div><div class="pill">Ghostty</div></div>
    \\          <div class="terminal" data-native-slot="${terminal ? "ghostty:" + terminal.id : ""}">
    \\            <div class="muted">$ native-slot ${terminal ? terminal.id : "none"}</div>
    \\            <div>$ ${terminal ? terminal.cwd : "~"}</div>
    \\            <div class="muted">surface=${terminal ? terminal.host : "ghostty"} context=split io=exec</div>
    \\          </div>
    \\        </section>
    \\        <section class="pane">
    \\          <div class="pane-head">
    \\            <div class="pane-title">${browser ? browser.title : "Browser"}</div>
    \\            <input class="address" id="address" value="${browser ? browser.url : ""}">
    \\            <button class="go" id="go">Go</button>
    \\          </div>
    \\          ${browser ? `<iframe src="${browser.url}"></iframe>` : `<div class="empty">No browser pane</div>`}
    \\        </section>`;
    \\      const go = q("#go");
    \\      if (go && browser) {
    \\        go.onclick = async () => {
    \\          Object.assign(state, await invoke("workbench.navigateBrowser", { paneId: browser.id, url: q("#address").value }));
    \\          render();
    \\        };
    \\      }
    \\    }
    \\    async function refresh() {
    \\      Object.assign(state, await invoke("workbench.snapshot"));
    \\      render();
    \\    }
    \\    q("#new-terminal").onclick = async () => { Object.assign(state, await invoke("workbench.addTerminal")); render(); };
    \\    q("#new-browser").onclick = async () => { Object.assign(state, await invoke("workbench.addBrowser")); render(); };
    \\    refresh().catch((error) => {
    \\      q("#content").innerHTML = `<div class="empty">${error.code || "error"}: ${error.message}</div>`;
    \\    });
    \\  </script>
    \\</body>
    \\</html>
;

const MaxPanes = 8;
const MaxTitle = 80;
const MaxURL = 512;

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

const allowed_origins = [_][]const u8{ "zero://inline", "zero://app" };

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
            .source = zero_native.WebViewSource.html(html),
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
        try writer.writeAll("{\"browserEngine\":\"chromium-cef\",\"terminalEngine\":");
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
    try std.testing.expect(std.mem.indexOf(u8, response, "chromium-cef") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "ghostty") != null);
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
