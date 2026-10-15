// Bridge to the cmux-next app, against fake daemon and fake acpmux sockets.
import { mkdtempSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AcpmuxAgents } from "../src/bridge/acpmuxAgents.ts";
import { DaemonTerminals, ptyTabs } from "../src/bridge/daemonTerminals.ts";
import { PolicyError, checkAcpmuxCall, checkDaemonCommand } from "../src/bridge/policy.ts";
import { TranscriptBuilder } from "../src/bridge/transcript.ts";
import { connectedCore, waitFor } from "./helpers.ts";

const cleanups: (() => unknown)[] = [];
afterEach(async () => {
  for (const f of cleanups.splice(0)) await f();
});

function sockPath(name: string): string {
  return join(mkdtempSync(join(tmpdir(), "cnb-")), name);
}

/** A tiny NDJSON server; handler returns a response body or throws. */
function ndjsonServer(path: string, onLine: (msg: any, conn: { send: (m: unknown) => void }) => void) {
  const conns = new Set<net.Socket>();
  const server = net.createServer((sock) => {
    conns.add(sock);
    sock.setEncoding("utf8");
    let buf = "";
    const conn = { send: (m: unknown) => sock.write(JSON.stringify(m) + "\n") };
    sock.on("data", (d: string) => {
      buf += d;
      let n;
      while ((n = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, n);
        buf = buf.slice(n + 1);
        if (line.trim()) onLine(JSON.parse(line), conn);
      }
    });
    sock.on("close", () => conns.delete(sock));
  });
  return new Promise<{ close: () => Promise<void>; broadcast: (m: unknown) => void }>((resolve) =>
    server.listen(path, () =>
      resolve({
        broadcast: (m) => {
          for (const c of conns) c.write(JSON.stringify(m) + "\n");
        },
        close: () =>
          new Promise((r) => {
            for (const c of conns) c.destroy();
            server.close(() => r());
          }),
      }),
    ),
  );
}

async function fakeDaemon() {
  const path = sockPath("cmux-app-test.sock");
  const commands: any[] = [];
  const tabs: any[] = [
    { surface: 2, kind: "pty", name: null, title: "~", size: { cols: 104, rows: 40 }, cwd: "/Users/me", dead: false },
    { surface: 5, kind: "browser", title: "about:blank", size: { cols: 80, rows: 24 }, tab_resource_id: "tab_00000000000000000000000000000005" },
  ];
  let nextSurface = 10;
  const state = { activeTab: 0 };
  const tree = () => ({
    workspaces: [{ id: 1, name: "Home", active: true, screens: [{ id: 4, active: true, active_pane: 3, layout: { type: "leaf", pane: 3 }, panes: [{ id: 3, active_tab: state.activeTab, tabs }] }] }],
  });
  const srv = await ndjsonServer(path, (m, conn) => {
    commands.push(m);
    const ok = (data: unknown = {}) => conn.send({ id: m.id, ok: true, data });
    switch (m.cmd) {
      case "identify":
        return ok({ app: "cmux-tui", protocol: 12, capabilities: ["attach-initial-size"] });
      case "resize-attached-view": {
        const tab = tabs.find((t) => t.surface === m.surface);
        if (tab) tab.size = { cols: m.cols, rows: m.rows };
        ok({ accepted: true, reservation_id: null, outcome: "applied" });
        srv.broadcast({ event: "surface-resized", surface: m.surface });
        return;
      }
      case "note-size-activity":
        return ok({ participant: "c9", changed: false });
      case "set-client-info":
      case "subscribe":
      case "set-size-counts":
      case "detach-attached-view":
      case "focus-pane":
        return ok();
      case "select-tab":
        state.activeTab = m.index;
        ok();
        srv.broadcast({ event: "tree-changed" });
        return;
      case "list-workspaces":
        return ok(tree());
      case "attach-surface":
        if (!tabs.some((t) => t.surface === m.surface)) return conn.send({ id: m.id, ok: false, error: `unknown surface ${m.surface}` });
        conn.send({ event: "vt-state", surface: m.surface, cols: 104, rows: 40, data: Buffer.from("REPLAY$ ").toString("base64") });
        return ok({ lease: "lease-1", participant: "c9" });
      case "send":
        ok();
        conn.send({ event: "output", surface: m.surface, data: Buffer.from(`echo:${Buffer.from(m.bytes, "base64").toString()}`).toString("base64") });
        return;
      case "new-frontend-browser-tab": {
        const surface = nextSurface++;
        tabs.push({ surface, kind: "browser", title: m.url, url: m.url, size: { cols: 80, rows: 24 }, tab_resource_id: `tab_${String(surface).padStart(32, "0")}` });
        ok({ surface, tab_resource_id: `tab_${String(surface).padStart(32, "0")}`, content_resource_id: "browser_x", replayed: false });
        srv.broadcast({ event: "tab-added", surface });
        return;
      }
      case "close-tabs": {
        const closed = m.surfaces.filter((sf: number) => tabs.some((t) => t.surface === sf));
        for (const sf of closed) tabs.splice(tabs.findIndex((t) => t.surface === sf), 1);
        ok({ closed, terminals: closed.map(() => ({ terminal_id: "t", terminal_incarnation: "i" })) });
        srv.broadcast({ event: "tab-closed" });
        return;
      }
      case "new-tab": {
        const surface = nextSurface++;
        tabs.push({ surface, kind: "pty", name: null, title: "zsh", size: { cols: m.cols ?? 104, rows: m.rows ?? 40 }, cwd: "/Users/me", dead: false });
        ok({ surface });
        srv.broadcast({ event: "tab-added", surface });
        return;
      }
      default:
        return conn.send({ id: m.id, ok: false, error: `unknown command ${m.cmd}` });
    }
  });
  return { path, commands, tabs, srv, state };
}

