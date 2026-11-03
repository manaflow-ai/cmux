// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Claude Code's prompt suggestions (Leo 2026-11-03: "i know there's suggested prompts that you can
// right arrow/tab to do stuff with... maybe we can expose it in cmux-next too"). acpmux sends one
// after a turn as `{"sessionUpdate": "prompt_suggestion", "suggestion": text}` (null takes it back,
// claude_stdio/prompt_suggestions.rs). The pane never draws it as a transcript row; the snapshot
// carries the newest one for the composer's ghost text only between turns, until the next prompt or
// turn start, and one that arrives while a turn runs is stale and never shown.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import {
  mockSessions,
  PROMPT_SUGGESTION,
  PROMPT_SUGGESTION_SESSION,
  sessionHistory,
} from "../src/agent-session/acpmux/mockFixture";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 10, 3, 6, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (value: Record<string, unknown>) => ({ method: "session/update", params: { update: value } });
const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const suggest = (suggestion: string | null) => update({ sessionUpdate: "prompt_suggestion", suggestion });
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

function fakeDaemon(history: Rec[], status: string) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status,
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

async function snapshotOf(steps: Step[], status = "idle"): Promise<AcpmuxSnapshot> {
  let latest: AcpmuxSnapshot | undefined;
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: AcpmuxSnapshot) => (latest = snapshot),
    undefined,
    fakeDaemon(record(steps), status),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return latest!;
}

const turn = (text: string, reply: string): Step[] => [
  ["mux", "user_message", { text, promptId: `p-${text}` }],
  ["mux", "turn_started", {}],
  ["in", "agent_message_chunk", say(reply)],
  ["mux", "turn_result", { stopReason: "end_turn" }],
];

test("a suggestion after a turn is the snapshot's and draws no row", async () => {
  const snapshot = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ...turn("Now add a test", "Added."),
    ["in", "prompt_suggestion", suggest("run the tests")],
  ]);
  expect(snapshot.promptSuggestion?.text).toBe("run the tests");
  expect(snapshot.rows.map((row) => row.kind)).toEqual([
    "user",
    "assistant",
    "turnSummary",
    "user",
    "assistant",
    "turnSummary",
  ]);
  expect(JSON.stringify(snapshot.rows)).not.toContain("run the tests");
});

test("the next prompt spends it; a cleared one is gone", async () => {
  const spent = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ["in", "prompt_suggestion", suggest("add a test")],
    ...turn("Now add a test", "Added."),
  ]);
  expect(spent.promptSuggestion).toBeUndefined();
  const cleared = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ["in", "prompt_suggestion", suggest("add a test")],
    ["in", "prompt_suggestion", suggest(null)],
  ]);
  expect(cleared.promptSuggestion).toBeUndefined();
});

test("a newer suggestion replaces the one before", async () => {
  const snapshot = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ["in", "prompt_suggestion", suggest("add a test")],
    ...turn("Now add a test", "Added."),
    ["in", "prompt_suggestion", suggest("commit it")],
  ]);
  expect(snapshot.promptSuggestion).toEqual({ text: "commit it", seq: 10 });
});

test("one that arrives while a turn runs is never shown, during or after it", async () => {
  const running = await snapshotOf(
    [
      ...turn("Rename the helper", "Renamed."),
      ["mux", "user_message", { text: "Now add a test", promptId: "p-2" }],
      ["mux", "turn_started", {}],
      ["in", "prompt_suggestion", suggest("add a test")],
    ],
    "running",
  );
  expect(running.promptSuggestion).toBeUndefined();
  const after = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ["mux", "user_message", { text: "Now add a test", promptId: "p-2" }],
    ["mux", "turn_started", {}],
    ["in", "prompt_suggestion", suggest("add a test")],
    ["in", "agent_message_chunk", say("Added.")],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ]);
  expect(after.promptSuggestion).toBeUndefined();
});

test("a blank suggestion is nothing; a chat with none (an older acpmux) has none", async () => {
  const blank = await snapshotOf([
    ...turn("Rename the helper", "Renamed."),
    ["in", "prompt_suggestion", suggest("  ")],
  ]);
  expect(blank.promptSuggestion).toBeUndefined();
  const none = await snapshotOf([...turn("Rename the helper", "Renamed."), ...turn("Now add a test", "Added.")]);
  expect(none.promptSuggestion).toBeUndefined();
});

test("the mock chat with a suggestion (?mock) carries it, and offers the Prompt suggestions option", async () => {
  const scene = mockSessions.find((session) => session.sessionId === PROMPT_SUGGESTION_SESSION)!;
  const steps: Step[] = sessionHistory(scene).map((step) =>
    "update" in step
      ? ["in", String(step.update.sessionUpdate), update(step.update)]
      : ["mux", step.mux, step.msg ?? {}],
  );
  const snapshot = await snapshotOf(steps);
  expect(snapshot.promptSuggestion?.text).toBe(PROMPT_SUGGESTION);
  expect(scene.extraOptions?.map((option) => option.id)).toEqual(["prompt-suggestions"]);
});
