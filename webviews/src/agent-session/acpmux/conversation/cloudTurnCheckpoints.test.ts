// A Cloud chat's turn checkpoints (cloudTurnCheckpoints.ts): one `chat.turnCheckpoint {afterSeq}`
// per completed turn, only while the handshake's `cloudTurnRewind` is present, one in flight with
// only the newest waiting, failures logged and nothing else; the answer's row joins the ready set and
// its retention's deleted turns leave it; and the prompt rows the page draws map to those marks.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import {
  bindMarks,
  chatAfterRewind,
  chatWithCheckpoint,
  CloudTurnCheckpoints,
  handshakeMarks,
  marksFor,
  readyPromptRows,
  withCheckpoint,
} from "./cloudTurnCheckpoints";

type Pending = { afterSeq: number; resolve(answer: unknown): void; reject(error: unknown): void };

function harness(on = true) {
  const asked: Pending[] = [];
  const answers: unknown[] = [];
  const logged: unknown[] = [];
  const checkpoints = new CloudTurnCheckpoints(
    (afterSeq) =>
      new Promise((resolve, reject) => {
        asked.push({ afterSeq, resolve, reject });
      }),
    (answer) => answers.push(answer),
    (error) => logged.push(error),
  );
  checkpoints.setOn(on);
  let rows: { kind: string; seq?: number }[] = [{ kind: "user" }, { kind: "turnSummary", seq: 4 }];
  const snap = (isWorking: boolean, sessionId = "s1") => checkpoints.observe({ sessionId, isWorking, rows });
  // A turn: the prompt starts it, its summary lands and it ends.
  const turn = (summarySeq: number, sessionId = "s1") => {
    rows = [...rows, { kind: "user" }];
    snap(true, sessionId);
    rows = [...rows, { kind: "turnSummary", seq: summarySeq }];
    snap(false, sessionId);
  };
  return {
    checkpoints,
    asked,
    answers,
    logged,
    snap,
    turn,
    rows: () => rows,
    setRows: (next: typeof rows) => (rows = next),
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("asks once per completed turn, for its summary's seq, and not on load", async () => {
  const h = harness();
  h.snap(false); // the chat loads with turns already ended: no checkpoint
  expect(h.asked).toHaveLength(0);
  h.turn(9);
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9]);
  // Further snapshots of the same idle chat (streamed metadata, a reread) ask nothing more.
  h.snap(false);
  h.snap(false);
  expect(h.asked).toHaveLength(1);
  h.asked[0]!.resolve({ rowId: "user-10" });
  await settle();
  h.turn(15);
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9, 15]);
});

test("a turn whose summary lands after it stops working asks once the summary is in", () => {
  const h = harness();
  h.setRows([{ kind: "user" }]);
  h.snap(true);
  h.snap(false);
  expect(h.asked).toHaveLength(0);
  h.setRows([{ kind: "user" }, { kind: "turnSummary", seq: 3 }]);
  h.snap(false);
  expect(h.asked.map((a) => a.afterSeq)).toEqual([3]);
});

test("never asks when the handshake had no cloudTurnRewind", () => {
  const h = harness(false);
  h.snap(false);
  h.turn(9);
  h.turn(12);
  expect(h.asked).toHaveLength(0);
});

test("one in flight: turns that end meanwhile wait, and only the newest goes", async () => {
  const h = harness();
  h.snap(false);
  h.turn(9);
  h.turn(12);
  h.turn(15);
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9]);
  h.asked[0]!.resolve({ rowId: "user-10" });
  await settle();
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9, 15]);
  h.asked[1]!.resolve({ rowId: "user-16" });
  await settle();
  expect(h.asked).toHaveLength(2);
  expect(h.answers).toEqual([{ rowId: "user-10" }, { rowId: "user-16" }]);
});

