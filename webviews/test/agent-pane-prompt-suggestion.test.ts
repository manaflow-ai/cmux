// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Claude Code's prompt suggestions (Leo 2026-11-03: "i know there's suggested prompts that you can
// right arrow/tab to do stuff with... maybe we can expose it in cmux-next too"). acpmux sends one
// after a turn as `{"sessionUpdate": "prompt_suggestion", "suggestion": text}` (null takes it back,
// claude_stdio/prompt_suggestions.rs). The pane never draws it as a transcript row; the snapshot
// carries the newest one for the composer's ghost text only between turns, until the next prompt or
// turn start, and one that arrives while a turn runs is stale and never shown. acpmux sends it live
// only (hub/paging.rs keeps it out of pages, `matches_live` passes it live); the pages below hold it so the
// reducer's ordering can be checked, and the live test sends it as acpmux does.
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

let liveSocket: any;
let attachParams: any;
const prompts: any[] = [];
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
        if (message.method === "_acpmux/attach") attachParams = message.params;
        if (message.method === "session/prompt") prompts.push(message.params);
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
          }),
        );
      },
      close() {},
    };
    liveSocket = socket;
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};
let latest: AcpmuxSnapshot | undefined;
let client: AcpmuxDirectClient | undefined;
async function snapshotOf(steps: Step[], status = "idle"): Promise<AcpmuxSnapshot> {
  latest = undefined;
  client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: AcpmuxSnapshot) => (latest = snapshot),
    undefined,
    fakeDaemon(record(steps), status),
  );
  await settle();
  return latest!;
}
/** acpmux's live record of `step`, after the attach page's `seq`s. */
async function live(seq: number, [dir, kind, msg]: Step): Promise<AcpmuxSnapshot> {
  const params = { sessionId: CHAT, seq, at: START + seq * 1000, dir, kind, msg };
  liveSocket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params }) });
  await settle();
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

test("live, as acpmux sends it: shown after the turn, gone when the next prompt goes", async () => {
  const opened = await snapshotOf([...turn("Rename the helper", "Renamed."), ...turn("Now add a test", "Added.")]);
  expect(opened.promptSuggestion).toBeUndefined();
  const suggested = await live(9, ["in", "prompt_suggestion", suggest("commit it")]);
  expect(suggested.promptSuggestion).toEqual({ text: "commit it", seq: 9 });
  expect(JSON.stringify(suggested.rows)).not.toContain("commit it");
  const sent = await live(10, ["mux", "user_message", { text: "commit it", promptId: "p-3" }]);
  expect(sent.promptSuggestion).toBeUndefined();
});

// acpmux's "transcript" event stream carries the update live (hub/paging.rs `matches_live`, #33085)
// while its pages leave it out, so the attach asks for no kind of its own.
test("the attach asks for no extra kind: the transcript stream carries it live", async () => {
  await snapshotOf(turn("Rename the helper", "Renamed."));
  expect(attachParams.eventStream).toBe(true);
  expect(attachParams.kinds).toContain("transcript");
  expect(attachParams.kinds).not.toContain("prompt_suggestion");
});

test("the mock chat with a suggestion (?mock) carries acpmux's Prompt suggestions option and pages none", async () => {
  const scene = mockSessions.find((session) => session.sessionId === PROMPT_SUGGESTION_SESSION)!;
  expect(scene.suggestion).toBe(PROMPT_SUGGESTION);
  expect(scene.extraOptions?.map((option) => option.id)).toEqual(["prompt-suggestions"]);
  // acpmux sends it live only, so the chat's paged history holds none.
  expect(JSON.stringify(sessionHistory(scene))).not.toContain("prompt_suggestion");
});

// acpmux shows a harness's suggestions only while they tend to be taken (suggestion_gate.rs): it
// counts the next prompt as taken when it is the suggestion, or when the composer says the person
// took it into the field (Tab, Right-arrow) and then edited it.
test("a send after taking the suggestion tells acpmux it was taken; the next one does not", async () => {
  await snapshotOf([...turn("Rename the helper", "Renamed."), ["in", "prompt_suggestion", suggest("commit it")]]);
  prompts.length = 0;
  client!.takeSuggestion();
  void client!.send("commit it, then push").catch(() => undefined);
  await settle();
  void client!.send("and tag it").catch(() => undefined);
  await settle();
  expect(prompts.map((params) => params._meta?.acpmux?.promptSuggestion)).toEqual(["taken", undefined]);
  client!.close?.();
});

test("taking with no suggestion shown marks nothing", async () => {
  await snapshotOf(turn("Rename the helper", "Renamed."));
  prompts.length = 0;
  client!.takeSuggestion();
  void client!.send("anything").catch(() => undefined);
  await settle();
  expect(prompts.map((params) => params._meta?.acpmux?.promptSuggestion)).toEqual([undefined]);
  client!.close?.();
});
