// l10n-allow-file: test fixture versions, models and paths, not shipped UI.
// What a Claude Code chat runs on (its init line, `session_info_update._meta.claude`: version and
// model, on every turn) is in the chat's summary, for Session Info and /status. The transcript
// draws it only where it tells the reader something: a turn whose model or route changed from the
// turn before, or a first turn not on the chat's own model. Before, every chat opened on a
// "Claude Code · Opus 5.5" line over its reply (Leo, 2026-11-05: "why does it even show that ...
// like we know what it is ... giving tmi").
import { expect, test } from "bun:test";
import { insertRunChange, type RunChange } from "../src/agent-session/acpmux/conversation/sessionStart";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSessionStart } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d8";
const START = Date.UTC(2026, 9, 18, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events; `push` sends live ones.
function fakeDaemon(
  history: ReturnType<typeof record>,
  harness = "claude-sr2",
  page = history.length,
  detail: Record<string, unknown> = {},
) {
  let socket: any;
  const session = {
    ...detail,
    sessionId: CHAT,
    cwd: "/Users/dev/fun/cmux",
    title: "x",
    harness,
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history.slice(-page) };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const events = history.filter((event) => event.seq > after && event.seq < before);
        return { events, hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params),
              }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }),
      });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  let summary: any;
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => {
      rows = snapshot.rows;
      summary = snapshot.summary;
    },
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows, summary: () => summary };
}

const init = (version: string, model: string) =>
  update({
    sessionUpdate: "session_info_update",
    title: null,
    _meta: { claude: { tools: [], mcp_servers: [], plugins: [], skills: [], model, version } },
  });

test("a chat on one model draws no start line; its facts are in the summary, the latest version too", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["mux", "turn_started", {}],
      ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
      [
        "in",
        "agent_message_chunk",
        update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hi" } }),
      ],
    ]),
  );
  const { rows, summary } = await connect(daemon);
  const starts = () => rows().filter((row) => row.kind === "sessionStart");
  expect(starts()).toEqual([]);
  expect(summary()?.sessionStart).toEqual({
    agent: "claude",
    version: "2.1.303",
    model: "claude-opus-5-5",
    harness: "claude-sr2",
    cwd: "/Users/dev/fun/cmux",
  });

  // Claude Code sends the same init on every turn: still no line.
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "again" }],
        ["mux", "turn_started", {}],
        ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
      ],
      5,
    ),
  );
  expect(starts()).toEqual([]);

  // A restart on a new version is no change of model or route: the summary says the new version.
  daemon.push(record([["in", "session_info_update", init("2.1.304", "claude-opus-5-5")]], 8));
  expect(starts()).toEqual([]);
  expect(summary()?.sessionStart?.version).toBe("2.1.304");
});

test("a turn on another model draws one line where it changed, and the switch back draws another", async () => {
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
      ["in", "agent_message_chunk", say("on opus")],
      ["mux", "turn_end", {}],
      ["mux", "user_message", { text: "now sonnet" }],
      ["in", "session_info_update", init("2.1.303", "claude-sonnet-5-5")],
      ["in", "agent_message_chunk", say("on sonnet")],
      ["mux", "turn_end", {}],
      ["mux", "user_message", { text: "still sonnet" }],
      ["in", "session_info_update", init("2.1.303", "claude-sonnet-5-5")],
      ["in", "agent_message_chunk", say("still sonnet")],
    ]),
  );
  const { rows, summary } = await connect(daemon);
  const starts = () => rows().filter((row) => row.kind === "sessionStart");
  expect(starts().map((row) => [row.seq, row.sessionStart?.model])).toEqual([[6, "claude-sonnet-5-5"]]);
  // Its place is the turn that changed: after the prompt that asked for it, before the reply.
  const order = rows().map((row) => (row.kind === "sessionStart" ? "start" : row.text));
  expect(order.indexOf("start")).toBeGreaterThan(order.indexOf("now sonnet"));
  expect(order.indexOf("start")).toBeLessThan(order.indexOf("on sonnet"));
  expect(summary()?.sessionStart?.model).toBe("claude-sonnet-5-5");

  daemon.push(record([["in", "session_info_update", init("2.1.303", "claude-opus-5-5")]], 12));
  expect(starts().map((row) => [row.seq, row.sessionStart?.model])).toEqual([
    [6, "claude-sonnet-5-5"],
    [12, "claude-opus-5-5"],
  ]);
});