test("a failure is logged, answers nothing and the next turn still asks", async () => {
  const h = harness();
  h.snap(false);
  h.turn(9);
  h.turn(12);
  h.asked[0]!.reject(new Error("Cloud chat is unavailable"));
  await settle();
  expect(h.logged).toHaveLength(1);
  expect(h.answers).toHaveLength(0);
  // The turn that waited goes once the failed one settles.
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9, 12]);
  h.asked[1]!.resolve({ rowId: "user-13" });
  await settle();
  expect(h.answers).toEqual([{ rowId: "user-13" }]);
});

test("a request that throws at once is logged too", async () => {
  const logged: unknown[] = [];
  const checkpoints = new CloudTurnCheckpoints(
    () => {
      throw new Error("no host");
    },
    () => undefined,
    (error) => logged.push(error),
  );
  checkpoints.setOn(true);
  checkpoints.observe({ sessionId: "s", isWorking: true, rows: [] });
  checkpoints.observe({ sessionId: "s", isWorking: false, rows: [{ kind: "turnSummary", seq: 2 }] });
  await settle();
  expect(logged).toHaveLength(1);
});

test("an answer for a chat no longer shown is dropped, and its waiting turn is not asked", async () => {
  const h = harness();
  h.snap(false);
  h.turn(9);
  h.turn(12);
  h.setRows([{ kind: "user" }]);
  h.snap(false, "s2");
  h.asked[0]!.resolve({ rowId: "user-10" });
  await settle();
  expect(h.answers).toHaveLength(0);
  expect(h.asked).toHaveLength(1);
});

test("an answer adds its rowId and drops the rows its retention deleted", () => {
  const ready = new Set(["user-3", "user-7"]);
  const next = withCheckpoint(ready, {
    rowId: "user-12",
    retention: { kept: 5, deleted: ["auto-t3-g0", "auto-t12-g0", "manual-x"], failed: [] },
  });
  expect([...next!].sort()).toEqual(["user-12", "user-7"]);
  // Nothing new: the same set, so the turn actions are not rebuilt.
  expect(withCheckpoint(next, { rowId: "user-12", retention: { deleted: [] } })).toBe(next);
  // Off (no ready set) stays off, and a malformed answer changes nothing.
  expect(withCheckpoint(undefined, { rowId: "user-12" })).toBeUndefined();
  expect(withCheckpoint(next, { rowId: "assistant-4" })).toBe(next);
  expect(withCheckpoint(next, null)).toBe(next);
});

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...extra,
});

test("each prompt maps to the newest mark between the turn before it and itself", () => {
  const rows = [
    row("user-1", "user", { text: "first" }),
    row("assistant-2", "assistant"),
    row("summary-a", "turnSummary", { seq: 5 }),
    // The next prompt's echo came two events after the checkpoint's mark (user-6).
    row("user-8", "user", { text: "second" }),
    row("summary-b", "turnSummary", { seq: 11 }),
    // This pane sent the third prompt: its row keeps its local id.
    row("local-p3", "user", { text: "third" }),
    row("summary-c", "turnSummary", { seq: 20 }),
    // The running turn's prompt, also local.
    row("local-p4", "user", { text: "fourth" }),
  ];
  const shown = readyPromptRows(rows, new Set(["user-6", "user-12", "user-21"]));
  expect([...shown]).toEqual([
    ["user-8", "user-6"],
    ["local-p3", "user-12"],
    ["local-p4", "user-21"],
  ]);
  // A mark of the row itself and the first prompt's checkpoint (after "turn 0").
  expect([...readyPromptRows(rows, new Set(["user-1", "user-8"]))]).toEqual([
    ["user-1", "user-1"],
    ["user-8", "user-8"],
  ]);
  // A mark past a prompt is not that prompt's; no marks, no rows.
  expect([...readyPromptRows(rows.slice(0, 4), new Set(["user-9"]))]).toEqual([]);
  expect(readyPromptRows(rows, undefined).size).toBe(0);
});

test("steers, failed prompts and turns paged in with no seq take no mark", () => {
  const rows = [
    row("summary-old", "turnSummary"),
    row("user-30", "user", { text: "after a paged turn" }),
    row("summary-a", "turnSummary", { seq: 40 }),
    row("local-failed", "user", { text: "x", failed: true }),
    row("user-42", "user", { text: "opens the turn" }),
    row("user-43", "user", { text: "a second prompt in the same turn" }),
  ];
  expect([...readyPromptRows(rows, new Set(["user-25", "user-41", "user-43"]))]).toEqual([["user-42", "user-41"]]);
});

