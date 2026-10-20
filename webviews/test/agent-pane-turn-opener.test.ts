// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Lawrence 2026-10-19: "When I start the acpmux agent I don't see a user prompt." A Chief subagent's
// first prompt carries the Chief's whole view (often 100+ KB), and the open page is capped at
// 128 KB newest-first: once the turn's own output passes that, the page starts mid-turn and the
// prompt that opened it is never drawn. The pane must show the open turn's prompt anyway, without
// skipping the history between it and the page, and say when the Chief sent it.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000c3";
const START = Date.UTC(2026, 9, 19, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const call = (toolCallId: string) => ({
  method: "session/update",
  params: {
    update: { sessionUpdate: "tool_call", toolCallId, title: `Run ${toolCallId}`, kind: "execute", status: "completed" },
  },
});
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Rec = ReturnType<typeof record>[number];

/// A daemon whose attach page holds only the newest `page` records (as acpmux's maxBytes cap
/// does), answering `_acpmux/events` like acpmux: beforeSeq pages backwards, newest `limit` first.
function fakeDaemon(history: Rec[], page: number) {
  let socket: any;
  const requests: { method: string; params: any }[] = [];
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  };
  const matches = (kinds: unknown, event: Rec) =>
    !Array.isArray(kinds) || kinds.includes("transcript") || kinds.includes(event.kind);
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return {
          session,
          lastSeq: history.at(-1)?.seq ?? 0,
          events: history.slice(-page),
          hasMore: history.length > page,
        };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const limit = params?.limit ?? 5000;
        const all = history.filter((event) => event.seq < before && matches(params?.kinds, event));
        const events = all.slice(-limit);
        return { events, hasMore: all.length > events.length, lastSeq: history.at(-1)?.seq ?? 0 };
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
        if (message.id === undefined) return;
        requests.push({ method: message.method, params: message.params });
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, requests };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}
const users = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "user");

/// A Chief subagent's chat: the Chief's task, then a long turn of tool calls.
function longTurn(prompt: Record<string, unknown>, calls = 30): Rec[] {
  const steps: Step[] = [
    ["mux", "user_message", prompt],
    ["mux", "turn_started", {}],
  ];
  for (let i = 0; i < calls; i++) steps.push(["in", "tool_call", call(`c${i}`)]);
  steps.push(["in", "agent_message_chunk", say("still working")]);
  return record(steps);
}
const chiefTask = {
  text: "<chat>\n0+1|user: hi\n</chat>Your task:\n\nFix the prompt bubble",
  client: "optchat-chief#01a156",
  promptId: "optchat-sub:a142:1792456541519",
};

test("a chat whose open turn outgrew the open page still shows the prompt that started it", async () => {
  const daemon = fakeDaemon(longTurn(chiefTask), 10);
  const { rows } = await connect(daemon);
  const shown = users(rows());
  expect(shown.map((row) => row.text)).toEqual([chiefTask.text]);
  // It draws above the turn's output, as the first row.
  expect(rows()[0]?.kind).toBe("user");
});

test("the Chief's prompt says it came from the Chief; a typed one does not", async () => {
  const chief = await connect(fakeDaemon(longTurn(chiefTask), 10));
  expect(users(chief.rows())[0]?.from).toBe("chief");

  const typed = await connect(
    fakeDaemon(longTurn({ text: "typed here", client: "cmux-next#0001", promptId: "p-1" }, 2), 100),
  );
  expect(users(typed.rows())[0]?.text).toBe("typed here");
  expect(users(typed.rows())[0]?.from).toBeUndefined();
});

test("a Chief follow-up (tell, restart message) also shows as from the Chief", async () => {
  const history = record([
    ["mux", "user_message", chiefTask],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("done")],
    ["mux", "turn_result", { stopReason: "end_turn" }],
    ["mux", "user_message", { text: "one more thing", client: "optchat-chief#01a156", promptId: "optchat-tell:a142:2" }],
    ["mux", "turn_started", {}],
  ]);
  const { rows } = await connect(fakeDaemon(history, 100));
  expect(users(rows()).map((row) => [row.text, row.from])).toEqual([
    [chiefTask.text, "chief"],
    ["one more thing", "chief"],
  ]);
});

test("the opener is the turn's prompt, not a steer sent into it", async () => {
  const history = longTurn(chiefTask, 10);
  history.splice(
    5,
    0,
    ...record([["mux", "user_message", { text: "steer in", steer: true, client: "cmux-next#0001" }]], 6),
  );
  history.forEach((event, index) => (event.seq = index + 1));
  const { rows } = await connect(fakeDaemon(history, 4));
  expect(users(rows())[0]?.text).toBe(chiefTask.text);
});

test("loading older history after the opener keeps the records between and draws the prompt once", async () => {
  const daemon = fakeDaemon(longTurn(chiefTask), 10);
  const { client, rows } = await connect(daemon);
  await client.loadOlder();
  for (let i = 0; i < 3; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  // The older page continues from the open page, not from the opener.
  const older = daemon.requests.filter(
    (request) => request.method === "_acpmux/events" && request.params?.kinds?.includes("transcript"),
  );
  expect(older[0]?.params.beforeSeq).toBeGreaterThan(2);
  expect(users(rows()).map((row) => row.text)).toEqual([chiefTask.text]);
  // Every tool call of the turn is there once the history is in.
  const toolIds = rows().flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])));
  expect(new Set(toolIds).size).toBe(30);
});
