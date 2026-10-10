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
    { surface: 5, kind: "browser", title: "about:blank", size: { cols: 80, rows: 24 } },
  ];
  let nextSurface = 10;
  const tree = () => ({ workspaces: [{ id: "w1", screens: [{ panes: [{ tabs }] }] }] });
  const srv = await ndjsonServer(path, (m, conn) => {
    commands.push(m);
    const ok = (data: unknown = {}) => conn.send({ id: m.id, ok: true, data });
    switch (m.cmd) {
      case "identify":
        return ok({ app: "cmux-tui", protocol: 12 });
      case "set-client-info":
      case "subscribe":
      case "set-size-counts":
      case "detach-attached-view":
        return ok();
      case "list-workspaces":
        return ok(tree());
      case "attach-surface":
        conn.send({ event: "vt-state", surface: m.surface, cols: 104, rows: 40, data: Buffer.from("REPLAY$ ").toString("base64") });
        return ok({ lease: "lease-1", participant: "c9" });
      case "send":
        ok();
        conn.send({ event: "output", surface: m.surface, data: Buffer.from(`echo:${Buffer.from(m.bytes, "base64").toString()}`).toString("base64") });
        return;
      case "new-tab": {
        const surface = nextSurface++;
        tabs.push({ surface, kind: "pty", name: null, title: "zsh", size: { cols: 104, rows: 40 }, cwd: "/Users/me", dead: false });
        ok({ surface });
        srv.broadcast({ event: "tab-added", surface });
        return;
      }
      default:
        return conn.send({ id: m.id, ok: false, error: `unknown command ${m.cmd}` });
    }
  });
  return { path, commands, tabs, srv };
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
      ["attach-surface", { surface: 2, mode: "bytes", cols: 10, rows: 10 }],
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
    const { terminal } = await client.request("term.create", { cols: 80, rows: 24 });
    expect(terminal.id).toBe("s10");
    expect(d.commands.filter((c) => c.cmd === "new-tab")).toEqual([{ id: expect.any(Number), cmd: "new-tab" }]);
    // A tab opened on the Mac reaches the phone through tab-added.
    d.tabs.push({ surface: 42, kind: "pty", name: "mac tab", title: "zsh", size: { cols: 90, rows: 30 }, cwd: "/Users/me", dead: false });
    d.srv.broadcast({ event: "tab-added", surface: 42 });
    await waitFor(() => updates.some((t) => t.id === "s42" && t.title === "mac tab"));
    await expect(client.request("term.attach", { terminalId: "s5", cols: 1, rows: 1 })).rejects.toMatchObject({ code: "not_found" }); // browser tab
    await expect(client.request("term.attach", { terminalId: "../x", cols: 1, rows: 1 })).rejects.toMatchObject({ code: "not_found" });
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
        conn.send(rec("user_message", "mux", { text: p.prompt[0].text, promptId: `pp${seq}`, turnId: "t2" }));
        conn.send(rec("turn_started", "mux", { turnId: "t2" }));
        conn.send(rec("permission_request", "mux", { permissionId: "perm9", request: { toolCall: { toolCallId: "tc1", title: "Edit a.txt" }, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] } }));
        conn.send(rec("tool_call", "in", { params: { update: { sessionUpdate: "tool_call", toolCallId: "tc1", title: "echo hi", kind: "execute", status: "in_progress", content: [{ type: "terminal", terminalId: "x" }] } } }));
        conn.send(rec("tool_call_update", "in", { params: { update: { sessionUpdate: "tool_call_update", toolCallId: "tc1", status: "completed", _meta: { terminal_output_delta: { data: "hi\n" }, terminal_exit: { exit_code: 0 } } } } }));
        conn.send(rec("agent_message_chunk", "in", { params: { update: { sessionUpdate: "agent_message_chunk", messageId: "m2", content: { type: "text", text: "Done." } } } }));
        conn.send(rec("turn_result", "mux", { turnId: "t2", status: "completed", stopReason: "end_turn" }));
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