describe("bridge policy", () => {
  it("denies command-bearing daemon commands and fields", () => {
    for (const [cmd, params] of [
      ["run", { command: "rm -rf ~" }],
      ["create-terminal", { argv: ["/bin/sh"] }],
      ["create-surface-with-receipt", {}],
      ["apply-layout", {}],
      ["new-tab", { cwd: "/" }],
      ["new-tab", { shell_args: ["-c", "id"] }],
      ["new-tab", { env: { X: "1" } }],
      ["split", { dir: "right" }],
      ["attach-surface", { surface: 2, mode: "render" }],
      ["attach-surface", { surface: 2, mode: "bytes", cols: 1, rows: 10 }],
      ["new-tab", { cols: 50000, rows: 10 }],
      ["resize-attached-view", { surface: 2, lease: "l", cols: 10, rows: 10, view: "x" }],
      ["set-size-counts", { surface: 2, counts: true }],
      ["shutdown-daemon", {}],
      ["pairing-response", {}],
      ["agent-session-permission", {}],
      ["send", { surface: "2", bytes: "eA==" }],
      ["send", { surface: 2, bytes: "eA==", text: "x" }],
      ["constructor", {}],
      ["__proto__", {}],
    ] as const) {
      expect(() => checkDaemonCommand(cmd, params as Record<string, unknown>), `${cmd} ${JSON.stringify(params)}`).toThrow(PolicyError);
    }
    expect(() => checkDaemonCommand("new-tab", {})).not.toThrow();
    expect(() => checkDaemonCommand("close-tabs", { surfaces: [3], end_terminals: true })).not.toThrow();
    expect(() => checkDaemonCommand("close-tabs", { surfaces: [3, 4], end_terminals: true })).toThrow(PolicyError);
    expect(() => checkDaemonCommand("close-tabs", { surfaces: [3], end_terminals: true, keep_layout: true })).toThrow(PolicyError);
    expect(() => checkDaemonCommand("new-frontend-browser-tab", { url: "https://example.com/x?y=1", engine: "cef" })).not.toThrow();
    expect(() => checkDaemonCommand("new-frontend-browser-tab", { url: "about:blank", engine: "cef" })).not.toThrow();
    for (const p of [
      { url: "file:///etc/passwd", engine: "cef" },
      { url: "javascript:alert(1)", engine: "cef" },
      { url: "chrome://settings", engine: "cef" },
      { url: "https://user:pw@example.com/", engine: "cef" },
      { url: "https://example.com/", engine: "webkit" },
      { url: "https://example.com/", engine: "cef", pane: 3 },
      { url: "https://example.com/", engine: "cef", owner: "x" },
      { url: "https://example.com/\n", engine: "cef" },
    ]) {
      expect(() => checkDaemonCommand("new-frontend-browser-tab", p), JSON.stringify(p)).toThrow(PolicyError);
    }
    expect(() => checkDaemonCommand("new-browser-tab", { url: "https://example.com/" })).toThrow(PolicyError);
    expect(() => checkDaemonCommand("send", { surface: 2, bytes: "eA==" })).not.toThrow();
  });

  it("denies acpmux methods and params outside the bridge's needs", () => {
    for (const [method, params] of [
      ["_acpmux/peer_add", { name: "x", url: "ws://evil" }],
      ["_acpmux/export", { sessionId: "a", dest: "/tmp/x" }],
      ["_acpmux/import", { path: "/etc/passwd" }],
      ["_acpmux/set_policy", { sessionId: "a", policy: "approve-all" }],
      ["_acpmux/set_rules", { sessionId: "a", rules: null }],
      ["_acpmux/shutdown", {}],
      ["_acpmux/defaults", { set: { env: { X: "1" } } }],
      ["session/new", { cwd: "/Users/me", mcpServers: [{ command: "sh" }], _meta: { acpmux: { harness: "codex" } } }],
      ["session/new", { cwd: "/Users/me", mcpServers: [], _meta: { acpmux: { harness: "codex", policy: "approve-all" } } }],
      ["session/new", { cwd: "/Users/me", mcpServers: [], _meta: { acpmux: { harness: "codex" }, personKey: "k" } }],
      ["session/prompt", { sessionId: "a", prompt: [{ type: "resource", resource: { uri: "file:///etc/passwd" } }] }],
      ["initialize", { clientCapabilities: { terminal: true } }],
    ] as const) {
      expect(() => checkAcpmuxCall(method, params as Record<string, unknown>), method).toThrow(PolicyError);
    }
    expect(() => checkAcpmuxCall("session/new", { cwd: "/Users/me", mcpServers: [], _meta: { acpmux: { harness: "codex", model: "gpt" } } })).not.toThrow();
  });
});

