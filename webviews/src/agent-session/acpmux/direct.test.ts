import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AcpmuxDirectClient, applySupersededMessage, initialSession, mergeEventRecords, permissionFromMessage, settleOptimisticPrompt } from "./direct";
import type { EventRecord } from "./direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

describe("direct acpmux event helpers", () => {
  test("uses the permission notification envelope session id", () => {
    const permission = permissionFromMessage({
      sessionId: "selected",
      permissionId: "permission-1",
      request: {
        sessionId: "agent-request-id",
        toolCall: { title: "Run command", kind: "execute" },
        options: [{ optionId: "yes", name: "Allow", kind: "allow_once" }],
      },
    }, "selected");
    expect(permission?.permissionId).toBe("permission-1");
    expect(permission?.options[0]?.id).toBe("yes");
  });

  test("removes an optimistic prompt when mux records it", () => {
    const rows = new Map<string, AcpmuxRow>([["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }]]);
    const promptRows = new Map([["p1", "local-p1"]]);
    settleOptimisticPrompt(rows, promptRows, { promptId: "p1" });
    expect(rows.has("local-p1")).toBe(false);
    expect(promptRows.has("p1")).toBe(false);
  });

  test("merges attach pages with live events without dropping either", () => {
    const event = (seq: number) => ({ seq, at: seq, sessionId: "s", dir: "mux", kind: "status", msg: { status: "ready" } });
    expect(mergeEventRecords([event(1), event(2)], [event(2), event(3)]).map((item) => item.seq)).toEqual([1, 2, 3]);
  });

  test("reconciles older user messages by text when promptId is absent", () => {
    const rows = new Map<string, AcpmuxRow>([["local-p1", { id: "local-p1", version: 1, at: 1, kind: "user", text: "hello", pending: true }]]);
    const promptRows = new Map([["p1", "local-p1"]]);
    const promptTexts = new Map([["p1", "hello"]]);
    const fallbackPromptId = [...promptTexts.entries()].find(([, value]) => value === "hello")?.[0];
    settleOptimisticPrompt(rows, promptRows, { promptId: fallbackPromptId, text: "hello" });
    expect(rows.has("local-p1")).toBe(false);
  });

  test("drops the abandoned assistant row on a superseded message", () => {
    const rows = new Map<string, AcpmuxRow>([["assistant-1", { id: "assistant-1", version: 1, at: 1, kind: "assistant", text: "partial" }]]);
    const messageRows = new Map([["old-message", "assistant-1"]]);
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
  test("a new chat attaches nothing until its first prompt", () => expect(initialSession(undefined, sessions, true)).toBeUndefined());
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
    queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
  }
  send(raw: string) {
    const request = JSON.parse(raw) as Request;
    this.sent.push(request);
    if (request.id === undefined) return;
    if (ScriptedSocket.held.has(request.method)) { this.waiting.push(request); return; }
    const result = ScriptedSocket.respond(request);
    queueMicrotask(() => this.reply(request, result));
  }
  reply(request: Request, result: unknown) { this.onmessage?.({ data: JSON.stringify({ id: request.id, result }) }); }
  release(method: string, result: unknown) {
    const index = this.waiting.findIndex((request) => request.method === method);
    if (index < 0) throw new Error(`no ${method} request is waiting`);
    const [request] = this.waiting.splice(index, 1);
    this.reply(request!, result);
  }
  /// Answers a held request with a JSON-RPC error.
  fail(method: string) {
    const index = this.waiting.findIndex((request) => request.method === method);
    if (index < 0) throw new Error(`no ${method} request is waiting`);
    const [request] = this.waiting.splice(index, 1);
    this.onmessage?.({ data: JSON.stringify({ id: request!.id, error: { message: `${method} failed` } }) });
  }
  notify(method: string, params: unknown) { this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) }); }
  close() { this.readyState = 3; }
  drop() { this.readyState = 3; this.onclose?.(); }
}

const userEvent = (sessionId: string, seq: number, text: string): EventRecord => ({ sessionId, seq, at: seq, dir: "mux", kind: "user_message", msg: { text } });
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
  const host = { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:4100/acp", token: "t", sessionId: "a" } as const;
  let snapshots: AcpmuxSnapshot[];
  const latest = () => snapshots[snapshots.length - 1]!;
  const texts = () => latest().rows.map((row) => row.text);
  /// Session "a" starts at seq 5 with a queued prompt; "b" holds one message.
  const attachReply = (sessionId: string) => sessionId === "a"
    ? { session: { sessionId: "a", status: "idle", queue: [{ promptId: "q1", prompt: "queued" }] }, events: [userEvent("a", 5, "a five"), userEvent("a", 6, "a six")] }
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
  afterEach(() => { (globalThis as any).WebSocket = realSocket; });

  const connect = () => AcpmuxDirectClient.connect(host, (snapshot) => snapshots.push(snapshot));

  test("purging an unselected session refreshes the picker", async () => {
    await connect();
    const before = snapshots.length;
    ScriptedSocket.current.notify("_acpmux/session_changed", { kind: "purged", session: { sessionId: "b" } });
    expect(snapshots.length).toBe(before + 1);
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a"]);
    ScriptedSocket.current.notify("_acpmux/session_changed", { kind: "created", session: { sessionId: "c", title: "Elsewhere" } });
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a", "c"]);
    expect(latest().sessionId).toBe("a");
  });

  test("history pages through events and keeps the live summary, queue and permission", async () => {
    const client = await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", { sessionId: "a", permissionId: "p1", request: { toolCall: { title: "Run" }, options: [] } });
    ScriptedSocket.respond = ({ method }) => method === "_acpmux/events" ? { events: [userEvent("a", 3, "a three"), userEvent("a", 4, "a four")], more: true } : {};
    await client.loadOlder();
    const methods = ScriptedSocket.current.sent.map((request) => request.method);
    expect(methods.filter((method) => method === "_acpmux/attach").length).toBe(1);
    expect(ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/events")?.params.beforeSeq).toBe(5);
    expect(texts()).toEqual(["a three", "a four", "a five", "a six"]);
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
    expect(latest().summary?.status).toBe("idle");
    expect(latest().permission?.permissionId).toBe("p1");
    expect(latest().canLoadOlder).toBe(true);
  });

  test("history stops when the daemon reports no more", async () => {
    const client = await connect();
    ScriptedSocket.respond = ({ method }) => method === "_acpmux/events" ? { events: [userEvent("a", 3, "a three")], more: false } : {};
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
    ScriptedSocket.current.release("_acpmux/events", { events: [userEvent("a", 3, "stale a three")] });
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
      client.setModel("m").then(() => "resolved", () => "rejected"),
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
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 3 });
    expect(texts()).toEqual(["a five", "a six", "still sending"]);
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "still sending"]);
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
  });

  test("a lag notice without session IDs resyncs the selected session", async () => {
    await connect();
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/events" && params.sessionId === "a" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { dropped: 2 });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven"]);
  });

  test("a lag notice for other sessions leaves the selected one alone", async () => {
    await connect();
    const sent = ScriptedSocket.current.sent.length;
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["b"], watch: false, dropped: 1 });
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
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 2 });
    await settle();
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "a eight"]);
  });

  test("lag paging continues from the page it fetched, not from live events that landed meanwhile", async () => {
    await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 9 });
    ScriptedSocket.current.notify("_acpmux/event", userEvent("a", 12, "a twelve"));
    ScriptedSocket.current.release("_acpmux/events", { events: [userEvent("a", 7, "a seven"), userEvent("a", 8, "a eight")], more: true });
    await settle();
    expect(ScriptedSocket.current.waiting.find((request) => request.method === "_acpmux/events")?.params.afterSeq).toBe(8);
    ScriptedSocket.current.release("_acpmux/events", { events: [9, 10, 11].map((seq) => userEvent("a", seq, `a ${seq}`)), more: false });
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
    ScriptedSocket.current.release("_acpmux/attach", { session: { sessionId: "b", status: "idle" }, events: [userEvent("b", 1, "b one")] });
    await selecting;
    expect(texts()).toEqual(["b one"]);
  });

  test("a watch lag refreshes the session picker", async () => {
    await connect();
    ScriptedSocket.respond = ({ method }) => method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }, { sessionId: "b" }, { sessionId: "c" }] } : { events: [] };
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: [], watch: true, dropped: 4 });
    await settle();
    expect(latest().sessions.map((session) => session.sessionId)).toEqual(["a", "b", "c"]);
  });

  test("lag recovery for a session that is no longer selected is ignored", async () => {
    const client = await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 1 });
    await client.select("b");
    ScriptedSocket.current.release("_acpmux/events", { events: [userEvent("a", 7, "stale a seven")] });
    await settle();
    client.snapshot();
    expect(texts()).toEqual(["b one"]);
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 1 });
    expect(ScriptedSocket.current.waiting.length).toBe(0);
  });

  test("selecting a session drops the previous session's queue, summary, permission and pending prompt", async () => {
    const client = await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", { sessionId: "a", permissionId: "p1", request: { toolCall: { title: "Run" }, options: [] } });
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

  test("lag recovery keeps the live summary, queue and permission", async () => {
    await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", { sessionId: "a", permissionId: "p1", request: { toolCall: { title: "Run" }, options: [] } });
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 1 });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven"]);
    expect(latest().permission?.permissionId).toBe("p1");
    expect(latest().queue).toEqual([{ id: "q1", prompt: "queued" }]);
    expect(latest().summary?.status).toBe("idle");
  });

  test("lag recovery still applies a missed permission decision and status", async () => {
    await connect();
    ScriptedSocket.current.notify("_acpmux/permission_pending", { sessionId: "a", permissionId: "p1", request: { toolCall: { title: "Run" }, options: [] } });
    ScriptedSocket.respond = ({ method }) => method === "_acpmux/events" ? { events: [{ sessionId: "a", seq: 7, at: 7, dir: "mux", kind: "permission_decision", msg: {} }, { sessionId: "a", seq: 8, at: 8, dir: "mux", kind: "status", msg: { status: "running" } }] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 2 });
    await settle();
    expect(latest().permission).toBeUndefined();
    expect(latest().summary?.status).toBe("running");
  });

  test("a failed lag fetch does not leave the pane resyncing", async () => {
    await connect();
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 1 });
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
    expect(ScriptedSocket.current.waiting.find((request) => request.method === "_acpmux/attach")?.params.sessionId).toBe("b");
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
      if (method === "_acpmux/attach") return { session: { sessionId: "a", status: "idle" }, events: [userEvent("a", 10, "a ten"), userEvent("a", 11, "a eleven")] };
      if (method === "_acpmux/events" && params.afterSeq === 6) return { events: [userEvent("a", 7, "a seven"), userEvent("a", 8, "a eight")], more: true };
      if (method === "_acpmux/events" && params.afterSeq === 8) return { events: [userEvent("a", 9, "a nine"), userEvent("a", 10, "a ten")], more: false };
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
      client.setModel("m").then(() => "resolved", () => "rejected"),
      new Promise((resolve) => setTimeout(() => resolve("pending"), 100)),
    ]);
    await settle();
    client.close();
    expect(await outcome).toBe("rejected");
  });

  const commandsEvent = (sessionId: string, seq: number, names: string[]): EventRecord => ({ sessionId, seq, at: seq, dir: "in", kind: "available_commands_update", msg: { method: "session/update", params: { update: { sessionUpdate: "available_commands_update", availableCommands: names.map((name) => ({ name, description: `${name} help` })) } } } });

  test("attach asks for the commands with the transcript and keeps them out of the rows", async () => {
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/attach" ? { ...attachReply(params.sessionId), events: [userEvent("a", 5, "a five"), commandsEvent("a", 6, ["review"])], lastSeq: 6 } : method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }] } : {};
    await connect();
    const attach = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/attach")!;
    expect(attach.params.kinds).toEqual(["transcript", "available_commands_update"]);
    expect(ScriptedSocket.current.sent.some((request) => request.method === "_acpmux/events")).toBe(false);
    expect(texts()).toEqual(["a five"]);
    expect(latest().commands).toEqual([{ name: "review", description: "review help", hint: undefined }]);
    ScriptedSocket.current.notify("session/update", { sessionId: "a", update: { sessionUpdate: "available_commands_update", availableCommands: [{ name: "compact", description: "" }] }, _meta: { acpmux: { seq: 7 } } });
    expect(latest().commands?.map((command) => command.name)).toEqual(["compact"]);
  });

  test("commands older than the attach page are fetched by kind, and a session switch drops them", async () => {
    ScriptedSocket.respond = ({ method, params }) => {
      if (method === "_acpmux/watch") return { sessions: [{ sessionId: "a" }, { sessionId: "b" }] };
      if (method === "_acpmux/attach") return { ...attachReply(params.sessionId), lastSeq: params.sessionId === "a" ? 900 : 0 };
      if (method === "_acpmux/events") return { events: [commandsEvent("a", 2, ["init", "review"])] };
      return {};
    };
    const client = await connect();
    await settle();
    const fetch = ScriptedSocket.current.sent.find((request) => request.method === "_acpmux/events")!;
    expect(fetch.params).toEqual({ sessionId: "a", beforeSeq: 901, limit: 1, kinds: ["available_commands_update"] });
    expect(latest().commands?.map((command) => command.name)).toEqual(["init", "review"]);
    await client.select("b");
    expect(latest().commands).toEqual([]);
  });

  test("a live update that lands while the fetch is in flight wins, even when it empties the list", async () => {
    ScriptedSocket.held.add("_acpmux/events");
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/attach" ? { ...attachReply(params.sessionId), lastSeq: 900 } : method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }] } : {};
    await connect();
    await settle();
    ScriptedSocket.current.notify("session/update", { sessionId: "a", update: { sessionUpdate: "available_commands_update", availableCommands: [] }, _meta: { acpmux: { seq: 901 } } });
    ScriptedSocket.current.release("_acpmux/events", { events: [commandsEvent("a", 2, ["init"])] });
    await settle();
    expect(latest().commands).toEqual([]);
  });

  test("a prompt with attachments sends the text, its text files and then its images, and shows the text it recorded", async () => {
    const client = await connect();
    await client.send("Compare", [
      { id: "i", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBORw==" },
      { id: "t", kind: "text", name: "a.txt", mimeType: "text/plain", size: 1, text: "x" },
    ]);
    const prompt = ScriptedSocket.current.sent.find((request) => request.method === "session/prompt")!;
    expect(prompt.params.prompt).toEqual([{ type: "text", text: "Compare\n\na.txt\n```txt\nx\n```" }, { type: "image", mimeType: "image/png", data: "iVBORw==" }]);
    expect(texts().at(-1)).toBe("Compare\n\na.txt\n```txt\nx\n```");
  });

  test("steering an agent that reports it sends a steer prompt without stopping the turn", async () => {
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/attach" ? { ...attachReply(params.sessionId), session: { sessionId: "a", status: "running", steering: true } } : method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }] } : {};
    const client = await connect();
    expect(latest().summary?.steering).toBe(true);
    await client.steer("use v2");
    const sent = ScriptedSocket.current.sent.filter((request) => request.method === "session/cancel" || request.method === "session/prompt");
    expect(sent.map((request) => request.method)).toEqual(["session/prompt"]);
    expect(sent[0]!.params._meta.acpmux).toEqual({ promptId: expect.any(String), steer: true });
  });

  test("steering any other agent stops the turn first, so the prompt runs next instead of waiting in the queue", async () => {
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/attach" ? { ...attachReply(params.sessionId), session: { sessionId: "a", status: "running" } } : method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }] } : {};
    const client = await connect();
    await client.steer("use v2");
    const sent = ScriptedSocket.current.sent.filter((request) => request.method === "session/cancel" || request.method === "session/prompt");
    expect(sent.map((request) => request.method)).toEqual(["session/cancel", "session/prompt"]);
    expect(sent[1]!.params._meta.acpmux.steer).toBeUndefined();
  });

  test("the agent's prompt capabilities reach the snapshot", async () => {
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/attach" ? { ...attachReply(params.sessionId), session: { sessionId: "a", agentCapabilities: { promptCapabilities: { image: false } } } } : method === "_acpmux/watch" ? { sessions: [{ sessionId: "a" }] } : {};
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
    ScriptedSocket.respond = ({ method, params }) => method === "_acpmux/events" && params.afterSeq === 6 ? { events: [userEvent("a", 7, "a seven")] } : {};
    ScriptedSocket.current.notify("_acpmux/lagged", { sessionIds: ["a"], watch: false, dropped: 1 });
    await settle();
    expect(texts()).toEqual(["a five", "a six", "a seven", "did not send"]);
    expect(latest().rows.find((row) => row.text === "did not send")?.failed).toBe(true);
  });
});
