// l10n-allow-file: test fixture versions, models and paths, not shipped UI.
// Where a Claude Code chat's session started, the pane says what it runs on and how it compacts.
// Before, acpmux forwarded Claude Code's init (`session_info_update._meta.claude`: version and
// model) and the pane dropped it: a chat opened with no word of its Claude Code version, model,
// route or folder, while the Claude Code TUI opens with all of them in its banner.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
function fakeDaemon(history: ReturnType<typeof record>, harness = "claude-sr2", page = history.length) {
  let socket: any;
  const session = {
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

test("a Claude Code chat notes its version, model, route and folder once, where it started", async () => {
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
  const { rows } = await connect(daemon);
  const starts = () => rows().filter((row) => row.kind === "sessionStart");
  expect(starts().map((row) => row.sessionStart)).toEqual([
    {
      agent: "claude",
      version: "2.1.303",
      model: "claude-opus-5-5",
      harness: "claude-sr2",
      cwd: "/Users/dev/fun/cmux",
    },
  ]);
  const first = starts()[0]!;
  // Its place is the session's start: before the reply.
  const order = rows().map((row) => row.kind);
  expect(order.indexOf("sessionStart")).toBeLessThan(order.indexOf("assistant"));

  // Claude Code sends the same init on every turn: still one row, unchanged.
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
  expect(starts().map((row) => [row.id, row.version])).toEqual([[first.id, first.version]]);

  // A restart on a new version updates the same row in place.
  daemon.push(record([["in", "session_info_update", init("2.1.304", "claude-opus-5-5")]], 8));
  expect(starts().map((row) => [row.id, row.sessionStart?.version])).toEqual([[first.id, "2.1.304"]]);
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
  const { rows, summary } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "sessionStart")
      .map((row) => row.sessionStart?.version),
  ).toEqual(["2.1.305"]);
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
