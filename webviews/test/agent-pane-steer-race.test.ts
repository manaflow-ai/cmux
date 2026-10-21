// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A steer that lands as the turn ends (claude-sr2, 2026-10-20). acpmux records the steer when it
// is sent; the agent then says it has no turn to steer, and acpmux runs the same prompt (same
// promptId) as the next turn, recording it again. The agent got it once, so the chat shows it once:
// as the prompt of the turn it started, not also as a steer of the turn before.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d4";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const record = (steps: Step[]) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));

/// A daemon whose attach page holds the whole history.
function fakeDaemon(history: ReturnType<typeof record>) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: true,
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

async function rowsOf(history: ReturnType<typeof record>) {
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    fakeDaemon(history),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return rows.filter((row) => row.kind === "user");
}

const message = { text: "from coord: check CI", client: "acpmux-cli#01", promptId: "p-msg" };

test("a steer that lands as the turn ends shows once, as the next turn's prompt", async () => {
  const users = await rowsOf(
    record([
      ["mux", "user_message", { text: "Refactor the parser", promptId: "p-turn", turnId: "turn-1" }],
      ["mux", "turn_started", { promptId: "p-turn", turnId: "turn-1" }],
      ["in", "agent_message_chunk", say("Done.")],
      ["mux", "user_message", { ...message, steer: true, turnId: "turn-1" }],
      ["mux", "turn_end", { turnId: "turn-1" }],
      ["mux", "turn_result", { stopReason: "end_turn", turnId: "turn-1" }],
      ["mux", "user_message", { ...message, turnId: "turn-2" }],
      ["mux", "turn_started", { promptId: "p-msg", turnId: "turn-2" }],
    ]),
  );
  expect(users.map((row) => [row.text, row.steer])).toEqual([
    ["Refactor the parser", undefined],
    [message.text, undefined],
  ]);
});

test("a steer the agent read keeps its row; a later prompt with its own id adds one", async () => {
  const users = await rowsOf(
    record([
      ["mux", "user_message", { text: "Refactor the parser", promptId: "p-turn", turnId: "turn-1" }],
      ["mux", "turn_started", { promptId: "p-turn", turnId: "turn-1" }],
      ["mux", "user_message", { ...message, steer: true, turnId: "turn-1" }],
      ["in", "agent_message_chunk", say("Checking CI.")],
      ["mux", "turn_result", { stopReason: "end_turn", turnId: "turn-1" }],
      ["mux", "user_message", { text: "from coord: check CI", promptId: "p-next", turnId: "turn-2" }],
      ["mux", "turn_started", { promptId: "p-next", turnId: "turn-2" }],
    ]),
  );
  expect(users.map((row) => row.text)).toEqual(["Refactor the parser", message.text, message.text]);
});
