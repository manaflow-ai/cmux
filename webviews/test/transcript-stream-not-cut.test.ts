// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reply that streams is one message until it ends, whatever lands in the turn meanwhile. Leo,
// 2026-11-05, on a reply cut mid-sentence ("Its owner, `") with its Copy/Speak row and a gap under
// the first half, and the rest of the sentence below: "If your text is streaming, I shouldn't be
// able to interrupt it or, like, break it in between."
//
// An agent that names its messages (Claude) kept its text together across a steer (cx-f51kv,
// agent-pane-steer-split.test.ts); one that names none (Codex) had its reply ended at the prompt's
// record, and the rest of the sentence started a row below the bubble. A host's notice did the same
// to any agent. Now the reply keeps its row for its own text, and what landed draws below it.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 10, 5, 21, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string, messageId?: string) =>
  update({
    sessionUpdate: "agent_message_chunk",
    ...(messageId ? { messageId } : {}),
    content: { type: "text", text },
  });
const think = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });

const record = (steps: Step[]) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));

async function rowsOf(steps: Step[], harness = "codex"): Promise<AcpmuxRow[]> {
  const history = record(steps);
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness,
    family: harness,
    status: "running",
    steering: false,
    turnCount: 1,
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
        return { events: [], hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  };
  let socket: any;
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
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
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return rows;
}

/// The transcript's text rows in order: each reply's text, each prompt's or notice's.
const drawn = (rows: AcpmuxRow[]) =>
  rows
    .filter((row) => row.kind === "assistant" || row.kind === "user" || row.kind === "notice")
    .map((row) => `${row.kind}: ${row.text}`);

const opened: Step[] = [
  ["mux", "user_message", { text: "Where is G2?", promptId: "p-1", turnId: "turn-1" }],
  ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }],
];

test("a steer sent while an unnamed message streams leaves the message whole above it", async () => {
  const rows = await rowsOf([
    ...opened,
    ["in", "agent_message_chunk", say("G2 exists only on studio-mac, pushed. Its owner, `")],
    ["mux", "user_message", { text: "which lane?", promptId: "p-2", steer: true }],
    ["in", "agent_message_chunk", say("build-box/prebuilt-ci`, ran it before.")],
  ]);
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac, pushed. Its owner, `build-box/prebuilt-ci`, ran it before.",
    "user: which lane?",
  ]);
  // Still one message being written: it shows no action row yet.
  expect(rows.find((row) => row.kind === "assistant")!.streaming).toBe(true);
});

test("after its next step, the unnamed agent's answer to the steer starts below the bubble", async () => {
  const rows = await rowsOf([
    ...opened,
    ["in", "agent_message_chunk", say("G2 exists only on studio-mac.")],
    ["mux", "user_message", { text: "which lane?", promptId: "p-2", steer: true }],
    ["in", "agent_message_chunk", say(" Its owner is lane 2.")],
    ["in", "agent_thought_chunk", think("The person asks which lane.")],
    ["in", "agent_message_chunk", say("Lane 2 owns it.")],
  ]);
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac. Its owner is lane 2.",
    "user: which lane?",
    "assistant: Lane 2 owns it.",
  ]);
});

test("a host's notice mid-message leaves a named message whole above it", async () => {
  const rows = await rowsOf(
    [
      ...opened,
      ["in", "agent_message_chunk", say("G2 exists only on studio-mac. Its owner, `", "m-1")],
      ["mux", "host_notice", { text: "cmux Cloud resized this machine." }],
      ["in", "agent_message_chunk", say("lane-2`, pushed it.", "m-1")],
      ["in", "agent_message_chunk", say("Next message.", "m-2")],
    ],
    "claude",
  );
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac. Its owner, `lane-2`, pushed it.",
    "notice: cmux Cloud resized this machine.",
    "assistant: Next message.",
  ]);
});

test("a named message keeps its text across a steer, and the next message starts below it", async () => {
  const rows = await rowsOf(
    [
      ...opened,
      ["in", "agent_message_chunk", say("G2 exists only on studio-mac. Its owner, `", "m-1")],
      ["mux", "user_message", { text: "which lane?", promptId: "p-2", steer: true }],
      ["in", "agent_message_chunk", say("lane-2`, pushed it.", "m-1")],
      ["in", "agent_message_chunk", say("Lane 2.", "m-2")],
    ],
    "claude",
  );
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac. Its owner, `lane-2`, pushed it.",
    "user: which lane?",
    "assistant: Lane 2.",
  ]);
});

test("a prompt that opens a turn over an unnamed reply starts its answer below its bubble", async () => {
  // Not a steer: the agent answers the prompt from its first word (agent-pane-transcript-spacing).
  const rows = await rowsOf([
    ...opened,
    ["in", "agent_message_chunk", say("Checking the hosted run now.")],
    ["mux", "user_message", { text: "Also check the PR checks.", promptId: "p-2" }],
    ["in", "agent_message_chunk", say("Not yet: the hosted run is still queued.")],
  ]);
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: Checking the hosted run now.",
    "user: Also check the PR checks.",
    "assistant: Not yet: the hosted run is still queued.",
  ]);
});

const planned = (entries: { content: string; status: string }[]) =>
  update({ sessionUpdate: "plan", entries: entries.map((entry) => ({ ...entry, priority: "medium" })) });

test("a plan cleared after a steer is the agent's next step: its answer starts below the bubble", async () => {
  const rows = await rowsOf([
    ...opened,
    ["in", "plan", planned([{ content: "Find G2", status: "in_progress" }])],
    ["in", "agent_message_chunk", say("G2 exists only on studio-mac.")],
    ["mux", "user_message", { text: "which lane?", promptId: "p-2", steer: true }],
    ["in", "plan", planned([])],
    ["in", "agent_message_chunk", say("Lane 2 owns it.")],
  ]);
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac.",
    "user: which lane?",
    "assistant: Lane 2 owns it.",
  ]);
});

test("a plan changed in place after a notice held the reply is the agent's next step", async () => {
  const rows = await rowsOf([
    ...opened,
    ["in", "plan", planned([{ content: "Find G2", status: "in_progress" }])],
    ["in", "agent_message_chunk", say("G2 exists only on studio-mac.")],
    ["mux", "host_notice", { text: "cmux Cloud resized this machine." }],
    ["in", "plan", planned([{ content: "Find G2", status: "completed" }])],
    ["in", "agent_message_chunk", say("Next, item A.")],
  ]);
  expect(drawn(rows)).toEqual([
    "user: Where is G2?",
    "assistant: G2 exists only on studio-mac.",
    "notice: cmux Cloud resized this machine.",
    "assistant: Next, item A.",
  ]);
});
