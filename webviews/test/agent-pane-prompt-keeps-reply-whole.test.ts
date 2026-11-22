// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-31: "why was i able to cut my prompt in between your messages? that's s*** rendering".
// Claude Code woke on its own (a background task's notice) and wrote a reply with no acpmux turn
// open, so a prompt sent while it streamed went in as a plain prompt, not a steer. The pane ended
// the reply's row at the prompt and drew the rest of the same message as a new row below the
// bubble: "…the other" [prompt] "makes the panel follow…". One assistant message's text is one
// row: whatever comes in while it streams (a prompt or a steer) goes after it, and the next
// message, or a chunk naming none, starts below.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 9, 31, 20, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string, messageId?: string) => ({
  method: "session/update",
  params: {
    sessionId: "agent-1",
    update: {
      sessionUpdate: "agent_message_chunk",
      ...(messageId ? { messageId } : {}),
      content: { type: "text", text },
    },
  },
});
const record = (steps: Step[]) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + (index + 1) * 1000,
    dir,
    kind,
    msg,
  }));
type Rec = ReturnType<typeof record>[number];

function fakeDaemon(history: Rec[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 2,
    updatedAt: START,
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: history.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  };
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

async function rowsOf(steps: Step[]): Promise<AcpmuxRow[]> {
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    fakeDaemon(record(steps)),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return rows;
}

/// The transcript's text rows in order: `A:` an assistant row, `U:` a prompt's bubble.
const drawn = (rows: AcpmuxRow[]) =>
  rows
    .filter((row) => (row.kind === "assistant" || row.kind === "user") && row.text)
    .map((row) => `${row.kind === "assistant" ? "A" : "U"}:${row.text}`);

// What acpmux recorded for Leo's chat: the agent's own turn (no turn_started), a prompt mid-message.
const woke: Step[] = [
  ["mux", "user_message", { text: "Open the two Session Info PRs", promptId: "p-0" }],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", say("On it.", "msg-0")],
  ["mux", "turn_result", { status: "completed", stopReason: "end_turn" }],
  ["in", "agent_message_chunk", say("The two PRs are open: one moves the handle, the other ", "msg-1")],
];

test("a prompt sent while a message streams goes after the whole message", async () => {
  const rows = await rowsOf([
    ...woke,
    ["mux", "user_message", { text: "these are collapsible", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("follows the composer. ", "msg-1")],
    ["in", "agent_message_chunk", say("Both merge once checks finish.", "msg-1")],
    ["in", "agent_message_chunk", say("Folding them now.", "msg-2")],
    ["mux", "turn_result", { status: "completed", stopReason: "end_turn" }],
  ]);
  expect(drawn(rows)).toEqual([
    "U:Open the two Session Info PRs",
    "A:On it.",
    "A:The two PRs are open: one moves the handle, the other follows the composer. Both merge once checks finish.",
    "U:these are collapsible",
    "A:Folding them now.",
  ]);
  // The whole message is one row, done streaming once the turn ends.
  const reply = rows.find((row) => row.text?.startsWith("The two PRs"));
  expect(reply?.streaming).toBe(false);
});

test("a steer's text block: A, steer, B in one block is one row AB; a new block after it draws below", async () => {
  const rows = await rowsOf([
    ["mux", "user_message", { text: "Write two sentences", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("A", "msg-1")],
    ["mux", "user_message", { text: "then stop", promptId: "p-2", steer: true }],
    ["in", "agent_message_chunk", say("B", "msg-1")],
    ["in", "agent_message_chunk", say("C", "msg-2")],
    ["mux", "turn_result", { status: "completed", stopReason: "end_turn" }],
  ]);
  expect(drawn(rows)).toEqual(["U:Write two sentences", "A:AB", "U:then stop", "A:C"]);
});

test("after a cut, text that names no message starts below the prompt", async () => {
  const rows = await rowsOf([
    ...woke,
    ["mux", "user_message", { text: "these are collapsible", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Answer.")],
    ["in", "agent_message_chunk", say(" More.")],
    ["mux", "turn_result", { status: "completed", stopReason: "end_turn" }],
  ]);
  expect(drawn(rows)).toEqual([
    "U:Open the two Session Info PRs",
    "A:On it.",
    "A:The two PRs are open: one moves the handle, the other ",
    "U:these are collapsible",
    "A:Answer. More.",
  ]);
});

test("a prompt after a tool call ended the text still starts its answer below", async () => {
  const rows = await rowsOf([
    ...woke,
    [
      "in",
      "tool_call",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "tool_call", toolCallId: "t1", title: "Bash", kind: "execute", status: "pending" },
        },
      },
    ],
    ["mux", "user_message", { text: "these are collapsible", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Done.", "msg-1")],
    ["mux", "turn_result", { status: "completed", stopReason: "end_turn" }],
  ]);
  expect(drawn(rows)).toEqual([
    "U:Open the two Session Info PRs",
    "A:On it.",
    "A:The two PRs are open: one moves the handle, the other ",
    "U:these are collapsible",
    "A:Done.",
  ]);
});