test("a first turn not on the chat's own model says so", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", init("2.1.303", "claude-haiku-5-5")],
    ]),
    "claude-sr2",
    undefined,
    { model: "claude-opus-5-5[1m]" },
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "sessionStart")
      .map((row) => row.sessionStart?.model),
  ).toEqual(["claude-haiku-5-5"]);

  // The chat's own model, its 1M window left out, draws nothing.
  const same = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
    ]),
    "claude-sr2",
    undefined,
    { model: "claude-opus-5-5[1m]" },
  );
  const quiet = await connect(same);
  expect(quiet.rows().filter((row) => row.kind === "sessionStart")).toEqual([]);
});

test("change points stay right when an older page's init lines land after newer ones", () => {
  const facts = (model: string, version = "2.1.303"): AcpmuxSessionStart => ({
    agent: "claude",
    version,
    model,
    harness: "claude-sr2",
  });
  const changes: RunChange[] = [];
  const add = (seq: number, model: string, version?: string) =>
    insertRunChange(changes, { seq, at: seq, start: facts(model, version) });
  const points = () => changes.map((change) => [change.seq, change.start.model]);
  // The newest page first: sonnet at 40 and 50.
  add(40, "claude-sonnet-5-5");
  expect(add(50, "claude-sonnet-5-5")).toBe(false);
  expect(points()).toEqual([[40, "claude-sonnet-5-5"]]);
  // The older page: opus at 10 and 20, then sonnet at 30, which makes 40 no change any more.
  add(10, "claude-opus-5-5");
  add(20, "claude-opus-5-5");
  expect(points()).toEqual([
    [10, "claude-opus-5-5"],
    [40, "claude-sonnet-5-5"],
  ]);
  add(30, "claude-sonnet-5-5");
  expect(points()).toEqual([
    [10, "claude-opus-5-5"],
    [30, "claude-sonnet-5-5"],
  ]);
  // A newer version on the same run is no change point; what the chat runs on now is the client's
  // newest line (below).
  expect(add(60, "claude-sonnet-5-5", "2.1.304")).toBe(false);
  expect(points()).toEqual([
    [10, "claude-opus-5-5"],
    [30, "claude-sonnet-5-5"],
  ]);
});

test("an older page landing late never takes the summary back to an older version", async () => {
  // The attach holds only the newest event; the rest come as an older page.
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
      ["mux", "user_message", { text: "again" }],
      ["in", "session_info_update", init("2.1.312", "claude-opus-5-5")],
    ]),
    "claude-sr2",
    1,
  );
  const { client, rows, summary } = await connect(daemon);
  expect(summary()?.sessionStart?.version).toBe("2.1.312");
  // The page lands, and its snapshot is out, before `loadOlder` resolves.
  await client.loadOlder();
  expect(rows().some((row) => row.kind === "user")).toBe(true);
  expect(summary()?.sessionStart?.version).toBe("2.1.312");
});

test("an older page that moves a change point back leaves one line, at the earlier turn", async () => {
  // The chat's own model is Opus; both turns ran on Sonnet. The first page holds only the second
  // turn, whose line moves to the first turn once the older page shows Sonnet began there.
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", init("2.1.303", "claude-sonnet-5-5")],
      ["mux", "user_message", { text: "again" }],
      ["in", "session_info_update", init("2.1.303", "claude-sonnet-5-5")],
    ]),
    "claude-sr2",
    2,
    { model: "claude-opus-5-5" },
  );
  const { client, rows } = await connect(daemon);
  const lines = () =>
    rows()
      .filter((row) => row.kind === "sessionStart")
      .map((row) => row.seq);
  expect(lines()).toEqual([4]);
  // The page lands, and its snapshot is out, before `loadOlder` resolves.
  await client.loadOlder();
  expect(lines()).toEqual([2]);
});

