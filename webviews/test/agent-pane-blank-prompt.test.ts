// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-21 (a live chat on a remote host): prompts drew as EMPTY grey bubbles. A prompt row
// whose text has nothing to read must never become a bubble. The shapes a `user_message` can take
// with no text: a blank or whitespace-only text, a steer that carried none, and a record acpmux
// left out of a page for its size (paging.rs `fit`: the record keeps its kind and seq, and its msg
// is only `_meta.acpmux.omitted`). Each draws nothing (`incoming: hidden`) and still starts its
// turn, so the reply under it stays its own turn. A prompt of images alone keeps its row: its
// images are what it says. The prompts around them keep their text.
//
// Before: each blank record made a `user` row with text "" and no `incoming`, which App.tsx draws
// as UserBubble's glass bubble with nothing in it.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d1";
const START = Date.UTC(2026, 9, 21, 22, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
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

/// A daemon whose attach page holds the whole history.
function fakeDaemon(history: Rec[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 4,
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

/// A user row the transcript draws as the person's bubble (rows/MessageRow.tsx: no `received`, no `incoming`).
const bubbles = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "user" && !row.received && !row.incoming);

const turn = (prompt: Record<string, unknown>, reply: string): Step[] => [
  ["mux", "user_message", prompt],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", say(reply)],
  ["mux", "turn_result", { stopReason: "end_turn" }],
];

test("a prompt with no text to read draws no bubble; the prompts around it keep theirs", async () => {
  const history = record([
    ...turn({ text: "Rename the helper", client: "acpmux-cli#01a1", promptId: "p-1" }, "Renamed."),
    ...turn({ text: "", client: "acpmux-peer#01a1", promptId: "p-2" }, "One."),
    ...turn({ text: "  \n\t ", client: "acpmux-cli#01a1", promptId: "p-3" }, "Two."),
    // acpmux's stub for a record too large for the page: no `text`, no `promptId`.
    ...turn({ _meta: { acpmux: { omitted: { bytes: 31_000_000, reason: "too_large" } } } }, "Three."),
    ...turn({ text: "Now add a test", client: "acpmux-cli#01a1", promptId: "p-5" }, "Added."),
  ]);
  const rows = await rowsOf(history);
  expect(bubbles(rows).map((row) => row.text)).toEqual(["Rename the helper", "Now add a test"]);
  // No row App.tsx would draw as a bubble has nothing in it.
  for (const row of bubbles(rows)) expect(row.text?.trim()).toBeTruthy();
  // The blank prompts are kept as rows that draw nothing, so each reply stays its own turn.
  const hidden = rows.filter((row) => row.kind === "user" && row.incoming?.kind === "hidden");
  expect(hidden).toHaveLength(3);
  expect(rows.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual([
    "Renamed.",
    "One.",
    "Two.",
    "Three.",
    "Added.",
  ]);
});

test("a steer that carried no text draws no bubble", async () => {
  const history = record([
    ["mux", "user_message", { text: "Fix the build", client: "acpmux-cli#01a1", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Looking.")],
    ["mux", "user_message", { text: "", steer: true, client: "acpmux-peer#01a1", promptId: "p-2" }],
    ["in", "agent_message_chunk", say("Done.")],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ]);
  const rows = await rowsOf(history);
  expect(bubbles(rows).map((row) => row.text)).toEqual(["Fix the build"]);
});

test("a prompt of images alone keeps its row and its images", async () => {
  const images = [{ id: "img-1", mimeType: "image/png", name: "screen.png" }];
  const history = record(turn({ text: "", images, client: "cmux-next#0001", promptId: "p-1" }, "I see a chart."));
  const rows = await rowsOf(history);
  const prompt = rows.find((row) => row.kind === "user");
  expect(prompt?.incoming).toBeUndefined();
  expect(prompt?.images?.map((image) => image.id)).toEqual(["img-1"]);
});