test("a checkpoint answered for one chat never readies another chat's prompt after chat.select", () => {
  const marks = chatWithCheckpoint(handshakeMarks(undefined, new Set(["user-4"]), "a"), { rowId: "user-10" }, "a");
  expect([...(marksFor(marks, "a") ?? [])]).toEqual(["user-4", "user-10"]);
  // chat.select to B: no new handshake, and B has no checkpoint of its own.
  expect([...(marksFor(marks, "b") ?? [])]).toEqual([]);
  const rowsB = [
    row("user-1", "user", { text: "one", seq: 1 }),
    row("summary-3", "turnSummary", { seq: 3 }),
    row("user-10", "user", { text: "ten", seq: 10 }),
  ];
  expect([...readyPromptRows(rowsB, marksFor(marks, "b"))]).toEqual([]);
  // B's own checkpoint readies only B's prompt; A keeps its own.
  const both = chatWithCheckpoint(marks, { rowId: "user-10" }, "b");
  expect([...readyPromptRows(rowsB, marksFor(both, "b"))]).toEqual([["user-10", "user-10"]]);
  expect([...(marksFor(both, "a") ?? [])]).toEqual(["user-4", "user-10"]);
  // Retention for B drops B's mark only.
  const pruned = chatWithCheckpoint(both, { rowId: "user-12", retention: { deleted: ["auto-t10-g0"] } }, "b");
  expect([...(marksFor(pruned, "b") ?? [])]).toEqual(["user-12"]);
  expect([...(marksFor(pruned, "a") ?? [])]).toEqual(["user-4", "user-10"]);
});

test("a handshake's list replaces its chat's set and keeps the other chats'", () => {
  const first = chatWithCheckpoint(handshakeMarks(undefined, new Set(["user-4"]), "a"), { rowId: "user-7" }, "b");
  const again = handshakeMarks(first, new Set(["user-9"]), "a");
  expect([...(marksFor(again, "a") ?? [])]).toEqual(["user-9"]);
  expect([...(marksFor(again, "b") ?? [])]).toEqual(["user-7"]);
  // No cloudTurnRewind in the handshake: no rewind anywhere.
  expect(handshakeMarks(again, undefined, "a")).toBeUndefined();
  expect(marksFor(undefined, "a")).toBeUndefined();
});

test("a handshake naming no chat binds its list to the first chat shown, not to the next one", () => {
  const unbound = handshakeMarks(undefined, new Set(["user-4"]), undefined);
  expect([...(marksFor(unbound, "a") ?? [])]).toEqual(["user-4"]);
  const bound = bindMarks(unbound, "a");
  expect([...(marksFor(bound, "a") ?? [])]).toEqual(["user-4"]);
  expect([...(marksFor(bound, "b") ?? [])]).toEqual([]);
  expect(bindMarks(bound, "b")).toBe(bound);
  // An answer before the bind binds the list to the answer's chat too.
  const answered = chatWithCheckpoint(unbound, { rowId: "user-8" }, "a");
  expect([...(marksFor(answered, "a") ?? [])]).toEqual(["user-4", "user-8"]);
  expect([...(marksFor(answered, "b") ?? [])]).toEqual([]);
});

test("the observer hands each answer the chat it was asked for", async () => {
  const seen: (string | undefined)[] = [];
  const checkpoints = new CloudTurnCheckpoints(
    async () => ({ rowId: "user-5" }),
    (_answer, session) => seen.push(session),
  );
  checkpoints.setOn(true);
  const rows = [{ kind: "user" }, { kind: "turnSummary", seq: 2 }];
  checkpoints.observe({ sessionId: "a", isWorking: false, rows });
  checkpoints.observe({ sessionId: "a", isWorking: true, rows: [...rows, { kind: "user" }] });
  checkpoints.observe({
    sessionId: "a",
    isWorking: false,
    rows: [...rows, { kind: "user" }, { kind: "turnSummary", seq: 4 }],
  });
  await Promise.resolve();
  await Promise.resolve();
  expect(seen).toEqual(["a"]);
});