describe("daemon layout bridge", () => {
  it("serves the Mac layout and focuses a tab on the Mac", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const { DaemonLayout } = await import("../src/layout/index.ts");
    const shown: string[] = [];
    const layout = new DaemonLayout(() => d.path, { showBrowserInApp: async (id) => void shown.push(id) });
    const { core, client } = await connectedCore({ bridge: { layout } });
    cleanups.push(() => core.shutdown());
    const { layout: l } = await client.request("layout.get");
    expect(l.workspaces[0]).toMatchObject({ id: "w1", title: "Home", active: true, activePaneId: "p3" });
    expect(l.workspaces[0].panes[0]).toMatchObject({
      id: "p3",
      rect: { x: 0, y: 0, w: 1, h: 1 },
      focusedTabId: "t2",
      tabs: [
        { id: "t2", kind: "terminal", refId: "s2", streamable: true, focused: true },
        { id: "t5", kind: "browser", streamable: false, focused: false },
      ],
    });
    const changed: any[] = [];
    client.peer.on("event", (t, p) => t === "layout.changed" && changed.push(p.layout));
    await client.request("layout.focusTab", { paneId: "p3", tabId: "t5" });
    expect(d.commands.filter((c) => ["focus-pane", "select-tab"].includes(c.cmd)).map((c) => ({ ...c, id: 0 }))).toEqual([
      { id: 0, cmd: "focus-pane", pane: 3 },
      { id: 0, cmd: "select-tab", pane: 3, index: 1 },
    ]);
    await waitFor(() => changed.some((x) => x.workspaces[0].panes[0].focusedTabId === "t5"));
    // A browser tab is also shown in the app window (its own selection).
    expect(shown).toEqual(["tab_00000000000000000000000000000005"]);
    await client.request("layout.focusTab", { paneId: "p3", tabId: "t2" });
    expect(shown).toHaveLength(1); // not for terminals
    await expect(client.request("layout.focusTab", { paneId: "p3", tabId: "t99" })).rejects.toMatchObject({ code: "not_found" });
    await expect(client.request("layout.focusTab", { paneId: "p77", tabId: "t2" })).rejects.toMatchObject({ code: "not_found" });
  });
});

describe("Mac browser tab creation", () => {
  it("creates a CEF tab in the Mac app and waits for its mapping", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const { DaemonLayout } = await import("../src/layout/index.ts");
    let mapped = false;
    const layout = new DaemonLayout(() => d.path, {
      resolveBrowser: (t: any) => (mapped && t.surface >= 10 ? { refId: `CEF-${t.surface}` } : { reason: "not linked yet" }),
    });
    cleanups.push(() => layout.shutdown());
    setTimeout(() => (mapped = true), 400);
    const created = await layout.createBrowserTab("https://example.com/", 5_000);
    expect(created).toMatchObject({ paneId: "p3", tab: { id: "t10", kind: "browser", refId: "CEF-10", streamable: true } });
    expect(d.commands.find((c) => c.cmd === "new-frontend-browser-tab")).toEqual({ id: expect.any(Number), cmd: "new-frontend-browser-tab", url: "https://example.com/", engine: "cef" });
    // Never mapped within the wait: returned unstreamable with the reason.
    mapped = false;
    const unmapped = await layout.createBrowserTab("about:blank", 300);
    expect(unmapped.tab).toMatchObject({ id: "t11", streamable: false, reason: "not linked yet" });
    await expect(layout.createBrowserTab("file:///etc/passwd", 300)).rejects.toThrow(/policy/);
  });
});

