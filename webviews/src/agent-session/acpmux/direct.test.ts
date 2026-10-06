import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  AcpmuxDirectClient,
  applySupersededMessage,
  initialSession,
  mergeEventRecords,
  permissionFromMessage,
  settleOptimisticPrompt,
} from "./direct";
import type { EventRecord } from "./direct";
import { AcpWireLog } from "./wire";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { isNewChat } from "./EmptyState";
import { translate } from "./i18n";

describe("direct acpmux event helpers", () => {
  test("uses the permission notification envelope session id", () => {
    const permission = permissionFromMessage(
      {
        sessionId: "selected",
        permissionId: "permission-1",
        groupId: "group-1",
        turnId: "turn-1",
        request: {
          sessionId: "agent-request-id",
          toolCall: { title: "Run command", kind: "execute" },
          options: [{ optionId: "yes", name: "Allow", kind: "allow_once" }],
        },
      },
      "selected",
    );
    expect(permission?.permissionId).toBe("permission-1");
    expect(permission?.groupId).toBe("group-1");
    expect(permission?.turnId).toBe("turn-1");
    expect(permission?.options[0]?.id).toBe("yes");
  });

  test("removes an optimistic prompt when mux records it", () => {
    const rows = new Map<string, AcpmuxRow>([
      ["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }],
    ]);
    const promptRows = new Map([["p1", "local-p1"]]);
    settleOptimisticPrompt(rows, promptRows, { promptId: "p1" });
    expect(rows.has("local-p1")).toBe(false);
    expect(promptRows.has("p1")).toBe(false);
  });

  test("merges attach pages with live events without dropping either", () => {
    const event = (seq: number) => ({
      seq,
      at: seq,
      sessionId: "s",
      dir: "mux",
      kind: "status",
      msg: { status: "ready" },
    });
    expect(mergeEventRecords([event(1), event(2)], [event(2), event(3)]).map((item) => item.seq)).toEqual([1, 2, 3]);
  });

  test("reconciles older user messages by text when promptId is absent", () => {
    const rows = new Map<string, AcpmuxRow>([
      ["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }],
    ]);
    const promptRows = new Map([["p1", "local-p1"]]);
    const promptTexts = new Map([["p1", "hello"]]);
    const fallbackPromptId = [...promptTexts.entries()].find(([, value]) => value === "hello")?.[0];
    settleOptimisticPrompt(rows, promptRows, { promptId: fallbackPromptId, text: "hello" });
    expect(rows.has("local-p1")).toBe(false);
  });

  test("drops the abandoned assistant row on a superseded message", () => {
    const rows = new Map<string, AcpmuxRow>([
      ["assistant-1", { id: "assistant-1", version: 1, at: 1, kind: "assistant", text: "partial" }],
    ]);
    const messageRows = new Map([["old-message", ["assistant-1"]]]);
    const superseded = new Set<string>();
    applySupersededMessage(rows, messageRows, superseded, "old-message");
    expect(rows.has("assistant-1")).toBe(false);
    expect(superseded.has("old-message")).toBe(true);
  });
});

describe("initial session", () => {
  const sessions = [{ sessionId: "recent" }, { sessionId: "older" }];
  test("keeps the host's session", () => expect(initialSession("older", sessions)).toBe("older"));
  test("falls back to the most recent session", () => expect(initialSession(undefined, sessions)).toBe("recent"));
  test("a new chat attaches nothing until its first prompt", () =>
    expect(initialSession(undefined, sessions, true)).toBeUndefined());
});

type Request = { id?: number; method: string; params: Record<string, any> };

/// A loopback acpmux whose replies a test scripts, holding back any method it names.
class ScriptedSocket {
  static OPEN = 1;
  static current: ScriptedSocket;
  static respond: (request: Request) => unknown = () => ({});
  static held = new Set<string>();
  readyState = 0;
  sent: Request[] = [];
  waiting: Request[] = [];
  onopen?: () => void;
  onerror?: () => void;
  onclose?: () => void;
  onmessage?: (message: { data: string }) => void;
  constructor(readonly url: URL) {
    ScriptedSocket.current = this;
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string) {
    const request = JSON.parse(raw) as Request;
    this.sent.push(request);
    if (request.id === undefined) return;
    if (ScriptedSocket.held.has(request.method)) {
      this.waiting.push(request);
      return;
    }
    const result = ScriptedSocket.respond(request);
    queueMicrotask(() => this.reply(request, result));
  }
  reply(request: Request, result: unknown) {
    this.onmessage?.({ data: JSON.stringify({ id: request.id, result }) });
  }
  release(method: string, result: unknown) {
    const index = this.waiting.findIndex((request) => request.method === method);
    if (index < 0) throw new Error(`no ${method} request is waiting`);
    const [request] = this.waiting.splice(index, 1);
    this.reply(request!, result);
  }
  /// Answers a held request with a JSON-RPC error.
  fail(method: string, error: { code?: number; message?: string; data?: unknown } = { message: `${method} failed` }) {
    const index = this.waiting.findIndex((request) => request.method === method);
    if (index < 0) throw new Error(`no ${method} request is waiting`);
    const [request] = this.waiting.splice(index, 1);
    this.onmessage?.({ data: JSON.stringify({ id: request!.id, error }) });
  }
  notify(method: string, params: unknown) {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }
  close() {
    this.readyState = 3;
  }
  drop() {
    this.readyState = 3;
    this.onclose?.();
  }
}

const userEvent = (sessionId: string, seq: number, text: string): EventRecord => ({
  sessionId,
  seq,
  at: seq,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
/// Drops the socket and waits out the client's first reconnect delay.
const dropAndReconnect = async () => {
  const dropped = ScriptedSocket.current;
  dropped.drop();
  await new Promise((resolve) => setTimeout(resolve, 300));
  for (let pass = 0; pass < 5 && ScriptedSocket.current === dropped; pass += 1) await settle();
  for (let pass = 0; pass < 5; pass += 1) await settle();
};

describe("direct client session state", () => {
  const realSocket = globalThis.WebSocket;
  const host = {
    protocolVersion: 1,
    transport: "acpmux-websocket",
    endpoint: "ws://127.0.0.1:4100/acp",
    token: "t",
    sessionId: "a",
  } as const;
  let snapshots: AcpmuxSnapshot[];
  const latest = () => snapshots[snapshots.length - 1]!;
  const texts = () => latest().rows.map((row) => row.text);
  /// Session "a" starts at seq 5 with a queued prompt; "b" holds one message.
  const attachReply = (sessionId: string) =>
    sessionId === "a"
      ? {
          session: {
            sessionId: "a",
            status: "idle",
            queue: [{ promptId: "q1", prompt: "queued" }],
          },
          events: [userEvent("a", 5, "a five"), userEvent("a", 6, "a six")],
        }
      : { session: { sessionId: "b", status: "idle" }, events: [userEvent("b", 1, "b one")] };

  beforeEach(() => {
    snapshots = [];
    ScriptedSocket.held = new Set();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    (globalThis as any).WebSocket = ScriptedSocket;
    (globalThis as any).window ??= globalThis;
  });
  afterEach(() => {
    (globalThis as any).WebSocket = realSocket;
  });

  const connect = () => AcpmuxDirectClient.connect(host, (snapshot) => snapshots.push(snapshot));

  test("warms one live child for each recent project without creating a session", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch")
        return {
          sessions: [
            { sessionId: "a", cwd: "/work/cmux", updatedAt: 30 },
            { sessionId: "b", cwd: "/work/cmux", updatedAt: 20 },
            { sessionId: "c", cwd: "/work/other", updatedAt: 10 },
          ],
        };
      if (method === "_acpmux/attach") return { session: { sessionId: params.sessionId }, events: [] };
      return {};
    };
    const client = await connect();
    await client.warmRecentProjects();
    const warm = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/warm");
    expect(warm?.params).toEqual({ sessionIds: ["a", "c"], limit: 3 });
    client.close();
  });

  test("grouped permissions reconcile on attach, suppress duplicate requests and keep interactive asks", async () => {
    const operations = [
      "_acpmux/permission_groups",
      "_acpmux/permission_group_respond",
      "_acpmux/permission_chat_revoke",
    ];
    const group = {
      groupId: "g",
      sessionId: "a",
      turnId: "t",
      revision: 3,
      state: "pending",
      decision: null,
      decisions: ["allow_once", "allow_chat", "deny"],
      items: [
        {
          permissionId: "grouped",
          state: "pending",
          request: {
            toolCall: { kind: "edit", title: "Write app" },
            options: [
              { optionId: "yes", kind: "allow_once" },
              { optionId: "no", kind: "reject_once" },
            ],
          },
        },
      ],
    };
    let reads = 0;
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "initialize") return { _meta: { acpmux: { operations } } };
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
      if (method === "_acpmux/attach")
        return {
          ...attachReply(params.sessionId),
          session: {
            sessionId: params.sessionId,
            pending: [
              {
                permissionId: "grouped",
                request: { toolCall: { title: "Write app" }, options: [] },
              },
              {
                permissionId: "question",
                request: { toolCall: { title: "Choose a target" }, options: [] },
              },
            ],
          },
        };
      if (method === "_acpmux/permission_groups") {
        reads++;
        return {
          groups: params.sessionId === "a" ? [group] : [],
          chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
          coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP only" },
          batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
        };
      }
      return {};
    };
    const client = await connect();
    expect(latest().permissionGroups?.groups[0]?.groupId).toBe("g");
    expect(latest().permission?.permissionId).toBe("question");
    ScriptedSocket.current.notify("_acpmux/permission_pending", {
      sessionId: "a",
      permissionId: "grouped",
      groupId: "g",
      turnId: "t",
      request: { options: [] },
    });
    expect(latest().permission?.permissionId).toBe("question");
    ScriptedSocket.current.notify("_acpmux/event", {
      sessionId: "a",
      seq: 9,
      at: 9,
      dir: "mux",
      kind: "permission_group",
      msg: { group },
    });
    await settle();
    expect(reads).toBeGreaterThan(1);
    ScriptedSocket.current.notify("_acpmux/event", {
      sessionId: "a",
      seq: 10,
      at: 10,
      dir: "mux",
      kind: "permission_decision",
      msg: { permissionId: "question" },
    });
    ScriptedSocket.held.add("_acpmux/permission_groups");
    ScriptedSocket.current.notify("_acpmux/event", {
      sessionId: "a",
      seq: 11,
      at: 11,
      dir: "mux",
      kind: "permission_group",
      msg: { group },
    });
    await settle();
    ScriptedSocket.current.fail("_acpmux/permission_groups", {
      code: -32601,
      message: "Unsupported",
      data: { reason: "operation.unsupported" },
    });
    await settle();
    expect(latest().permissionGroups?.supported).toBe(false);
    expect(latest().permission?.permissionId).toBe("grouped");
    ScriptedSocket.held.delete("_acpmux/permission_groups");
    await client.select("b");
    expect(latest().permissionGroups?.groups).toEqual([]);
    client.close();
  });

  test("an unavailable group read retains an individual interactive ask from the attach snapshot", async () => {
    ScriptedSocket.held.add("_acpmux/permission_groups");
    ScriptedSocket.respond = ({ method }) => {
      if (method === "initialize")
        return {
          _meta: {
            acpmux: {
              operations: [
                "_acpmux/permission_groups",
                "_acpmux/permission_group_respond",
                "_acpmux/permission_chat_revoke",
              ],
            },
          },
        };
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }] };
      if (method === "_acpmux/attach")
        return {
          events: [],
          session: {
            sessionId: "a",
            pending: [
              { permissionId: "grouped", groupId: "g", turnId: "t", request: { options: [] } },
              {
                permissionId: "question",
                groupId: null,
                turnId: null,
                request: { toolCall: { title: "Choose a target" }, options: [] },
              },
            ],
          },
        };
      return {};
    };
    const connecting = connect();
    await settle();
    ScriptedSocket.current.fail("_acpmux/permission_groups", {
      code: -32000,
      message: "The owner is unavailable.",
    });
    const client = await connecting;
    expect(latest().permission?.permissionId).toBe("question");
    expect(latest().permissionGroups?.ready).toBe(false);
    client.close();
  });

  test("a fresh session whose first kept record is its command list is a new chat with its folder", async () => {
    const commands: EventRecord = {
      sessionId: "a",
      seq: 14,
      at: 14,
      dir: "in",
      kind: "available_commands_update",
      msg: {
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: "a",
          update: {
            sessionUpdate: "available_commands_update",
            availableCommands: [{ name: "review", description: "Review changes" }],
          },
        },
      },
    };
    ScriptedSocket.respond = ({ method }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }] };
      if (method === "_acpmux/attach")
        return {
          session: {
            sessionId: "a",
            status: "idle",
            cwd: "/Users/me/harness-research",
            turnCount: 0,
          },
          events: [commands],
        };
      return {};
    };
    const client = await connect();
    await settle();
    // Seq 14 leaves older records unloaded, so history alone cannot say the chat is new.
    expect(latest().canLoadOlder).toBe(true);
    expect(latest().summary?.cwd).toBe("/Users/me/harness-research");
    expect(isNewChat(latest())).toBe(true);
    client.close();
  });

  test("a linked session the daemon lacks is refused, not replaced by the latest chat, and marks nothing seen", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a", unread: true }, { sessionId: "b" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    const client = await AcpmuxDirectClient.connect(
      { ...host, sessionId: "bogus", sessionMustExist: true },
      (snapshot) => snapshots.push(snapshot),
    );
    await settle();
    expect(latest().sessionId).toBeUndefined();
    expect(latest().missingSession).toBe("bogus");
    expect(latest().rows).toEqual([]);
    expect(ScriptedSocket.current.sent.map((request) => request.method)).not.toContain("_acpmux/attach");
    expect(latest().sessions.find((session) => session.sessionId === "a")?.unread).toBe(true);
    // Choosing a chat afterwards clears the notice.
    await client.select("b");
    await settle();
    expect(latest().missingSession).toBeUndefined();
    client.close();
  });

  test("without the link's strictness a missing session still falls back to the latest chat", async () => {
    const client = await AcpmuxDirectClient.connect({ ...host, sessionId: "bogus" }, (snapshot) =>
      snapshots.push(snapshot),
    );
    await settle();
    expect(latest().sessionId).toBe("a");
    expect(latest().missingSession).toBeUndefined();
    client.close();
  });

  test("a new chat opens in the chosen project's folder, and without one leaves the folder to the daemon", async () => {
    const client = await connect();
    await client.create("codex", "/Users/me/code/notes");
    await client.create();
    const created = ScriptedSocket.current.sent.filter((request) => request.method === "session/new");
    expect(created.map((request) => request.params.cwd)).toEqual(["/Users/me/code/notes", undefined]);
    expect(created.map((request) => "cwd" in request.params)).toEqual([true, false]);
    expect(created[0]!.params._meta).toEqual({ acpmux: { harness: "codex" } });
    client.close();
  });

  test("connect attaches without waiting on the harness catalog, which the pane queries itself", async () => {
    ScriptedSocket.held = new Set(["_acpmux/harnesses"]);
    const client = await connect();
    expect(ScriptedSocket.current.sent.map((request) => request.method)).not.toContain("_acpmux/harnesses");
    expect(latest().catalog).toEqual([]);
    const catalog = client.harnesses();
    await settle();
    ScriptedSocket.current.release("_acpmux/harnesses", {
      harnesses: { codex: { name: "Codex", models: [{ modelId: "gpt-6-astra" }] } },
    });
    expect(await catalog).toEqual([{ id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: undefined }] }]);
  });

  test("only the first new chat starts in the inherited cwd", async () => {
    let created = 0;
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [] };
      if (method === "session/new") return { sessionId: `n${(created += 1)}` };
      if (method === "_acpmux/attach") return { session: { sessionId: params.sessionId, status: "idle" }, events: [] };
      return {};
    };
    const client = await AcpmuxDirectClient.connect(
      { ...host, sessionId: undefined, newSession: true, cwd: "/work/app" },
      (snapshot) => snapshots.push(snapshot),
    );
    await client.create("claude");
    await client.create("codex");
    const news = ScriptedSocket.current.sent.filter((request) => request.method === "session/new");
    expect(news.map((request) => request.params.cwd)).toEqual(["/work/app", undefined]);
  });

  test("a resumed chat is adopted on connect, once, without the inherited cwd", async () => {
    const adopt = { harness: "claude", agentSessionId: "0a1b2c3d" };
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [] };
      if (method === "session/new")
        return {
          sessionId: "adopted",
          _meta: { acpmux: { agentSessionId: params._meta.acpmux.adopt?.agentSessionId } },
        };
      if (method === "_acpmux/attach") return { session: { sessionId: params.sessionId, status: "idle" }, events: [] };
      return {};
    };
    const client = await AcpmuxDirectClient.connect(
      { ...host, sessionId: undefined, newSession: true, cwd: "/work/app", adopt },
      (snapshot) => snapshots.push(snapshot),
    );
    const news = ScriptedSocket.current.sent.filter((request) => request.method === "session/new");
    expect(news.map((request) => request.params)).toEqual([
      { mcpServers: [], _meta: { acpmux: { harness: "claude", adopt } } },
    ]);
    expect(snapshots.at(-1)?.summary?.sessionId).toBe("adopted");
    expect(client.adopted).toBe("adopted");
    expect(await client.ensureSession()).toBe("adopted");
    expect(ScriptedSocket.current.sent.filter((request) => request.method === "session/new")).toHaveLength(1);
  });

  test("a daemon that can't adopt gets its fresh session removed and the pane says so", async () => {
    ScriptedSocket.respond = ({ method }) => {
      if (method === "_acpmux/watch") return { sessions: [] };
      if (method === "session/new") return { sessionId: "fresh", _meta: { acpmux: { agentSessionId: "its-own" } } };
      return {};
    };
    const client = await AcpmuxDirectClient.connect(
      {
        ...host,
        sessionId: undefined,
        newSession: true,
        adopt: { harness: "codex", agentSessionId: "01999a2b" },
      },
      (snapshot) => snapshots.push(snapshot),
    );
    expect(client.adopted).toBeUndefined();
    const kills = ScriptedSocket.current.sent.filter((request) => request.method === "_acpmux/kill");
    expect(kills.map((request) => request.params)).toEqual([{ sessionId: "fresh", purge: true }]);
    expect(ScriptedSocket.current.sent.some((request) => request.method === "_acpmux/attach")).toBe(false);
    const last = snapshots.at(-1);
    expect(last?.connection).toBe("connected");
    expect(last?.rows.at(-1)).toMatchObject({
      kind: "notice",
      text: "Couldn't resume this chat: this acpmux can't resume chats",
    });
  });

  test("a socket that drops while adopting fails the connect instead of claiming the chat can't resume", async () => {
    ScriptedSocket.respond = ({ method }) => (method === "_acpmux/watch" ? { sessions: [] } : {});
    ScriptedSocket.held = new Set(["session/new"]);
    const connecting = AcpmuxDirectClient.connect(
      {
        ...host,
        sessionId: undefined,
        newSession: true,
        adopt: { harness: "claude", agentSessionId: "0a1b2c3d" },
      },
      (snapshot) => snapshots.push(snapshot),
    );
    for (let tries = 0; tries < 20 && ScriptedSocket.current?.waiting.length === 0; tries += 1) await settle();
    ScriptedSocket.current.drop();
    expect(
      await connecting.then(
        () => "connected",
        () => "rejected",
      ),
    ).toBe("rejected");
    expect(snapshots.flatMap((snapshot) => snapshot.rows).some((row) => row.kind === "notice")).toBe(false);
  });

  test("a chat started in a chosen project leaves the inherited cwd for the next default chat", async () => {
    let created = 0;
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [] };
      if (method === "session/new") return { sessionId: `n${(created += 1)}` };
      if (method === "_acpmux/attach") return { session: { sessionId: params.sessionId, status: "idle" }, events: [] };
      return {};
    };
    const client = await AcpmuxDirectClient.connect(
      { ...host, sessionId: undefined, newSession: true, cwd: "/work/app" },
      (snapshot) => snapshots.push(snapshot),
    );
    await client.create("claude", "/work/notes", "devbox");
    await client.create("claude");
    await client.create("codex");
    const news = ScriptedSocket.current.sent.filter((request) => request.method === "session/new");
    expect(news.map((request) => request.params.cwd)).toEqual(["/work/notes", "/work/app", undefined]);
    expect(news[0]?.params._meta.acpmux.peer).toBe("devbox");
  });

  test("a turn that ends in the background is unread until its session is selected, and survives a reread", async () => {
    const client = await connect();
    const unread = () =>
      Object.fromEntries(latest().sessions.map((session) => [session.sessionId, session.unread === true]));
    const change = (session: Record<string, unknown>) =>
      ScriptedSocket.current.notify("_acpmux/session_changed", { kind: "updated", session });
    change({ sessionId: "b", status: "running" });
    expect(unread()).toEqual({ a: false, b: false });
    change({ sessionId: "b", status: "idle" });
    expect(unread()).toEqual({ a: false, b: true });
    // Later changes and a full reread after a watch lag keep it.
    change({ sessionId: "b", status: "idle", title: "Renamed" });
    expect(unread().b).toBe(true);
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: [], watch: true, dropped: 1 });
    await settle();
    await settle();
    expect(ScriptedSocket.current.sent.filter((request) => request.method === "_acpmux/watch")).toHaveLength(2);
    expect(unread()).toEqual({ a: false, b: true });
    // The selected session's own turn ending is seen as it happens.
    change({ sessionId: "a", status: "running" });
    change({ sessionId: "a", status: "idle" });
    expect(unread().a).toBe(false);
    await client.select("b");
    await settle();
    expect(unread()).toEqual({ a: false, b: false });
    client.close();
  });

  test("a turn whose end only a reread shows is unread; a fallback selection is seen", async () => {
    const client = await connect();
    const unread = () =>
      Object.fromEntries(latest().sessions.map((session) => [session.sessionId, session.unread === true]));
    ScriptedSocket.current.notify("_acpmux/session_changed", {
      kind: "updated",
      session: { sessionId: "b", status: "running" },
    });
    // The notice that b finished was dropped; the reread after the lag shows it idle.
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b", status: "idle" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: [], watch: true, dropped: 1 });
    await settle();
    await settle();
    expect(unread()).toEqual({ a: false, b: true });
    // Purging the selected session falls back to b, which is then on screen.
    ScriptedSocket.current.notify("_acpmux/session_changed", {
      kind: "purged",
      session: { sessionId: "a" },
    });
    await settle();
    expect(latest().sessionId).toBe("b");
    expect(unread()).toEqual({ b: false });
    client.close();
  });

  test("the wire log records each request, its reply and a dropped socket", async () => {
    const wire = new AcpWireLog();
    const client = await AcpmuxDirectClient.connect(
      host,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      undefined,
      undefined,
      wire,
    );
    ScriptedSocket.current.notify("session/update", {
      sessionId: "a",
      update: { sessionUpdate: "agent_message_chunk" },
    });
    const requests = wire.entries().filter((entry) => entry.kind === "request");
    const methods = requests.map((entry) => entry.method);
    expect(methods.slice(0, 4)).toEqual(["initialize", "_acpmux/status", "_acpmux/watch", "_acpmux/attach"]);
    // Every request that was answered pairs with its reply and its latency.
    const replies = wire.entries().filter((entry) => entry.kind === "response");
    expect(replies.length).toBeGreaterThanOrEqual(3);
    expect(replies.map((entry) => entry.method)).toEqual(
      replies.map((reply) => requests.find((request) => request.id === reply.id)?.method),
    );
    expect(replies.every((entry) => typeof entry.latencyMs === "number")).toBe(true);
    expect(wire.entries().at(-1)).toMatchObject({
      dir: "in",
      kind: "notification",
      method: "session/update",
    });
    const lifecycle = () =>
      wire
        .entries()
        .filter((entry) => entry.kind === "lifecycle")
        .map((entry) => entry.event);
    expect(lifecycle()).toEqual(["connecting", "open", "connected"]);
    expect(JSON.stringify(wire.entries())).not.toContain("token=t");
    ScriptedSocket.current.drop();
    expect(lifecycle().slice(3)).toEqual(["close", "reconnect scheduled"]);
    client.close();
  });

  test("purging an unselected session refreshes the picker", async () => {
    await connect();
    const before = snapshots.length;
    ScriptedSocket.current.notify("_acpmux/session_changed", {
      kind: "purged",
      session: { sessionId: "b" },
    });
    expect(snapshots.length).toBe(before + 1);
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a"]);
    ScriptedSocket.current.notify("_acpmux/session_changed", {
      kind: "created",
      session: { sessionId: "c", title: "Elsewhere" },
    });
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a", "c"]);
    expect(latest().sessionId).toBe("a");
  });

  test("history pages through events and keeps the live summary, queue and permission", async () => {
    const client = await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", {
      sessionId: "a",
      permissionId: "p1",
      request: { toolCall: { title: "Run" }, options: [] },
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/events"
        ? { events: [userEvent("a", 3, "a three"), userEvent("a", 4, "a four")], more: true }
        : {};
    await client.loadOlder();
    const methods = ScriptedSocket.current.sent.map((request) => request.method);
    expect(methods.filter((method) => method === "_acpmux/attach").length).toBe(1);
    expect(ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/events")?.params.beforeSeq).toBe(
      5,
    );
    expect(texts()).toEqual(["a three", "a four", "a five", "a six"]);
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
    expect(latest().summary?.status).toBe("idle");
    expect(latest().permission?.permissionId).toBe("p1");
    expect(latest().canLoadOlder).toBe(true);
  });

  test("history stops when the daemon reports no more", async () => {
    const client = await connect();
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/events" ? { events: [userEvent("a", 3, "a three")], more: false } : {};
    await client.loadOlder();
    expect(texts()).toEqual(["a three", "a five", "a six"]);
    expect(latest().canLoadOlder).toBe(false);
  });

  test("a history page that lands after the selection changed is dropped", async () => {
    const client = await connect();
    ScriptedSocket.held.add("_acpmux/events");
    const older = client.loadOlder();
    await settle();
    await client.select("b");
    ScriptedSocket.current.release("_acpmux/events", {
      events: [userEvent("a", 3, "stale a three")],
    });
    await older;
    client.snapshot();
    expect(latest().sessionId).toBe("b");
    expect(texts()).toEqual(["b one"]);
  });

  test("a request on a socket that is not open rejects instead of hanging", async () => {
    const client = await connect();
    ScriptedSocket.current.readyState = 3;
    const sent = ScriptedSocket.current.sent.length;
    const outcome = await Promise.race([
      client.setModel("m").then(
        () => "resolved",
        () => "rejected",
      ),
      new Promise((resolve) => setTimeout(() => resolve("pending"), 100)),
    ]);
    expect(outcome).toBe("rejected");
    expect(ScriptedSocket.current.sent.length).toBe(sent);
  });

  test("lag recovery merges missed events without clearing the transcript", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/prompt");
    void client.send("still sending").catch(() => undefined);
    await settle();
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 3,
    });
    expect(texts()).toEqual(["a five", "a six", "still sending"]);
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "still sending"]);
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
  });

  test("a lag notice without session IDs resyncs the selected session", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/events" && params.sessionId === "a" && params.afterSeq === 6
        ? { events: [userEvent("a", 7, "a seven")] }
        : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { dropped: 2 });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven"]);
  });

  test("a lag notice for other sessions leaves the selected one alone", async () => {
    await connect();
    const sent = ScriptedSocket.current.sent.length;
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["b"],
      watch: false,
      dropped: 1,
    });
    await settle();
    expect(ScriptedSocket.current.sent.length).toBe(sent);
  });

  test("lag recovery pages until the daemon reports no more", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method !== "_acpmux/events") return {};
      if (params.afterSeq === 6) return { events: [userEvent("a", 7, "a seven")], more: true };
      if (params.afterSeq === 7) return { events: [userEvent("a", 8, "a eight")], more: false };
      return {};
    };
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 2,
    });
    await settle();
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "a eight"]);
  });

  test("lag paging continues from the page it fetched, not from live events that landed meanwhile", async () => {
    await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 9,
    });
    ScriptedSocket.current.notify("_acpmux/event", userEvent("a", 12, "a twelve"));
    ScriptedSocket.current.release("_acpmux/events", {
      events: [userEvent("a", 7, "a seven"), userEvent("a", 8, "a eight")],
      more: true,
    });
    await settle();
    expect(ScriptedSocket.current.waiting.find((request) => request.method === "_acpmux/events")?.params.afterSeq).toBe(
      8,
    );
    ScriptedSocket.current.release("_acpmux/events", {
      events: [9, 10, 11].map((seq) => userEvent("a", seq, `a ${seq}`)),
      more: false,
    });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "a eight", "a 9", "a 10", "a 11", "a twelve"]);
  });

  test("a lag notice before the selected session's attach returns waits for the attach", async () => {
    const client = await connect();
    ScriptedSocket.held.add("_acpmux/attach");
    const selecting = client.select("b");
    await settle();
    ScriptedSocket.current.notify("_acpmux/lagged", { dropped: 1 });
    await settle();
    expect(ScriptedSocket.current.sent.some((request) => request.method === "_acpmux/events")).toBe(false);
    ScriptedSocket.current.release("_acpmux/attach", {
      session: { sessionId: "b", status: "idle" },
      events: [userEvent("b", 1, "b one")],
    });
    await selecting;
    expect(texts()).toEqual(["b one"]);
  });

  test("a watch lag refreshes the session picker", async () => {
    await connect();
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/watch"
        ? { sessions: [{ sessionId: "a" }, { sessionId: "b" }, { sessionId: "c" }] }
        : { events: [] };
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: [], watch: true, dropped: 4 });
    await settle();
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a", "b", "c"]);
  });

  test("lag recovery for a session that is no longer selected is ignored", async () => {
    const client = await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 1,
    });
    await client.select("b");
    ScriptedSocket.current.release("_acpmux/events", {
      events: [userEvent("a", 7, "stale a seven")],
    });
    await settle();
    client.snapshot();
    expect(texts()).toEqual(["b one"]);
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 1,
    });
    expect(ScriptedSocket.current.waiting.length).toBe(0);
  });

  test("selecting a session drops the previous session's queue, summary, permission and pending prompt", async () => {
    const client = await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", {
      sessionId: "a",
      permissionId: "p1",
      request: { toolCall: { title: "Run" }, options: [] },
    });
    ScriptedSocket.held.add("session/prompt");
    void client.send("still sending").catch(() => undefined);
    await settle();
    expect(texts()).toContain("still sending");
    ScriptedSocket.held.add("_acpmux/attach");
    const selected = client.select("b");
    await settle();
    client.snapshot();
    expect(latest().rows).toEqual([]);
    expect(latest().queue).toEqual([]);
    expect(latest().summary).toBeUndefined();
    expect(latest().permission).toBeUndefined();
    ScriptedSocket.current.release("_acpmux/attach", attachReply("b"));
    expect(await selected).toBe("b");
    expect(texts()).toEqual(["b one"]);
  });

  // bench-switch-race.mjs (plans/cmux-next/acp-usability.md, blocker 3): a prompt sent while a
  // harness switch's session/new is out went to the OLD session, and the pane then moved to the
  // new chat, so its reply landed out of view.
  test("a prompt sent while a new chat's session starts goes to that session, not the one on screen", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/new");
    const switching = client.create("codex");
    await settle();
    ScriptedSocket.held.add("session/prompt");
    const sent = client.send("which harness?").catch(() => undefined);
    await settle();
    expect(ScriptedSocket.current.waiting.some((request) => request.method === "session/prompt")).toBe(false);
    ScriptedSocket.current.release("session/new", { sessionId: "b" });
    expect(await switching).toBe("b");
    await settle();
    const prompt = ScriptedSocket.current.waiting.find((request) => request.method === "session/prompt");
    expect(prompt?.params.sessionId).toBe("b");
    expect(texts()).toContain("which harness?");
    ScriptedSocket.current.release("session/prompt", {});
    expect(await sent).toBe("b");
  });

  // The acpmux pool (fdfc0cd36ee) refuses a hint over a remote-origin connection, and every
  // WebSocket connection is remote-origin unless acpmux says otherwise in initialize.
  test("a prewarm hint goes out only when acpmux lists _acpmux/prewarm and calls this connection local", async () => {
    const hinted = async (meta: Record<string, unknown> | undefined) => {
      ScriptedSocket.respond = ({ method, params }) => {
        if (method === "initialize") return meta ? { _meta: { acpmux: meta } } : {};
        if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
        if (method === "_acpmux/attach") return attachReply(params.sessionId);
        if (method === "_acpmux/prewarm") throw new Error("never awaited");
        return {};
      };
      const client = await connect();
      // The folder argument is new; the cast keeps this test compiling before it exists.
      (client.prewarm as (...args: unknown[]) => void).call(client, "codex", "/work/app");
      await settle();
      const sent = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/prewarm")?.params;
      client.close();
      return sent;
    };
    expect(await hinted(undefined)).toBeUndefined();
    expect(await hinted({ extensions: ["_acpmux/prewarm"] })).toBeUndefined();
    expect(await hinted({ extensions: ["_acpmux/prewarm"], origin: "remote" })).toBeUndefined();
    expect(await hinted({ extensions: [], origin: "local" })).toBeUndefined();
    expect(await hinted({ extensions: ["_acpmux/prewarm"], origin: "local" })).toEqual({
      harness: "codex",
      cwd: "/work/app",
    });
  });

  // acpmux names the connection's origin in initialize; the composer's remote state follows it.
  test("the snapshot carries the origin acpmux names, and unknown when it names none", async () => {
    const originFor = async (meta: Record<string, unknown> | undefined) => {
      ScriptedSocket.respond = ({ method, params }) => {
        if (method === "initialize") return meta ? { _meta: { acpmux: meta } } : {};
        if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }] };
        if (method === "_acpmux/attach") return attachReply(params.sessionId);
        return {};
      };
      const client = await connect();
      await settle();
      const origin = latest().origin;
      client.close();
      return origin;
    };
    expect(await originFor({ origin: "remote" })).toBe("remote");
    expect(await originFor({ origin: "local" })).toBe("local");
    expect(await originFor({ origin: "peer" })).toBe("peer");
    expect(await originFor({ origin: "elsewhere" })).toBe("unknown");
    expect(await originFor(undefined)).toBe("unknown");
  });

  test("a refused prewarm hint is ignored and never blocks", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "initialize") return { _meta: { acpmux: { extensions: ["_acpmux/prewarm"], origin: "local" } } };
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    const client = await connect();
    ScriptedSocket.held.add("_acpmux/prewarm");
    expect(client.prewarm("codex")).toBeUndefined();
    ScriptedSocket.current.fail("_acpmux/prewarm", { code: -32602, message: "the session pool is off" });
    await settle();
    client.close();
  });

  test("leaving the shown session detaches it and draws no session; a started one is not shown", async () => {
    const client = await connect();
    expect(client.shownSession()).toMatchObject({ sessionId: "a", empty: false });
    client.leave();
    expect(latest().sessionId).toBeUndefined();
    expect(latest().rows).toEqual([]);
    await settle();
    expect(ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/detach")?.params).toEqual({
      sessionId: "a",
    });
    ScriptedSocket.respond = ({ method }) => (method === "session/new" ? { sessionId: "c" } : {});
    expect(await client.startSession("codex")).toBe("c");
    expect(client.selectedSession).toBeUndefined();
    client.close();
  });

  test("lag recovery keeps the live summary, queue and permission", async () => {
    await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", {
      sessionId: "a",
      permissionId: "p1",
      request: { toolCall: { title: "Run" }, options: [] },
    });
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 1,
    });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven"]);
    expect(latest().permission?.permissionId).toBe("p1");
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
    expect(latest().summary?.status).toBe("idle");
  });

  test("lag recovery still applies a missed permission decision and status", async () => {
    await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", {
      sessionId: "a",
      permissionId: "p1",
      request: { toolCall: { title: "Run" }, options: [] },
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/events"
        ? {
            events: [
              { sessionId: "a", seq: 7, at: 7, dir: "mux", kind: "permission_decision", msg: {} },
              {
                sessionId: "a",
                seq: 8,
                at: 8,
                dir: "mux",
                kind: "status",
                msg: { status: "running" },
              },
            ],
          }
        : {};
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 2,
    });
    await settle();
    expect(latest().permission).toBeUndefined();
    expect(latest().summary?.status).toBe("running");
  });

  test("a failed lag fetch does not leave the pane resyncing", async () => {
    await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 1,
    });
    expect(latest().connection).toBe("resyncing");
    ScriptedSocket.current.fail("_acpmux/events");
    await settle();
    expect(latest().connection).toBe("failed");
  });

  test("a reconnect that finds the selected session gone waits for the new attach before a lag resync", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "b" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    ScriptedSocket.held.add("_acpmux/attach");
    await dropAndReconnect();
    expect(
      ScriptedSocket.current.waiting.find((request) => request.method === "_acpmux/attach")?.params.sessionId,
    ).toBe("b");
    ScriptedSocket.current.notify("_acpmux/lagged", { dropped: 1 });
    await settle();
    expect(ScriptedSocket.current.sent.some((request) => request.method === "_acpmux/events")).toBe(false);
    ScriptedSocket.current.release("_acpmux/attach", attachReply("b"));
    await settle();
    expect(latest().sessionId).toBe("b");
    expect(texts()).toEqual(["b one"]);
  });

  test("a reconnect re-attach fetches the events between the old cursor and the new attach page", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
      if (method === "_acpmux/attach")
        return {
          session: { sessionId: "a", status: "idle" },
          events: [userEvent("a", 10, "a ten"), userEvent("a", 11, "a eleven")],
        };
      if (method === "_acpmux/events" && params.afterSeq === 6)
        return { events: [userEvent("a", 7, "a seven"), userEvent("a", 8, "a eight")], more: true };
      if (method === "_acpmux/events" && params.afterSeq === 8)
        return { events: [userEvent("a", 9, "a nine"), userEvent("a", 10, "a ten")], more: false };
      return {};
    };
    await dropAndReconnect();
    expect(texts()).toEqual(["a five", "a six", "a seven", "a eight", "a nine", "a ten", "a eleven"]);
  });

  test("a watch lag that drops the selected session selects the most recent remaining one", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "b" }] };
      if (method === "_acpmux/attach") return attachReply(params.sessionId);
      return {};
    };
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: [], watch: true, dropped: 4 });
    await settle();
    await settle();
    expect(latest().sessionId).toBe("b");
    expect(texts()).toEqual(["b one"]);
    expect(latest().queue).toEqual([]);
  });

  test("closing the client settles its pending requests", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/set_model");
    const outcome = Promise.race([
      client.setModel("m").then(
        () => "resolved",
        () => "rejected",
      ),
      new Promise((resolve) => setTimeout(() => resolve("pending"), 100)),
    ]);
    await settle();
    client.close();
    expect(await outcome).toBe("rejected");
  });

  const commandsEvent = (sessionId: string, seq: number, names: string[]): EventRecord => ({
    sessionId,
    seq,
    at: seq,
    dir: "in",
    kind: "available_commands_update",
    msg: {
      method: "session/update",
      params: {
        update: {
          sessionUpdate: "available_commands_update",
          availableCommands: names.map((name) => ({ name, description: `${name} help` })),
        },
      },
    },
  });

  test("attach asks for the commands with the transcript and keeps them out of the rows", async () => {
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/attach"
        ? {
            ...attachReply(params.sessionId),
            events: [userEvent("a", 5, "a five"), commandsEvent("a", 6, ["review"])],
            lastSeq: 6,
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    const attach = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/attach")!;
    expect(attach.params.kinds).toEqual(["transcript", "available_commands_update", "usage_update"]);
    expect(ScriptedSocket.current.sent.some((request) => request.method === "_acpmux/events")).toBe(false);
    expect(texts()).toEqual(["a five"]);
    expect(latest().commands).toEqual([{ name: "review", description: "review help", hint: undefined }]);
    ScriptedSocket.current.notify("session/update", {
      sessionId: "a",
      update: {
        sessionUpdate: "available_commands_update",
        availableCommands: [{ name: "compact", description: "" }],
      },
      _meta: { acpmux: { seq: 7 } },
    });
    expect(latest().commands?.map((command) => command.name)).toEqual(["compact"]);
  });

  test("the context used comes from the agent's last usage update, stays out of the rows, and resets with the session", async () => {
    const usage = (sessionId: string, seq: number, used: number) => ({
      sessionId,
      seq,
      at: seq,
      dir: "in",
      kind: "usage_update",
      msg: {
        method: "session/update",
        params: { update: { sessionUpdate: "usage_update", used, size: 200000 } },
      },
    });
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/attach"
        ? {
            ...attachReply(params.sessionId),
            events: params.sessionId === "a" ? [userEvent("a", 5, "a five"), usage("a", 6, 33551)] : [],
            lastSeq: 6,
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }, { sessionId: "b" }] }
          : {};
    const client = await connect();
    expect(texts()).toEqual(["a five"]);
    expect(latest().summary?.usage).toEqual({ used: 33551, size: 200000 });
    ScriptedSocket.current.notify("session/update", {
      sessionId: "a",
      update: { sessionUpdate: "usage_update", used: 50000, size: 200000 },
      _meta: { acpmux: { seq: 7 } },
    });
    expect(latest().summary?.usage).toEqual({ used: 50000, size: 200000 });
    await client.select("b");
    expect(latest().summary?.usage).toBeUndefined();
  });

  test("commands older than the attach page are fetched by kind, and a session switch drops them", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
      if (method === "_acpmux/attach")
        return { ...attachReply(params.sessionId), lastSeq: params.sessionId === "a" ? 900 : 0 };
      if (method === "_acpmux/events") return { events: [commandsEvent("a", 2, ["init", "review"])] };
      return {};
    };
    const client = await connect();
    await settle();
    const fetch = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/events")!;
    expect(fetch.params).toEqual({
      sessionId: "a",
      beforeSeq: 901,
      limit: 1,
      kinds: ["available_commands_update"],
    });
    expect(latest().commands?.map((command) => command.name)).toEqual(["init", "review"]);
    await client.select("b");
    expect(latest().commands).toEqual([]);
  });

  test("a live update that lands while the fetch is in flight wins, even when it empties the list", async () => {
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/attach"
        ? { ...attachReply(params.sessionId), lastSeq: 900 }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    ScriptedSocket.current.notify("session/update", {
      sessionId: "a",
      update: { sessionUpdate: "available_commands_update", availableCommands: [] },
      _meta: { acpmux: { seq: 901 } },
    });
    ScriptedSocket.current.release("_acpmux/events", { events: [commandsEvent("a", 2, ["init"])] });
    await settle();
    expect(latest().commands).toEqual([]);
  });

  test("a prompt with attachments sends the text, its text files and then its images, and shows the text it recorded", async () => {
    const client = await connect();
    await client.send("Compare", [
      {
        id: "i",
        kind: "image",
        name: "shot.png",
        mimeType: "image/png",
        size: 4,
        data: "iVBORw==",
      },
      { id: "t", kind: "text", name: "a.txt", mimeType: "text/plain", size: 1, text: "x" },
    ]);
    const prompt = ScriptedSocket.current.sent.find((request) => request.method === "session/prompt")!;
    expect(prompt.params.prompt).toEqual([
      { type: "text", text: "Compare\n\na.txt\n```txt\nx\n```" },
      { type: "image", mimeType: "image/png", data: "iVBORw==" },
    ]);
    expect(texts().at(-1)).toBe("Compare\n\na.txt\n```txt\nx\n```");
  });

  test("the agent's prompt capabilities reach the snapshot", async () => {
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/attach"
        ? {
            ...attachReply(params.sessionId),
            session: {
              sessionId: "a",
              agentCapabilities: { promptCapabilities: { image: false } },
            },
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    expect(latest().summary?.promptCapabilities).toEqual({ image: false });
  });

  test("a failed prompt row survives a lag rebuild", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/prompt");
    const sending = client.send("did not send").catch(() => "failed");
    await settle();
    ScriptedSocket.current.fail("session/prompt");
    expect(await sending).toBe("failed");
    ScriptedSocket.respond = ({ method, params }) =>
      method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", {
      sessionIds: ["a"],
      watch: false,
      dropped: 1,
    });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "did not send"]);
    expect(latest().rows.find((row) => row.text === "did not send")?.failed).toBe(true);
  });

  /// The host refuses a prompt that has no user gesture (decision 27): the bubble says so on its
  /// row and offers Retry, the connection stays up, and Retry sends the same prompt once more.
  test("a prompt the host refuses says why on its bubble, and Retry sends it again", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/prompt");
    const sending = client.send("not yet").catch(() => "refused");
    await settle();
    const pendingRow = latest().rows.find((row) => row.text === "not yet")!;
    expect(pendingRow.pending).toBe(true);
    ScriptedSocket.current.fail("session/prompt", {
      code: -32601,
      message: "Refused by the cmux host",
      data: { code: "transport.gesture_required", origin: "native", method: "session/prompt" },
    });
    expect(await sending).toBe("refused");
    const failed = latest().rows.find((row) => row.text === "not yet")!;
    // A new row object: MessageRow is memoized on the row's identity and version, so a row
    // changed in place would keep drawing as a plain bubble.
    expect(failed).not.toBe(pendingRow);
    expect(failed.failed).toBe(true);
    expect(failed.error).toBe(translate("prompt.notSentGesture"));
    expect(latest().connection).toBe("connected");

    const prompts = () => ScriptedSocket.current.sent.filter((request) => request.method === "session/prompt").length;
    const before = prompts();
    ScriptedSocket.held.delete("session/prompt");
    await client.retryPrompt(failed.id);
    await settle();
    expect(prompts()).toBe(before + 1);
    const rows = latest().rows.filter((row) => row.text === "not yet");
    expect(rows.length).toBe(1);
    expect(rows[0]!.failed).toBeFalsy();
  });

  /// Any other failure names its reason on the bubble.
  test("a prompt that fails for another reason names it on its bubble", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/prompt");
    const sending = client.send("broken").catch(() => "failed");
    await settle();
    ScriptedSocket.current.fail("session/prompt", { code: -32000, message: "harness exited" });
    expect(await sending).toBe("failed");
    const failed = latest().rows.find((row) => row.text === "broken")!;
    expect(failed.error).toBe(translate("prompt.notSent", { reason: "harness exited" }));
  });

  /// A row made without an event (a failed prompt) sorts after the events it saw, and live events
  /// that arrive after it sort below it; it does not stick to the bottom of the transcript.
  test("a failed prompt row stays above the turns that come after it", async () => {
    const client = await connect();
    ScriptedSocket.held.add("session/prompt");
    const sending = client.send("did not send").catch(() => "failed");
    await settle();
    ScriptedSocket.current.fail("session/prompt");
    expect(await sending).toBe("failed");
    ScriptedSocket.current.notify("_acpmux/event", { ...userEvent("a", 7, "a later prompt"), at: 7 });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "did not send", "a later prompt"]);
  });

  test("a gesture ticket rides on set_mode and set_config_option as _meta.cmuxGesture", async () => {
    const client = await connect();
    await settle();
    await client.setMode("plan", "ticket-1");
    await client.setConfig("reasoning_effort", "high", "ticket-2");
    await client.setMode("auto");
    const sent = ScriptedSocket.current.sent.filter((request) => request.method.startsWith("session/set_"));
    expect(sent.map((request) => request.params._meta)).toEqual([
      { cmuxGesture: "ticket-1" },
      { cmuxGesture: "ticket-2" },
      undefined,
    ]);
  });

  /// ACP wraps a tool call's output as `{ type: "content", content: { type: "text" } }`.
  test("a tool call's wrapped text content becomes its output", async () => {
    const update: EventRecord = {
      sessionId: "a",
      seq: 2,
      at: 2000,
      dir: "in",
      kind: "tool_call",
      msg: {
        method: "session/update",
        params: {
          sessionId: "a",
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "t1",
            kind: "execute",
            title: "Run bun test",
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: "2 pass\n0 fail" } }],
          },
        },
      },
    };
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [userEvent("a", 1, "test it"), update],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    const call = latest()
      .rows.flatMap((row) => row.items ?? [])
      .find((item) => item.tool?.id === "t1");
    expect(call?.tool?.output).toBe("2 pass\n0 fail");
  });

  test("a turn summary counts the turn's tool calls and its time", async () => {
    const update = (seq: number, update: Record<string, unknown>): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq * 1000,
      dir: "in",
      kind: String(update.sessionUpdate),
      msg: { method: "session/update", params: { sessionId: "a", update } },
    });
    const tool = (seq: number, toolCallId: string) =>
      update(seq, { sessionUpdate: "tool_call", toolCallId, title: "Run", status: "completed" });
    const result = (seq: number): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq * 1000,
      dir: "mux",
      kind: "turn_result",
      msg: { status: "completed" },
    });
    const user = (seq: number, text: string): EventRecord => ({
      ...userEvent("a", seq, text),
      at: seq * 1000,
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [
              user(1, "one"),
              tool(2, "t1"),
              result(3),
              user(4, "two"),
              tool(5, "t2"),
              tool(6, "t3"),
              tool(7, "t4"),
              result(10),
            ],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    expect(
      latest()
        .rows.filter((row) => row.kind === "turnSummary")
        .map((row) => [row.toolCount, row.durationMs]),
    ).toEqual([
      [1, 2000],
      [3, 6000],
    ]);
  });

  test("a prompt queued during a turn does not restart that turn's count", async () => {
    const tool = (seq: number, toolCallId: string): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq * 1000,
      dir: "in",
      kind: "tool_call",
      msg: {
        method: "session/update",
        params: {
          sessionId: "a",
          update: { sessionUpdate: "tool_call", toolCallId, title: "Run", status: "completed" },
        },
      },
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [{ ...userEvent("a", 1, "one"), at: 1000 }, tool(2, "t1"), tool(3, "t2")],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    const client = await connect();
    await settle();
    ScriptedSocket.held.add("session/prompt");
    void client.send("queued").catch(() => undefined);
    await settle();
    ScriptedSocket.current.notify("_acpmux/event", {
      sessionId: "a",
      seq: 4,
      at: 4000,
      dir: "mux",
      kind: "turn_result",
      msg: { status: "completed" },
    });
    await settle();
    expect(
      latest()
        .rows.filter((row) => row.kind === "turnSummary")
        .map((row) => [row.toolCount, row.durationMs]),
    ).toEqual([[2, 3000]]);
  });

  test("tool calls between agent messages split the reply into segments in order", async () => {
    const update = (seq: number, update: Record<string, unknown>): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq,
      dir: "in",
      kind: String(update.sessionUpdate),
      msg: { method: "session/update", params: { sessionId: "a", update } },
    });
    const chunk = (seq: number, text: string) =>
      update(seq, { sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
    const tool = (seq: number, toolCallId: string, status: string) =>
      update(seq, {
        sessionUpdate: seq % 2 ? "tool_call" : "tool_call_update",
        toolCallId,
        title: "Run",
        status,
      });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [
              userEvent("a", 5, "run it"),
              chunk(6, "I'll inspect total.py."),
              tool(7, "t1", "pending"),
              tool(8, "t1", "completed"),
              chunk(9, "rg is unavailable,"),
              chunk(10, " so I read the file."),
              tool(11, "t2", "completed"),
              chunk(12, "It prints 64.35."),
            ],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    expect(latest().rows.map((row) => [row.kind, row.kind === "activity" ? row.toolCount : row.text])).toEqual([
      ["user", "run it"],
      ["assistant", "I'll inspect total.py."],
      ["activity", 1],
      ["assistant", "rg is unavailable, so I read the file."],
      ["activity", 1],
      ["assistant", "It prints 64.35."],
    ]);
  });

  test("a user message ends the reply streaming before it", async () => {
    const chunk = (seq: number, text: string): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId: "a",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
        },
      },
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [chunk(5, "Welcome."), userEvent("a", 6, "hi"), chunk(7, "Hello.")],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    expect(latest().rows.map((row) => [row.kind, row.text])).toEqual([
      ["assistant", "Welcome."],
      ["user", "hi"],
      ["assistant", "Hello."],
    ]);
  });

  test("a superseded message drops every segment it was split into", async () => {
    const update = (seq: number, update: Record<string, unknown>): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq,
      dir: "in",
      kind: String(update.sessionUpdate),
      msg: { method: "session/update", params: { sessionId: "a", update } },
    });
    const chunk = (seq: number, text: string) =>
      update(seq, {
        sessionUpdate: "agent_message_chunk",
        messageId: "m1",
        content: { type: "text", text },
      });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [
              userEvent("a", 5, "run it"),
              chunk(6, "Before."),
              update(7, {
                sessionUpdate: "tool_call",
                toolCallId: "t1",
                title: "Run",
                status: "completed",
              }),
              chunk(8, "After."),
              {
                sessionId: "a",
                seq: 9,
                at: 9,
                dir: "mux",
                kind: "message_superseded",
                msg: { oldMessageId: "m1" },
              },
            ],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    await connect();
    await settle();
    expect(latest().rows.filter((row) => row.kind === "assistant")).toEqual([]);
  });

  const chunkEvent = (seq: number, text: string) => ({
    sessionId: "a",
    seq,
    at: seq,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: { sessionId: "a", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
    },
  });

  test("deltas that land in one display frame make one snapshot, in order", async () => {
    const frames: (() => void)[] = [];
    const previous = AcpmuxDirectClient.scheduleFrame;
    AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
    try {
      const client = await connect();
      await settle();
      for (const run of frames.splice(0)) run();
      const before = snapshots.length;
      for (let seq = 7; seq < 12; seq += 1) ScriptedSocket.current.notify("_acpmux/event", chunkEvent(seq, `${seq} `));
      await settle();
      expect(snapshots.length).toBe(before);
      expect(frames).toHaveLength(1);
      frames.shift()!();
      expect(snapshots.length).toBe(before + 1);
      expect(texts()).toEqual(["a five", "a six", "7 8 9 10 11 "]);
      client.close();
    } finally {
      AcpmuxDirectClient.scheduleFrame = previous;
    }
  });

  // A harness switch leaves the shown session and attaches the new one; with snapshots coalesced
  // per display frame, the old session's last deltas and the new chat's first snapshot can land
  // in the same frame. The frame must draw only the new chat.
  test("leave() and the new chat's first snapshot in one frame draw only the new chat", async () => {
    const frames: (() => void)[] = [];
    const previous = AcpmuxDirectClient.scheduleFrame;
    AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
    try {
      const client = await connect();
      await settle();
      for (const run of frames.splice(0)) run();
      ScriptedSocket.current.notify("_acpmux/event", chunkEvent(7, "old reply "));
      client.leave();
      expect(latest().sessionId).toBeUndefined();
      expect(latest().rows).toEqual([]);
      const opened = client.select("b");
      ScriptedSocket.current.notify("_acpmux/event", chunkEvent(8, "late old delta"));
      expect(await opened).toBe("b");
      const fromLeave = snapshots.length;
      for (const run of frames.splice(0)) run();
      for (const snapshot of snapshots.slice(fromLeave))
        expect(snapshot.rows.map((row) => row.text)).not.toContain("old reply late old delta");
      expect(latest().sessionId).toBe("b");
      expect(texts()).toEqual(["b one"]);
      client.close();
    } finally {
      AcpmuxDirectClient.scheduleFrame = previous;
    }
  });

  test("two notices in the same millisecond are two rows", async () => {
    const client = await connect();
    const realNow = Date.now;
    Date.now = () => 1_000;
    try {
      client.notice("first");
      client.notice("second");
    } finally {
      Date.now = realNow;
    }
    expect(texts().filter((text) => text === "first" || text === "second")).toEqual(["first", "second"]);
    client.close();
  });

  test("a streamed thought is one item that grows, not one item per chunk", async () => {
    const thought = (seq: number, text: string): EventRecord => ({
      sessionId: "a",
      seq,
      at: seq,
      dir: "in",
      kind: "agent_thought_chunk",
      msg: {
        method: "session/update",
        params: { sessionId: "a", update: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text } } },
      },
    });
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            events: [
              userEvent("a", 6, "prompt"),
              thought(7, "Looking at "),
              thought(8, "the code"),
              thought(9, " now."),
            ],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    const client = await connect();
    await settle();
    const activity = latest().rows.find((row) => row.kind === "activity");
    expect(activity?.items).toEqual([{ kind: "thought", text: "Looking at the code now." }]);
    client.close();
  });

  test("rows keep the daemon's event order even when wall-clock times disagree", async () => {
    ScriptedSocket.respond = ({ method }) =>
      method === "_acpmux/attach"
        ? {
            session: { sessionId: "a", status: "idle" },
            // The reply's time stamp is earlier than its prompt's (two clocks, or one millisecond).
            events: [
              { ...userEvent("a", 6, "prompt"), at: 2_000 },
              { ...chunkEvent(7, "reply"), at: 1_000 },
            ],
          }
        : method === "_acpmux/watch"
          ? { sessions: [{ sessionId: "a" }] }
          : {};
    const client = await connect();
    await settle();
    expect(texts()).toEqual(["prompt", "reply"]);
    client.close();
  });

  test("without a display (no frame scheduler) each delta snapshots at once", async () => {
    const previous = AcpmuxDirectClient.scheduleFrame;
    AcpmuxDirectClient.scheduleFrame = undefined;
    try {
      const client = await connect();
      await settle();
      const before = snapshots.length;
      ScriptedSocket.current.notify("_acpmux/event", chunkEvent(7, "hi"));
      await settle();
      expect(snapshots.length).toBe(before + 1);
      client.close();
    } finally {
      AcpmuxDirectClient.scheduleFrame = previous;
    }
  });
});

