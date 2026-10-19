// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The newest message draws last (cx-jzhka): whatever order the daemon's events, steers, queued
// prompts, reconnects and history pages arrive in, the client's rows end on the newest text.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000c1";
const START = Date.UTC(2026, 9, 14, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string, messageId?: string) => ({
  method: "session/update",
  params: {
    update: {
      sessionUpdate: "agent_message_chunk",
      ...(messageId ? { messageId } : {}),
      content: { type: "text", text },
    },
  },
});
const call = (toolCallId: string, kind: "tool_call" | "tool_call_update" = "tool_call") => ({
  method: "session/update",
  params: {
    update: {
      sessionUpdate: kind,
      toolCallId,
      title: `Run ${toolCallId}`,
      kind: "execute",
      status: kind === "tool_call" ? "in_progress" : "completed",
    },
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

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events; `push` sends live ones.
function fakeDaemon(history: ReturnType<typeof record>, page = history.length) {
  let socket: any;
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
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}
const texts = (rows: AcpmuxRow[]) => rows.filter((row) => row.text).map((row) => `${row.kind}:${row.text}`);

test("a reply without message ids after a steer draws below the steer", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("working")],
    ]),
  );
  const { rows } = await connect(daemon);
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "steer", steer: true }],
        ["in", "agent_message_chunk", say("newest")],
      ],
      4,
    ),
  );
  expect(texts(rows()).at(-1)).toBe("assistant:newest");
});

test("a reply that keeps its message id after a steer still ends on the newest message once a new one starts", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("working", "m1")],
    ]),
  );
  const { rows } = await connect(daemon);
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "steer", steer: true }],
        ["in", "agent_message_chunk", say(" more", "m1")],
        ["in", "agent_message_chunk", say("newest", "m2")],
      ],
      4,
    ),
  );
  expect(texts(rows()).at(-1)).toBe("assistant:newest");
});

test("a tool call that reuses an earlier turn's id draws in the newest turn", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first" }],
      ["in", "tool_call", call("t1")],
      ["in", "tool_call_update", call("t1", "tool_call_update")],
      ["in", "agent_message_chunk", say("done one")],
      ["mux", "turn_result", { status: "completed" }],
    ]),
  );
  const { rows } = await connect(daemon);
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "second" }],
        ["in", "tool_call", call("t1")],
      ],
      6,
    ),
  );
  const calls = rows()
    .map((row) => row.items?.map((item) => `${row.kind}:${item.tool?.id}:${item.tool?.status}`))
    .filter(Boolean);
  // The first turn's call stays finished where it was; the new one draws under the new prompt.
  expect(calls).toEqual([["activity:t1:completed"], ["activity:t1:in_progress"]]);
  expect(rows().at(-1)?.kind).toBe("activity");
  expect(rows().findIndex((row) => row.text === "second")).toBe(rows().length - 2);
});

test("a queued prompt's answer draws last", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first", promptId: "p1" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("one")],
    ]),
  );
  const { rows } = await connect(daemon);
  daemon.push(
    record(
      [
        ["mux", "queued", { promptId: "p2", text: "queued" }],
        ["mux", "turn_result", { status: "completed" }],
        ["mux", "dequeued", { promptId: "p2" }],
        ["mux", "user_message", { text: "queued", promptId: "p2" }],
        ["mux", "turn_started", {}],
        ["in", "agent_message_chunk", say("newest")],
      ],
      4,
    ),
  );
  expect(texts(rows()).at(-1)).toBe("assistant:newest");
});

test("loading older history while a reply streams keeps the reply last", async () => {
  const older: Step[] = [];
  for (let turn = 0; turn < 30; turn += 1)
    older.push(
      ["mux", "user_message", { text: `q${turn}` }],
      ["in", "agent_message_chunk", say(`a${turn}`)],
      ["mux", "turn_result", { status: "completed" }],
    );
  older.push(
    ["mux", "user_message", { text: "live" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("stream")],
  );
  const daemon = fakeDaemon(record(older), 10);
  const { client, rows } = await connect(daemon);
  await client.loadOlder();
  daemon.push(record([["in", "agent_message_chunk", say("ing")]], older.length + 1));
  expect(texts(rows()).at(-1)).toBe("assistant:streaming");
});

test("a reconnect mid-stream keeps the reply last", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "first" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("half")],
    ]),
  );
  const first = await connect(daemon);
  first.client.close();
  const { rows } = await connect(daemon);
  daemon.push(record([["in", "agent_message_chunk", say(" whole")]], 4));
  expect(texts(rows()).at(-1)).toBe("assistant:half whole");
});
