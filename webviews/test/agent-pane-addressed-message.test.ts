// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-22, on claude-sr2's chat: "this needs to be rendered better... it is now right".
// summary-panel's report, relayed by `acpmux send` from another machine, drew as the person's grey
// bubble: "summary-panel -> claude-sr2: Confirmed. …". acpmux records such a prompt with only its
// client (`acpmux-peer#…`) and its text, so the pane reads the address line: a message names this
// chat as its receiver, or a listed chat as its sender. The person's own "foo -> bar:" stays theirs.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "01a15779-206b-72b0-96af-bdbe4868e19c";
const PANEL = "01a15bd2-60bc-7ec1-96a0-06192135a35e";
const START = Date.UTC(2026, 9, 22, 4, 0, 0);
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
type Rec = ReturnType<typeof record>[number];

/// A daemon whose list holds this chat and a chat on huge-blue, and whose attach page holds the
/// whole history.
function fakeDaemon(history: Rec[]) {
  let socket: any;
  const base = { cwd: "/home/dev/x", harness: "claude", family: "claude", status: "idle", updatedAt: START };
  const session = { ...base, sessionId: CHAT, name: "claude-sr2", title: "Reply with only: OK", turnCount: 2 };
  const panel = { ...base, sessionId: PANEL, name: "huge-blue/summary-panel", peer: "huge-blue", turnCount: 9 };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session, panel] };
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

async function rowsOf(history: Rec[]): Promise<AcpmuxRow[]> {
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    fakeDaemon(history),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return rows;
}

const CONFIRMED =
  "summary-panel -> claude-sr2: Confirmed. On feat-cmux-next today, the overlay card is as tall as its content and ends 15px under its last section.";

test("another agent's addressed report, relayed from a peer as a steer, is its message card", async () => {
  const rows = await rowsOf(
    record([
      ["mux", "user_message", { text: "Check the overlay card's height", client: "cmux-next#0001", promptId: "p-1" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("Asked summary-panel.")],
      ["mux", "user_message", { text: CONFIRMED, steer: true, client: "acpmux-peer#01a161", promptId: "p-2" }],
      ["in", "agent_message_chunk", say("Confirmed by summary-panel.")],
      // To another chat, from the listed chat on huge-blue (listed as `huge-blue/summary-panel`).
      [
        "mux",
        "user_message",
        { text: "summary-panel→coord-deputy: Also #24020.", client: "acpmux-cli#01a2", promptId: "p-3" },
      ],
      // The person at the acpmux TUI: neither name is this chat or a listed one.
      ["mux", "user_message", { text: "foo -> bar: rename it", client: "acpmux-cli#01a2", promptId: "p-4" }],
      ["mux", "turn_result", { stopReason: "end_turn" }],
    ]),
  );
  const prompts = rows.filter((row) => row.kind === "user");
  expect(
    prompts.map((row) => [row.text, row.incoming?.kind === "message" ? row.incoming.message.name : undefined]),
  ).toEqual([
    ["Check the overlay card's height", undefined],
    [
      "Confirmed. On feat-cmux-next today, the overlay card is as tall as its content and ends 15px under its last section.",
      "summary-panel",
    ],
    ["Also #24020.", "summary-panel"],
    ["foo -> bar: rename it", undefined],
  ]);
  // Retry resends the message as the agent got it.
  expect(prompts[1]?.resend).toBe(CONFIRMED);
});