/// acpmux serves no git methods, so the changes view's reads go to the native host, which runs
/// them on the session host in the selected session's folder.
describe("direct client git reads", () => {
  const realSocket = globalThis.WebSocket;
  const host = {
    protocolVersion: 1,
    transport: "acpmux-websocket",
    endpoint: "ws://127.0.0.1:4100/acp",
    token: "t",
    sessionId: "a",
  } as const;
  let posted: { method: string; params: Record<string, unknown> }[];
  let answer: (method: string) => unknown;
  const folders: Record<string, string | undefined> = { a: "/work/a", b: "/work/b" };

  beforeEach(() => {
    posted = [];
    answer = (method) => ({ ok: true, value: { method } });
    ScriptedSocket.held = new Set();
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b", cwd: folders.b }] };
      if (method === "_acpmux/attach")
        return {
          session: { sessionId: params.sessionId, status: "idle", cwd: folders[params.sessionId] },
          events: [],
        };
      return {};
    };
    (globalThis as any).WebSocket = ScriptedSocket;
    (globalThis as any).window ??= globalThis;
    (globalThis as any).webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method: string; params: Record<string, unknown> }) {
            posted.push({ method: message.method, params: message.params });
            return Promise.resolve(answer(message.method));
          },
        },
      },
    };
  });
  afterEach(() => {
    (globalThis as any).WebSocket = realSocket;
    delete (globalThis as any).webkit;
    folders.a = "/work/a";
  });

  const connect = () => AcpmuxDirectClient.connect(host, () => {});
  const gitSent = () => ScriptedSocket.current.sent.filter((request) => request.method.startsWith("git."));

  test("a scope and the status go to the native host with the selected session's folder", async () => {
    const client = await connect();
    await settle();
    expect(await client.gitDiff("staged")).toEqual({ method: "git.diff" });
    expect(await client.gitStatus()).toEqual({ method: "git.status" });
    await client.select("b");
    await settle();
    await client.gitDiff("branch");
    expect(posted).toEqual([
      { method: "git.diff", params: { cwd: "/work/a", scope: "staged", include_patch: true } },
      { method: "git.status", params: { cwd: "/work/a" } },
      { method: "git.diff", params: { cwd: "/work/b", scope: "branch", include_patch: true } },
    ]);
    expect(gitSent()).toEqual([]);
    client.close();
  });

  test("the host's refusal rejects with its message", async () => {
    answer = () => ({
      ok: false,
      error: { code: "git_failed", userMessage: "The changes could not be read." },
    });
    const client = await connect();
    await settle();
    await expect(client.gitDiff("uncommitted")).rejects.toThrow("The changes could not be read.");
    client.close();
  });

  test("the host's structured error reaches the changes view with its origin and fields", async () => {
    const userMessage = "The changes could not be read.";
    answer = (method) =>
      method === "git.diff"
        ? {
            ok: false,
            error: {
              code: "resource.not_found",
              userMessage,
              details: { path: "/work/a" },
              retryable: false,
              origin: "session_host",
            },
          }
        : { ok: false, error: { code: "native.not_connected", userMessage, origin: "native" } };
    const client = await connect();
    await settle();
    await expect(client.gitDiff("staged")).rejects.toMatchObject({
      name: "NativeError",
      message: userMessage,
      code: "resource.not_found",
      details: { path: "/work/a" },
      retryable: false,
      origin: "session_host",
    });
    await expect(client.gitStatus()).rejects.toMatchObject({
      name: "NativeError",
      message: userMessage,
      code: "native.not_connected",
      origin: "native",
    });
    client.close();
  });

  test("a session with no known folder rejects without asking anyone", async () => {
    folders.a = undefined;
    const client = await connect();
    await settle();
    await expect(client.gitDiff("uncommitted")).rejects.toThrow("no working folder");
    await expect(client.gitStatus()).rejects.toThrow("no working folder");
    expect(posted).toEqual([]);
    expect(gitSent()).toEqual([]);
    client.close();
  });

  test("a cloud session's folder is not read on this Mac", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a", hostKind: "cloud", cwd: "/workspace" }] };
      if (method === "_acpmux/attach")
        return {
          session: {
            sessionId: params.sessionId,
            status: "idle",
            hostKind: "cloud",
            cwd: "/workspace",
          },
          events: [],
        };
      return {};
    };
    const client = await connect();
    await settle();
    await expect(client.gitDiff("uncommitted")).rejects.toThrow("runs on another machine");
    await expect(client.gitStatus()).rejects.toThrow("runs on another machine");
    expect(posted).toEqual([]);
    expect(gitSent()).toEqual([]);
    client.close();
  });
});