describe("daemon terminals bridge", () => {
  it("lists Mac terminals, mirrors output and input, and never takes the Mac's grid", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const terminals = new DaemonTerminals(() => d.path);
    const { core, client } = await connectedCore({ bridge: { terminals } });
    cleanups.push(() => core.shutdown());
    expect((await client.hello()).capabilities).toContain("term.mirror.v1");
    const { terminals: list } = await client.request("term.list");
    expect(list).toEqual([expect.objectContaining({ id: "s2", title: "~", cols: 104, rows: 40, cwd: "/Users/me", running: true })]);

    const { streamId, terminal } = await client.request("term.attach", { terminalId: "s2", cols: 40, rows: 20 });
    expect(terminal).toMatchObject({ cols: 104, rows: 40 });
    let out = "";
    client.onStream(streamId, (p) => (out += Buffer.from(p).toString()));
    await waitFor(() => out.includes("REPLAY$ "));
    client.sendInput(streamId, "ls\r");
    await waitFor(() => out.includes("echo:ls\r"));
    await client.request("term.resize", { terminalId: "s2", cols: 40, rows: 20 });

    const sent = d.commands.map((c) => c.cmd);
    expect(sent).not.toContain("resize-surface");
    expect(sent).not.toContain("resize-attached-view");
    expect(sent).not.toContain("note-size-activity");
    expect(d.commands.find((c) => c.cmd === "attach-surface")).toEqual({ id: expect.any(Number), cmd: "attach-surface", surface: 2, mode: "bytes" });
    expect(d.commands.find((c) => c.cmd === "set-size-counts")).toMatchObject({ surface: 2, counts: false });
    expect(d.commands.find((c) => c.cmd === "send")).toMatchObject({ surface: 2, bytes: Buffer.from("ls\r").toString("base64") });

    await client.request("term.detach", { streamId });
    await waitFor(() => d.commands.some((c) => c.cmd === "detach-attached-view" && c.lease === "lease-1"));
  });

  it("shows terminals created on either side and refuses phone-chosen cwd", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const terminals = new DaemonTerminals(() => d.path);
    const { core, client } = await connectedCore({ bridge: { terminals } });
    cleanups.push(() => core.shutdown());
    const updates: any[] = [];
    client.peer.on("event", (t, p) => t === "term.updated" && updates.push(p.terminal));
    await client.request("term.list");
    await expect(client.request("term.create", { cols: 80, rows: 24, cwd: "/etc" })).rejects.toMatchObject({ code: "unsupported" });
    for (const extra of [{ argv: ["/bin/sh"] }, { env: { X: "1" } }, { shell_args: ["-c", "id"] }, { command: "id" }])
      await expect(client.request("term.create", { cols: 80, rows: 24, ...extra })).rejects.toMatchObject({ code: "unsupported" });
    const { terminal } = await client.request("term.create", { cols: 80, rows: 24, cwd: null });
    expect(terminal.id).toBe("s10");
    expect(d.commands.filter((c) => c.cmd === "new-tab")).toEqual([{ id: expect.any(Number), cmd: "new-tab", cols: 80, rows: 24 }]);
    // A tab opened on the Mac reaches the phone through tab-added.
    d.tabs.push({ surface: 42, kind: "pty", name: "mac tab", title: "zsh", size: { cols: 90, rows: 30 }, cwd: "/Users/me", dead: false });
    d.srv.broadcast({ event: "tab-added", surface: 42 });
    await waitFor(() => updates.some((t) => t.id === "s42" && t.title === "mac tab"));
    await expect(client.request("term.attach", { terminalId: "s5", cols: 1, rows: 1 })).rejects.toMatchObject({ code: "not_found" }); // browser tab
    await expect(client.request("term.attach", { terminalId: "../x", cols: 1, rows: 1 })).rejects.toMatchObject({ code: "not_found" });
    // term.close ends the shell, not just the tab.
    const exited: any[] = [];
    client.peer.on("event", (t, p) => t === "term.exited" && exited.push(p));
    await client.request("term.close", { terminalId: "s10" });
    expect(d.commands.find((c) => c.cmd === "close-tabs")).toEqual({ id: expect.any(Number), cmd: "close-tabs", surfaces: [10], end_terminals: true });
    expect(d.commands.some((c) => c.cmd === "close-surface")).toBe(false);
    expect(exited.map((e) => e.terminalId)).toContain("s10");
    expect((await client.request("term.list")).terminals.map((t: any) => t.id)).not.toContain("s10");
    await expect(client.request("term.close", { terminalId: "s10" })).rejects.toMatchObject({ code: "not_found" });
  });

  it("sizes a terminal the phone created to the phone's grid, and only that one", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const terminals = new DaemonTerminals(() => d.path);
    const { core, client } = await connectedCore({ bridge: { terminals } });
    cleanups.push(() => core.shutdown());
    const { terminal } = await client.request("term.create", { cols: 50, rows: 36 });
    expect(terminal).toMatchObject({ id: "s10", cols: 50, rows: 36 });
    const { streamId } = await client.request("term.attach", { terminalId: "s10", cols: 50, rows: 36 });
    expect(d.commands.find((c) => c.cmd === "attach-surface" && c.surface === 10)).toMatchObject({ mode: "bytes", cols: 50, rows: 36 });
    expect(d.commands.some((c) => c.cmd === "set-size-counts" && c.surface === 10)).toBe(false);
    // Rotation: the phone's new grid reaches the daemon through its lease.
    const updates: any[] = [];
    client.peer.on("event", (t, p) => t === "term.updated" && updates.push(p.terminal));
    await client.request("term.resize", { terminalId: "s10", cols: 90, rows: 20 });
    expect(d.commands.filter((c) => c.cmd === "resize-attached-view").at(-1)).toMatchObject({ surface: 10, lease: "lease-1", cols: 90, rows: 20 });
    expect(d.commands.some((c) => c.cmd === "note-size-activity" && c.surface === 10)).toBe(true);
    await waitFor(() => updates.some((t) => t.id === "s10" && t.cols === 90 && t.rows === 20));
    // A Mac terminal is still never resized from the phone.
    const before = d.commands.filter((c) => c.cmd === "resize-attached-view").length;
    await client.request("term.attach", { terminalId: "s2", cols: 50, rows: 36 });
    await client.request("term.resize", { terminalId: "s2", cols: 50, rows: 36 });
    expect(d.commands.find((c) => c.cmd === "attach-surface" && c.surface === 2)).toEqual({ id: expect.any(Number), cmd: "attach-surface", surface: 2, mode: "bytes" });
    expect(d.commands.filter((c) => c.cmd === "resize-attached-view").length).toBe(before);
    await client.request("term.detach", { streamId });
  });

  it("maps a terminal that ended on the Mac to not_found and drops it from the list", async () => {
    const d = await fakeDaemon();
    cleanups.push(() => d.srv.close());
    const terminals = new DaemonTerminals(() => d.path);
    const { core, client } = await connectedCore({ bridge: { terminals } });
    cleanups.push(() => core.shutdown());
    const exited: any[] = [];
    client.peer.on("event", (t, p) => t === "term.exited" && exited.push(p));
    expect((await client.request("term.list")).terminals.map((t: any) => t.id)).toEqual(["s2"]);
    // The Mac closed the terminal; the host has not heard about it yet.
    d.tabs.splice(d.tabs.findIndex((t) => t.surface === 2), 1);
    await expect(client.request("term.attach", { terminalId: "s2", cols: 80, rows: 24 })).rejects.toMatchObject({ code: "not_found" });
    await waitFor(() => exited.some((e) => e.terminalId === "s2"));
    expect((await client.request("term.list")).terminals).toEqual([]);
  });

  it("recognizes the daemon's gone-terminal errors", async () => {
    const { isGoneError } = await import("../src/bridge/daemonTerminals.ts");
    for (const m of ["attach-surface: unknown surface 7", "unknown terminal abc", "surface 7 not found", "pane disappeared"].slice(0, 3)) expect(isGoneError(m), m).toBe(true);
    for (const m of ["attach-surface: timed out", "connection closed: socket closed", "bad request: x"]) expect(isGoneError(m), m).toBe(false);
  });

  it("finds pty tabs anywhere in the tree", () => {
    expect(ptyTabs({ a: [{ b: { surface: 1, kind: "pty" } }, { surface: 2, kind: "browser" }] }).map((t) => t.surface)).toEqual([1]);
  });
});

