// A long mock chat opens on its newest page and pages back to its first message, as a chat on
// acpmux does (perf100 chat-load). The in-page mock daemon (CMUX_NEXT_AGENT_PANE_MOCK=1, the
// showcase, debug load_seed) answered an attach with the chat's whole log, so a 10,000-turn mock
// chat drew every turn up front (50 s to first paint, 1.6 GB of heap). The real client, the mock
// daemon's socket: the open holds one page, and the older pages bring every turn once, in order.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Snapshot = { sessionId?: string; rows: { kind: string; text?: string }[]; canLoadOlder: boolean };

test("a long mock chat opens on its newest page and pages back to its first message", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const TURNS = 1200;
  let snapshot: Snapshot | undefined;
  let snapshots = 0;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => {
      snapshots += 1;
      snapshot = next as unknown as Snapshot;
    },
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    const session = MockAcpmuxSocket.live!.seedLoadSession(TURNS);
    await client.select(session);
    const prompts = () => (snapshot?.rows ?? []).filter((row) => row.kind === "user").map((row) => row.text ?? "");
    expect(snapshot?.sessionId).toBe(session);
    // The open holds the newest page only, and ends on the newest turn.
    const opened = prompts();
    expect(opened.length).toBeGreaterThan(0);
    expect(opened.length).toBeLessThan(TURNS / 4);
    expect(opened.at(-1)).toStartWith(`Turn ${TURNS - 1}:`);
    expect(snapshot?.canLoadOlder).toBe(true);
    // Older pages, as the reader scrolls up, until the first message.
    for (let pages = 0; snapshot?.canLoadOlder && pages < TURNS; pages += 1) await client.loadOlder();
    expect(snapshot?.canLoadOlder).toBe(false);
    // Older pages are published in bounded batches; publishing once per page makes the
    // composer/session rail re-render while a long transcript is being prepended.
    expect(snapshots).toBeLessThan(25);
    const all = prompts();
    expect(all.length).toBe(TURNS);
    all.forEach((text, turn) => expect(text).toStartWith(`Turn ${turn}:`));
  } finally {
    client.close();
  }
});

test("learning a native chat thread seeds the live subagent fold even when unnamed", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  let seeded: string | undefined;
  const client = Object.create(AcpmuxDirectClient.prototype) as any;
  client.summary = { agentSessionId: "native-root" };
  client.sessions = [];
  client.selectedSessionId = "chat";
  client.subagents = {
    chat: undefined,
    deferredRun: false,
    harness: undefined,
    names: () => false,
    setRoot: (id: string) => {
      seeded = id;
    },
    // Nothing to publish: the seed repaired no rows.
    takeRows: () => [],
  };
  client.learnChatThread();
  expect(seeded).toBe("native-root");
});

test("learning an unnamed native chat thread publishes the fold rows it repairs", async () => {
  const { AcpmuxDirectClient, OrderedRows } = await import("./direct");
  const { SubagentFold } = await import("./subagents/subagentFold");
  const client = Object.create(AcpmuxDirectClient.prototype) as any;
  const fold = new SubagentFold();
  client.summary = { agentSessionId: "native-root" };
  client.sessions = [];
  client.selectedSessionId = "chat";
  client.subagents = fold;
  client.rows = new OrderedRows();
  client.streamingAssistant = undefined;
  client.streamingAssistantMessageId = undefined;

  const replay = (seq: number, update: any, acpmux: Record<string, unknown>) => {
    const withCodex = {
      ...update,
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "native-root" } } },
    };
    fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update: withCodex, _meta: { acpmux } } } },
      withCodex,
    );
  };
  replay(1, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "stale", parent: null }] });
  replay(2, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "child", parent: "stale" }] });
  client.takeSubagentRows();
  expect(
    client.rows
      .sorted()
      .flatMap((row: any) => row.subagents ?? [])
      .map((agent: any) => agent.id),
  ).toEqual(["stale"]);

  client.learnChatThread();

  expect(
    client.rows
      .sorted()
      .flatMap((row: any) => row.subagents ?? [])
      .map((agent: any) => agent.id),
  ).toEqual(["stale", "child"]);
  expect(fold.takeRows()).toEqual([]);
});

test("late root promotion keeps a worker before a later subagent batch", async () => {
  const { AcpmuxDirectClient, OrderedRows } = await import("./direct");
  const { SubagentFold } = await import("./subagents/subagentFold");
  const client = Object.create(AcpmuxDirectClient.prototype) as any;
  const fold = new SubagentFold();
  client.rows = new OrderedRows();
  client.subagents = fold;
  client.streamingAssistant = undefined;
  client.streamingAssistantMessageId = undefined;

  const replay = (seq: number, acpmux: Record<string, unknown>) => {
    const update = {
      sessionUpdate: "subagent_spawned",
      _meta: { codex: { collaboration: { tool: "spawnAgent", senderThreadId: "native-root" } } },
    };
    fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
      update,
    );
    client.takeSubagentRows();
  };
  replay(1, { subagents: [{ id: "stale", parent: null }] });
  replay(2, { subagents: [{ id: "child", parent: "stale" }] });
  fold.closeBatch();
  replay(3, { subagents: [{ id: "later", parent: null }] });
  expect(
    client.rows
      .sorted()
      .flatMap((row: any) => row.subagents ?? [])
      .map((agent: any) => agent.id),
  ).toEqual(["stale", "later"]);

  fold.setRoot("native-root");
  client.takeSubagentRows();

  expect(
    client.rows
      .sorted()
      .flatMap((row: any) => row.subagents ?? [])
      .map((agent: any) => agent.id),
  ).toEqual(["stale", "child", "later"]);
});