test("a replay seeking back draws the change lines up to that point, and none after", () => {
  const steps = record([
    ["mux", "user_message", { text: "hello" }],
    ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
    ["mux", "user_message", { text: "sonnet" }],
    ["in", "session_info_update", init("2.1.303", "claude-sonnet-5-5")],
    ["mux", "user_message", { text: "opus" }],
    ["in", "session_info_update", init("2.1.303", "claude-opus-5-5")],
  ]);
  let rows: AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay(CHAT, steps as any, (snapshot: any) => {
    rows = snapshot.rows;
  });
  const lines = () =>
    rows.filter((row) => row.kind === "sessionStart").map((row) => [row.seq, row.sessionStart?.model]);
  client.seekReplay(6);
  client.seekReplay(Number.MAX_SAFE_INTEGER);
  expect(lines()).toEqual([
    [4, "claude-sonnet-5-5"],
    [6, "claude-opus-5-5"],
  ]);
  client.seekReplay(5);
  expect(lines()).toEqual([[4, "claude-sonnet-5-5"]]);
  client.seekReplay(6);
  expect(lines()).toEqual([
    [4, "claude-sonnet-5-5"],
    [6, "claude-opus-5-5"],
  ]);
});

test("an init without Claude Code's facts (Codex's info update) draws nothing", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", update({ sessionUpdate: "session_info_update", title: "Fix the build" })],
      [
        "in",
        "session_info_update",
        update({ sessionUpdate: "session_info_update", _meta: { codex: { error: null } } }),
      ],
    ]),
    "codex",
  );
  const { rows } = await connect(daemon);
  expect(rows().filter((row) => row.kind === "sessionStart")).toEqual([]);
});

test("an info update with the context breakdown and Claude Code's facts keeps both", async () => {
  const breakdown = {
    categories: [{ name: "Messages", tokens: 10, kind: "used" }],
    memoryFiles: [],
    mcpTools: [],
    totalTokens: 10,
    maxTokens: 100,
  };
  const both = update({
    sessionUpdate: "session_info_update",
    title: null,
    _meta: {
      claude: { tools: [], mcp_servers: [], plugins: [], skills: [], model: "claude-opus-5-5", version: "2.1.305" },
      acpmux: { contextBreakdown: breakdown },
    },
  });
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      ["in", "session_info_update", both],
    ]),
  );
  const { summary } = await connect(daemon);
  expect(summary()?.sessionStart?.version).toBe("2.1.305");
  expect(summary()?.contextBreakdown).toEqual(breakdown);
});

test("a failover drops the last harness's context breakdown", async () => {
  const breakdown = {
    categories: [{ name: "Messages", tokens: 10, kind: "used" }],
    memoryFiles: [],
    mcpTools: [],
    totalTokens: 10,
    maxTokens: 100,
  };
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "hello" }],
      [
        "in",
        "session_info_update",
        update({ sessionUpdate: "session_info_update", _meta: { acpmux: { contextBreakdown: breakdown } } }),
      ],
      ["mux", "failover", { from: "claude", to: "codex" }],
    ]),
  );
  const { summary } = await connect(daemon);
  expect(summary()?.contextBreakdown).toBeUndefined();
});

test("the session detail's usage limits reach the summary, and malformed ones read as unreported", async () => {
  const usageLimits = {
    windows: [
      { id: "session", usedPercent: 38, resetsAt: 1_793_570_400 },
      { id: "weekly", usedPercent: 12.5 },
    ],
  };
  const history = () => record([["mux", "user_message", { text: "hello" }]]);
  const reported = await connect(fakeDaemon(history(), "claude-sr2", 1, { usageLimits }));
  expect(reported.summary()?.usageLimits).toEqual(usageLimits);

  // A window without an id or a finite percent is dropped; none left is no report at all.
  const mixed = { windows: [{ id: "weekly", usedPercent: 40 }, { usedPercent: 5 }, { id: "x", usedPercent: "1" }] };
  const kept = await connect(fakeDaemon(history(), "claude-sr2", 1, { usageLimits: mixed }));
  expect(kept.summary()?.usageLimits).toEqual({ windows: [{ id: "weekly", usedPercent: 40 }] });
  for (const malformed of [{ windows: "weekly" }, { windows: [{ id: "session" }] }, null, 42]) {
    const dropped = await connect(fakeDaemon(history(), "claude-sr2", 1, { usageLimits: malformed }));
    expect(dropped.summary()?.usageLimits).toBeUndefined();
  }
  // A harness that reports its limits as text keeps them.
  const plain = await connect(fakeDaemon(history(), "claude-sr2", 1, { usageLimits: "Weekly: 62% remaining" }));
  expect(plain.summary()?.usageLimits).toBe("Weekly: 62% remaining");
});