async function fakeAcpmux() {
  const path = sockPath("acpmux.sock");
  const calls: any[] = [];
  const sessions = [
    { sessionId: "sess-mac", name: "started on the Mac", harness: "codex", family: "codex", cwd: "/Users/me", status: "idle", createdAt: 1, updatedAt: 2, unread: false },
  ];
  const events: Record<string, any[]> = {
    "sess-mac": [
      { sessionId: "sess-mac", seq: 1, at: 1000, dir: "mux", kind: "user_message", msg: { text: "hello", promptId: "p1", turnId: "t1" } },
      { sessionId: "sess-mac", seq: 2, at: 1000, dir: "mux", kind: "turn_started", msg: { turnId: "t1" } },
      { sessionId: "sess-mac", seq: 3, at: 1100, dir: "in", kind: "agent_message_chunk", msg: { params: { update: { sessionUpdate: "agent_message_chunk", messageId: "m1", content: { type: "text", text: "Hi " } } } } },
      { sessionId: "sess-mac", seq: 4, at: 1200, dir: "in", kind: "agent_message_chunk", msg: { params: { update: { sessionUpdate: "agent_message_chunk", messageId: "m1", content: { type: "text", text: "there" } } } } },
      { sessionId: "sess-mac", seq: 5, at: 1500, dir: "mux", kind: "turn_result", msg: { turnId: "t1", status: "completed", stopReason: "end_turn" } },
    ],
  };
  let seq = 100;
  const srv = await ndjsonServer(path, (m, conn) => {
    calls.push(m);
    const ok = (result: unknown = {}) => conn.send({ jsonrpc: "2.0", id: m.id, result });
    const p = m.params ?? {};
    switch (m.method) {
      case "initialize":
        return ok({ protocolVersion: 1 });
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return ok({ sessions });
      case "_acpmux/harnesses":
        return ok({ families: { claude: ["claude"], codex: ["codex"] } });
      case "_acpmux/models":
        return ok({ harnesses: [{ harness: "codex", models: [{ id: "gpt-x", name: "GPT X" }] }] });
      case "session/new": {
        const s = { sessionId: `sess-${++seq}`, name: "phone session", harness: p._meta.acpmux.harness, family: p._meta.acpmux.harness, cwd: p.cwd, status: "idle", createdAt: 3, updatedAt: 3, unread: false };
        sessions.push(s);
        events[s.sessionId] = [];
        srv.broadcast({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { sessionId: s.sessionId, kind: "created", session: s } });
        return ok({ sessionId: s.sessionId });
      }
      case "_acpmux/attach":
        return ok({ session: sessions.find((s) => s.sessionId === p.sessionId), events: events[p.sessionId] ?? [], hasMore: false, lastSeq: 5 });
      case "session/prompt": {
        const rec = (kind: string, dir: string, msg: unknown) => ({ jsonrpc: "2.0", method: "_acpmux/event", params: { sessionId: p.sessionId, seq: ++seq, at: Date.now(), dir, kind, msg } });
        const sess = sessions.find((x) => x.sessionId === p.sessionId)!;
        const setStatus = (status: string) => {
          sess.status = status;
          srv.broadcast({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { sessionId: sess.sessionId, kind: "updated", session: { ...sess } } });
        };
        setStatus("running");
        conn.send(rec("user_message", "mux", { text: p.prompt[0].text, promptId: `pp${seq}`, turnId: "t2" }));
        conn.send(rec("turn_started", "mux", { turnId: "t2" }));
        conn.send(rec("permission_request", "mux", { permissionId: "perm9", request: { toolCall: { toolCallId: "tc1", title: "Edit a.txt" }, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] } }));
        conn.send(rec("tool_call", "in", { params: { update: { sessionUpdate: "tool_call", toolCallId: "tc1", title: "echo hi", kind: "execute", status: "in_progress", content: [{ type: "terminal", terminalId: "x" }] } } }));
        conn.send(rec("tool_call_update", "in", { params: { update: { sessionUpdate: "tool_call_update", toolCallId: "tc1", status: "completed", _meta: { terminal_output_delta: { data: "hi\n" }, terminal_exit: { exit_code: 0 } } } } }));
        conn.send(rec("agent_message_chunk", "in", { params: { update: { sessionUpdate: "agent_message_chunk", messageId: `m${seq}`, content: { type: "text", text: "Done." } } } }));
        conn.send(rec("turn_result", "mux", { turnId: "t2", status: "completed", stopReason: "end_turn" }));
        setStatus("idle");
        return ok({ stopReason: "end_turn" });
      }
      case "_acpmux/permission_respond":
        if (p.optionId === "allow-unknown") return conn.send({ jsonrpc: "2.0", id: m.id, error: { code: -32000, message: "permission.person_required" } });
        return ok({});
      case "_acpmux/kill":
      case "_acpmux/rename":
      case "session/set_model":
      case "session/set_mode":
        return ok({});
      default:
        if (m.id !== undefined) conn.send({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "nope" } });
    }
  });
  return { path, calls, sessions, srv };
}