test("a waiting checkpoint is dropped when a turn starts before it goes", async () => {
  const h = harness();
  h.snap(false);
  h.turn(9);
  h.turn(12); // waits behind 9
  // Another turn starts while 9 is still in flight: 12's checkpoint would capture its changes.
  h.setRows([...h.rows(), { kind: "user" }]);
  h.snap(true);
  h.asked[0]!.resolve({ rowId: "user-10" });
  await settle();
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9]);
  // That turn's own end asks for its own checkpoint.
  h.setRows([...h.rows(), { kind: "turnSummary", seq: 18 }]);
  h.snap(false);
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9, 18]);
});

test("a waiting checkpoint goes only while its chat is idle with that turn end the newest", async () => {
  const h = harness();
  h.snap(false);
  h.turn(9);
  h.turn(12); // waits behind 9
  // chat.select away and back while the chat runs another turn: no idle-to-working edge is seen.
  h.snap(false, "s2");
  h.setRows([...h.rows(), { kind: "user" }]);
  h.snap(true, "s1");
  h.asked[0]!.resolve({ rowId: "user-10" });
  await settle();
  expect(h.asked.map((a) => a.afterSeq)).toEqual([9]);
});

test("rewind then send: the new local prompt maps to the checkpoint after the turn before it", () => {
  // The chat rewound to before its second turn (summary 5); the person then sent a new prompt.
  const rows = [
    row("user-1", "user", { text: "first" }),
    row("summary-a", "turnSummary", { seq: 5 }),
    row("local-new", "user", { text: "the new prompt" }),
  ];
  const retained = new Set(["user-6", "user-12", "user-21"]);
  expect([...readyPromptRows(rows, retained)]).toEqual([["local-new", "user-6"]]);
  // Only the checkpoint taken right after summary 5: none, no button (never user-12 or user-21).
  expect([...readyPromptRows(rows, new Set(["user-12", "user-21"]))]).toEqual([]);
  // A prompt row with its own seq is bounded by it.
  const echoed = [...rows.slice(0, 2), row("local-new", "user", { text: "x", seq: 8 })];
  expect([...readyPromptRows(echoed, retained)]).toEqual([["local-new", "user-6"]]);
});

test("a successful rewind drops the chat's marks past the restored checkpoint", () => {
  const start = handshakeMarks(undefined, new Set(["user-6", "user-12", "user-21"]), "a");
  const other = chatWithCheckpoint(start, { rowId: "user-30" }, "b");
  const rewound = chatAfterRewind(other, { turn: "auto-t6-g0", turnSeq: 8, generation: 1 }, "a", "user-6");
  expect([...(marksFor(rewound, "a") ?? [])]).toEqual(["user-6"]);
  expect([...(marksFor(rewound, "b") ?? [])]).toEqual(["user-30"]);
  // Without the answer's turn, the rowId's seq bounds it.
  expect([...(marksFor(chatAfterRewind(start, { seconds: 9 }, "a", "user-12"), "a") ?? [])]).toEqual([
    "user-6",
    "user-12",
  ]);
  // A checkpoint asked before the rewind (an older generation) adds nothing; a new one does.
  expect(chatWithCheckpoint(rewound, { rowId: "user-22", generation: 0 }, "a")).toBe(rewound);
  const next = chatWithCheckpoint(rewound, { rowId: "user-9", generation: 1 }, "a");
  expect([...(marksFor(next, "a") ?? [])]).toEqual(["user-6", "user-9"]);
  // After the rewind the new local prompt maps to the restored checkpoint, never user-21.
  const rows = [
    row("user-1", "user", { text: "first" }),
    row("summary-a", "turnSummary", { seq: 5 }),
    row("local-new", "user", { text: "the new prompt" }),
  ];
  expect([...readyPromptRows(rows, marksFor(rewound, "a"))]).toEqual([["local-new", "user-6"]]);
});
