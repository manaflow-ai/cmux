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

const base = { cwd: "/home/dev/x", harness: "claude", family: "claude", status: "idle", updatedAt: START };
const PANEL_ENTRY = { ...base, sessionId: PANEL, name: "huge-blue/summary-panel", peer: "huge-blue", turnCount: 9 };

/// A daemon whose list holds this chat and `listed`, and whose attach page holds the whole history.
/// `socket()` is the open connection, for a notification.
function fakeDaemon(history: Rec[], listed: object[] = [PANEL_ENTRY], chat: object = {}) {
  let socket: any;
  const session = { ...base, sessionId: CHAT, name: "claude-sr2", title: "Reply with only: OK", turnCount: 2, ...chat };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session, ...listed] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: history.at(-1)?.seq ?? 0 };
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
  return Object.assign(open, { socket: () => socket });
}

async function rowsOf(history: Rec[], daemon = fakeDaemon(history)): Promise<AcpmuxRow[]> {
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon,
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

test("a sender listed after its addressed prompt was read makes that prompt its message", async () => {
  const history = record([
    [
      "mux",
      "user_message",
      { text: "summary-panel -> coord-deputy: Also #24020.", client: "acpmux-peer#01a1", promptId: "p-1" },
    ],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Noted.")],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ]);
  // Addressed to another chat, from a chat the list does not hold yet: the person's, for now.
  const daemon = fakeDaemon(history, []);
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon,
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  const prompt = () => rows.find((row) => row.kind === "user");
  expect(prompt()?.incoming).toBeUndefined();
  // The chat on huge-blue is listed: the prompt is its message.
  daemon.socket().onmessage?.({
    data: JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { sessionId: PANEL, session: PANEL_ENTRY, kind: "created" },
    }),
  });
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(prompt()?.incoming).toMatchObject({
    kind: "message",
    message: { name: "summary-panel", text: "Also #24020." },
  });
});

const QUEUED = "summary-panel -> coord-deputy: Also #24020.";

/// The queue a chat shows after the list names summary-panel, its prompt `p-2` queued as `QUEUED`
/// by a peer and then changed by `edits` (`queue_updated` texts).
async function queueAfterListing(edits: string[]) {
  const text = QUEUED;
  const history = record([
    ["mux", "user_message", { text: "Check the overlay", client: "cmux-next#0001", promptId: "p-1", turnId: "t-1" }],
    ["mux", "turn_started", { promptId: "p-1", turnId: "t-1" }],
    ["mux", "queued", { text, promptId: "p-2", client: "acpmux-peer#01a1", position: 1 }],
    ...edits.map((edit): Step => ["mux", "queue_updated", { text: edit, promptId: "p-2" }]),
  ]);
  const queue = [{ promptId: "p-2", prompt: edits.at(-1) ?? text, turnId: "t-2", queuedAt: START, held: false }];
  const daemon = fakeDaemon(history, [], { status: "running", steering: true, queue });
  let shown: any[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (shown = snapshot.queue),
    undefined,
    daemon,
  );
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(shown.map((entry) => [entry.id, entry.message])).toEqual([["p-2", undefined]]);
  daemon.socket().onmessage?.({
    data: JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { sessionId: PANEL, session: PANEL_ENTRY, kind: "created" },
    }),
  });
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return shown.map((entry) => [entry.id, entry.prompt, entry.message?.name, entry.message?.text]);
}

test("a queued addressed prompt reads as its sender's once the sender is listed", async () => {
  expect(await queueAfterListing([])).toEqual([["p-2", QUEUED, "summary-panel", "Also #24020."]]);
});

test("a queued addressed prompt the person edited stays theirs, even edited back", async () => {
  expect(await queueAfterListing(["Also #24021."])).toEqual([["p-2", "Also #24021.", undefined, undefined]]);
  expect(await queueAfterListing(["Also #24021.", QUEUED])).toEqual([["p-2", QUEUED, undefined, undefined]]);
  expect(await queueAfterListing([QUEUED])).toEqual([["p-2", QUEUED, undefined, undefined]]);
});