describe("acpmux agents bridge", () => {
  it("shows Mac sessions with their transcript and streams phone prompts live", async () => {
    const a = await fakeAcpmux();
    cleanups.push(() => a.srv.close());
    const agents = new AcpmuxAgents(() => a.path);
    const { core, client } = await connectedCore({ bridge: { agents } });
    cleanups.push(() => core.shutdown());

    expect((await client.hello()).capabilities).toContain("agent.mirror.v1");
    const { harnesses } = await client.request("agent.harnesses");
    expect(harnesses.map((h: any) => [h.id, h.available])).toEqual([
      ["claude", true],
      ["codex", true],
    ]);
    expect(harnesses[1].models).toEqual([{ id: "gpt-x", name: "GPT X" }]);
    const { sessions } = await client.request("agent.list");
    expect(sessions).toEqual([expect.objectContaining({ id: "sess-mac", title: "started on the Mac", harness: "codex", status: "idle" })]);

    const h = await client.request("agent.history", { sessionId: "sess-mac" });
    expect(h.items.map((i: any) => [i.kind, i.text ?? i.stopReason])).toEqual([
      ["user", "hello"],
      ["assistant", "Hi there"],
      ["turnEnd", "end_turn"],
    ]);
    expect(h.items[2].durationMs).toBe(500);

    const items = new Map<string, any>();
    client.peer.on("event", (t, p) => t === "agent.item" && items.set(p.item.id, p.item));
    await client.request("agent.prompt", { sessionId: "sess-mac", text: "from the phone" });
    await waitFor(() => [...items.values()].some((i) => i.kind === "turnEnd"));
    const byKind = (k: string) => [...items.values()].filter((i) => i.kind === k);
    expect(byKind("user")[0].text).toBe("from the phone");
    expect(byKind("tool")[0]).toMatchObject({ id: "tool-tc1", status: "completed", output: "hi\n", toolKind: "execute" });
    expect(byKind("permission")[0]).toMatchObject({ id: "perm-perm9", title: "Edit a.txt", options: [{ id: "allow" }, { id: "deny" }] });
    expect(byKind("assistant")[0]).toMatchObject({ text: "Done.", streaming: false });

    await expect(client.request("agent.permission", { sessionId: "sess-mac", itemId: "perm-perm9", optionId: "allow" })).rejects.toMatchObject({
      code: "unsupported",
      message: "Approve this on the Mac",
    });
    expect(a.calls.some((c) => c.method === "_acpmux/permission_respond")).toBe(false);
    await client.request("agent.permission", { sessionId: "sess-mac", itemId: "perm-perm9", optionId: "deny" });
    expect(a.calls.find((c) => c.method === "_acpmux/permission_respond").params).toEqual({ sessionId: "sess-mac", permissionId: "perm9", optionId: "deny" });
    // An allow the bridge could not classify still maps acpmux's refusal.
    await expect(client.request("agent.permission", { sessionId: "sess-mac", itemId: "perm-perm9", optionId: "allow-unknown" })).rejects.toMatchObject({ code: "unsupported", message: "Approve this on the Mac" });
  });

  it("creates sessions with a safe cwd and reports Mac-side changes", async () => {
    const a = await fakeAcpmux();
    cleanups.push(() => a.srv.close());
    const agents = new AcpmuxAgents(() => a.path);
    const { core, client } = await connectedCore({ bridge: { agents } });
    cleanups.push(() => core.shutdown());
    const sessionsSeen: any[] = [];
    client.peer.on("event", (t, p) => t === "agent.session" && sessionsSeen.push(p.session));
    await expect(client.request("agent.create", { harness: "codex", cwd: "/etc" })).rejects.toMatchObject({ code: "bad_request" });
    const { session } = await client.request("agent.create", { harness: "codex", model: "gpt-x" });
    const newCall = a.calls.find((c) => c.method === "session/new");
    expect(newCall.params).toEqual({ cwd: expect.stringMatching(/^\//), mcpServers: [], _meta: { acpmux: { harness: "codex", model: "gpt-x" } } });
    expect(session.harness).toBe("codex");
    await waitFor(() => sessionsSeen.some((s) => s.id === session.id));
    // A session created with a first prompt streams that turn without agent.history.
    const items: any[] = [];
    client.peer.on("event", (t, p) => t === "agent.item" && items.push(p));
    const { session: s2 } = await client.request("agent.create", { harness: "codex", prompt: "first" });
    await waitFor(() => items.some((i) => i.sessionId === s2.id && i.item.kind === "turnEnd"));
    const attachIdx = a.calls.findIndex((c) => c.method === "_acpmux/attach" && c.params.sessionId === s2.id);
    const promptIdx = a.calls.findIndex((c) => c.method === "session/prompt" && c.params.sessionId === s2.id);
    expect(attachIdx).toBeGreaterThan(-1);
    expect(attachIdx).toBeLessThan(promptIdx);
  });
});

describe("session preview", () => {
  it("separates concatenated assistant messages", async () => {
    const { cleanPreview } = await import("../src/bridge/acpmuxAgents.ts");
    expect(cleanPreview("Checked its response.No HTTP status line was found.")).toBe("Checked its response. No HTTP status line was found.");
    expect(cleanPreview("Version 1.2.3 is out")).toBe("Version 1.2.3 is out");
    expect(cleanPreview("a\n\nb")).toBe("a b");
  });
});

describe("bridged session status", () => {
  it("shows a session whose last turn failed as error, and closed sessions as closed", async () => {
    const { toAgentSession, mapStatus } = await import("../src/bridge/acpmuxAgents.ts");
    const base = { sessionId: "s", name: "claude", harness: "claude", cwd: "/Users/me", createdAt: 1, updatedAt: 2 };
    const failed = toAgentSession({ ...base, status: "ready", preview: "", lastTurn: { status: "failed", errorText: "Not logged in · Please run /login" } });
    expect(failed).toMatchObject({ status: "error", preview: "Not logged in · Please run /login" });
    expect(toAgentSession({ ...base, status: "ready", lastTurn: { status: "completed" } }).status).toBe("idle");
    expect(toAgentSession({ ...base, status: "closed", lastTurn: { status: "failed" } }).status).toBe("closed");
    expect(mapStatus("running", { status: "failed" })).toBe("running");
    expect(mapStatus("error")).toBe("error");
    expect(mapStatus("exited")).toBe("closed");
  });
});

describe("Chief in bridge mode", () => {
  it("starts /spawn sessions through acpmux so they are real Mac sessions", async () => {
    const a = await fakeAcpmux();
    cleanups.push(() => a.srv.close());
    const agents = new AcpmuxAgents(() => a.path);
    const { core, client } = await connectedCore({ bridge: { agents } });
    cleanups.push(() => core.shutdown());
    const messages: any[] = [];
    client.peer.on("event", (t, p) => t === "conv.message" && messages.push(p.message));
    await client.request("conv.send", { conversationId: "chief", text: "please spawn something", clientId: "c1" });
    await waitFor(() => messages.some((m) => m.text.startsWith("Started")), 15_000);
    expect(messages.find((m) => m.text.startsWith("Started")).text).toBe("Started Codex: phone session");
    const created = a.calls.filter((c) => c.method === "session/new");
    expect(created).toHaveLength(1);
    expect(created[0].params._meta.acpmux.harness).toBe("codex");
    expect(a.calls.some((c) => c.method === "session/prompt" && c.params.prompt[0].text === "fix the flaky test")).toBe(true);
    // Listed by agent.list (acpmux), like any Mac session.
    const { sessions } = await client.request("agent.list");
    expect(sessions.map((s: any) => s.id)).toContain(created[0].params ? a.sessions.at(-1)!.sessionId : "");
    // The host's own agents never started it.
    expect(core.agents.list()).toEqual([]);

    // Home lists an agent:<sessionId> conversation for it with the task and the agent's reply.
    const sessionId = a.sessions.at(-1)!.sessionId;
    const convId = `agent:${sessionId}`;
    const { conversations } = await client.request("conv.list");
    expect(conversations.find((c: any) => c.id === convId)).toMatchObject({ kind: "agent", title: "phone session", subtitle: "Codex" });
    const history = async () => (await client.request("conv.history", { conversationId: convId })).messages.map((m: any) => [m.sender.isMe, m.text]);
    await waitFor(async () => (await history()).length >= 2);
    expect(await history()).toEqual([
      [true, "fix the flaky test"],
      [false, "Done."],
    ]);

    // Texting it prompts the acpmux session; typing follows its running state.
    const typing: any[] = [];
    client.peer.on("event", (t, p) => t === "conv.typing" && p.conversationId === convId && typing.push(p.typing));
    await client.request("conv.send", { conversationId: convId, text: "and the other one", clientId: "c2" });
    expect(a.calls.some((c) => c.method === "session/prompt" && c.params.sessionId === sessionId && c.params.prompt[0].text === "and the other one")).toBe(true);
    await waitFor(() => typing.length >= 2);
    expect(typing).toEqual([true, false]);
    await waitFor(async () => (await history()).length >= 4);
    const msgs = (await client.request("conv.history", { conversationId: convId })).messages;
    expect(msgs.map((m: any) => [m.sender.isMe, m.text, m.status])).toEqual([
      [true, "fix the flaky test", "read"],
      [false, "Done.", "delivered"],
      [true, "and the other one", "read"],
      [false, "Done.", "delivered"],
    ]);

    // Removed on the Mac: the conversation goes too.
    const removed: string[] = [];
    client.peer.on("event", (t, p) => t === "conv.removed" && removed.push(p.conversationId));
    a.srv.broadcast({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { sessionId, kind: "purged", session: { sessionId } } });
    await waitFor(() => removed.includes(convId));
  });
});

describe("transcript builder", () => {
  it("ignores replayed records and keeps ids stable across rebuilds", () => {
    const rec = { sessionId: "s", seq: 1, at: 0, dir: "mux", kind: "user_message", msg: { text: "x", promptId: "p" } };
    const a = new TranscriptBuilder();
    a.apply(rec);
    expect(a.apply(rec)).toEqual([]);
    const b = new TranscriptBuilder();
    b.apply(rec);
    expect(b.items.map((i) => i.id)).toEqual(a.items.map((i) => i.id));
  });
});
