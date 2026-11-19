// Back to before this turn in a chat on this machine (localRewindModel.ts): which prompts rewind (from
// their turn summary's rewind fields), what the dry run offers for the files, and the RPC steps a
// rewind and its Undo take.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { translate } from "../i18n";
import {
  applyRewind,
  blockedText,
  canConfirm,
  failedText,
  filesOffer,
  initialChoice,
  localRewindKey,
  localRewindMap,
  localRewindPrompts,
  parseDryRun,
  readTurnRewind,
  undoAfterFailedRewind,
  undoRewind,
} from "./localRewindModel";

const user = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 1,
  kind: "user",
  text: id,
  ...extra,
});
const summary = (seq: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `summary-${seq}`,
  version: 1,
  at: 1,
  kind: "turnSummary",
  seq,
  status: "completed",
  ...extra,
});

test("a turn_result's rewind fields are read, and none without them", () => {
  expect(readTurnRewind({ rewindCheckpointId: "cp-1" })).toEqual({ checkpointId: "cp-1" });
  expect(readTurnRewind({ rewindCheckpointError: "not a git repository" })).toEqual({ error: "not a git repository" });
  expect(readTurnRewind({ rewind: { checkpointId: "cp-2" } })).toEqual({ checkpointId: "cp-2" });
  expect(readTurnRewind({ checkpointId: "other" })).toBeUndefined();
  expect(readTurnRewind({ rewindCheckpointId: "" })).toBeUndefined();
  expect(readTurnRewind(undefined)).toBeUndefined();
});

test("a prompt rewinds only when its turn ended with a rewind field, with its own seq", () => {
  const rows = [
    user("user-1"),
    summary(3, { rewind: { checkpointId: "cp-a" } }),
    // A sent prompt keeps its local id; its echo's seq names it.
    user("local-abc", { promptSeq: 4 }),
    summary(7, { rewind: { error: "not a git repository" } }),
    // The setting off: no field, no rewind.
    user("user-8"),
    summary(9),
    // Still running: no summary yet.
    user("user-10"),
  ];
  const ready = localRewindPrompts(rows);
  expect([...ready]).toEqual([
    ["user-1", 1],
    ["local-abc", 4],
  ]);
  expect(localRewindMap(localRewindKey(ready))).toEqual(ready);
});

test("a prompt with no seq, a failed one or a waiting steer never rewinds", () => {
  const rows = [
    user("local-x"),
    summary(3, { rewind: { checkpointId: "cp" } }),
    user("user-4", { failed: true } as Partial<AcpmuxRow>),
    summary(5, { rewind: { checkpointId: "cp" } }),
  ];
  expect(localRewindPrompts(rows).size).toBe(0);
  expect(localRewindPrompts([]).size).toBe(0);
});

test("the dry run's files give the count, or why they can't be reset", () => {
  const available = parseDryRun({
    conversation: "fork",
    files: { checkpointId: "cp", total: 3, paths: ["a", "b", "c"], baseChanged: false, complete: true },
  });
  expect(filesOffer(available)).toEqual({ kind: "available", total: 3, baseChanged: false, complete: true });
  const shared = parseDryRun({
    conversation: "fork",
    files: null,
    filesBlocked: { reason: "shared", message: "x", sharedWith: [{ sessionId: "s2", title: "Fix the pager" }] },
  });
  expect(filesOffer(shared)).toEqual({
    kind: "blocked",
    reason: "shared",
    sharedWith: [{ sessionId: "s2", title: "Fix the pager" }],
  });
  const offer = filesOffer(shared);
  if (offer?.kind !== "blocked") throw new Error("blocked");
  expect(blockedText(translate, offer)).toBe(translate("rewind.blocked.sharedWith", { title: "Fix the pager" }));
  expect(blockedText(translate, { reason: "shared" })).toBe(translate("rewind.blocked.shared"));
  for (const [reason, key] of [
    ["not_git", "rewind.blocked.notGit"],
    ["no_checkpoint", "rewind.blocked.noCheckpoint"],
    ["base_changed", "rewind.blocked.baseChanged"],
    ["something_new", "rewind.blocked.unavailable"],
  ] as const) {
    const dry = parseDryRun({ conversation: "fork", files: null, filesBlocked: { reason, message: "" } });
    const blocked = filesOffer(dry);
    if (blocked?.kind !== "blocked") throw new Error("blocked");
    expect(blockedText(translate, blocked)).toBe(translate(key));
  }
  expect(filesOffer(parseDryRun({ conversation: "fork", files: null }))).toEqual({
    kind: "blocked",
    reason: "no_checkpoint",
  });
  expect(filesOffer(parseDryRun({ conversation: "fork", files: { checkpointId: "cp", total: 0, paths: [] } }))).toEqual(
    { kind: "blocked", reason: "none" },
  );
  expect(filesOffer(undefined)).toBeUndefined();
});

test("the ask opens on the conversation alone, and Confirm needs a part that can go back", () => {
  const dry = parseDryRun({ conversation: "fork", files: { checkpointId: "cp", total: 2, paths: [] } });
  expect(initialChoice(dry)).toEqual({ conversation: true, files: false });
  expect(canConfirm(dry, { conversation: true, files: false })).toBe(true);
  expect(canConfirm(dry, { conversation: true, files: true })).toBe(true);
  expect(canConfirm(dry, { conversation: false, files: true })).toBe(true);
  expect(canConfirm(dry, { conversation: false, files: false })).toBe(false);
  expect(canConfirm(undefined, { conversation: true, files: false })).toBe(false);
  const blocked = parseDryRun({ conversation: "fork", files: null, filesBlocked: { reason: "not_git", message: "" } });
  expect(canConfirm(blocked, { conversation: true, files: true })).toBe(false);
  // A conversation that can't go back with files that can: files only.
  const filesOnly = parseDryRun({ conversation: null, files: { checkpointId: "cp", total: 1, paths: [] } });
  expect(initialChoice(filesOnly)).toEqual({ conversation: false, files: true });
  expect(canConfirm(filesOnly, { conversation: true, files: true })).toBe(false);
});

test("a failed rewind names a reason acpmux gave, else says it failed", () => {
  expect(failedText(translate, { reason: "fork.unsupported" })).toBe(
    translate("rewind.failedReason", { reason: translate("rewind.blocked.forkUnsupported") }),
  );
  expect(failedText(translate, { reason: "shared" })).toBe(
    translate("rewind.failedReason", { reason: translate("rewind.blocked.shared") }),
  );
  expect(failedText(translate, new Error("boom"))).toBe(translate("rewind.failed"));
});

function recorder() {
  const calls: unknown[][] = [];
  return {
    calls,
    io: (answer: unknown) => ({
      original: "chat-1",
      rewind: async (seq: number, choice: unknown) => {
        calls.push(["rewind", seq, choice]);
        return answer;
      },
      open: async (sessionId: string) => {
        calls.push(["open", sessionId]);
      },
      restorePrompt: (text: string) => {
        calls.push(["prompt", text]);
      },
    }),
  };
}

test("a conversation rewind opens its fork, puts the prompt back, and Undo restores files then the chat", async () => {
  const { calls, io } = recorder();
  const undo = await applyRewind(
    5,
    { conversation: true, files: true },
    io({
      sessionId: "fork-9",
      prompt: { text: "Now cover it with a test" },
      undo: { sessionId: "chat-1", safetyCheckpointId: "safe-1" },
      filesRestored: 3,
    }),
  );
  expect(calls).toEqual([
    ["rewind", 5, { conversation: true, files: true }],
    ["open", "fork-9"],
    ["prompt", "Now cover it with a test"],
  ]);
  expect(undo).toEqual({
    original: "chat-1",
    rewound: "fork-9",
    safetyCheckpointId: "safe-1",
    conversation: true,
    files: 3,
  });

  const steps: unknown[][] = [];
  await undoRewind(undo, {
    restoreFiles: async (sessionId, safety) => void steps.push(["rewind_undo", sessionId, safety]),
    open: async (sessionId) => void steps.push(["open", sessionId]),
  });
  expect(steps).toEqual([
    ["rewind_undo", "chat-1", "safe-1"],
    ["open", "chat-1"],
  ]);
});

test("a files-only rewind opens nothing, and its Undo restores the files only", async () => {
  const { calls, io } = recorder();
  const undo = await applyRewind(
    5,
    { conversation: false, files: true },
    io({ undo: { sessionId: "chat-1", safetyCheckpointId: "safe-2" }, filesRestored: 2 }),
  );
  expect(calls).toEqual([["rewind", 5, { conversation: false, files: true }]]);
  expect(undo).toEqual({ original: "chat-1", safetyCheckpointId: "safe-2", conversation: false, files: 2 });
  const steps: unknown[][] = [];
  await undoRewind(undo, {
    restoreFiles: async (sessionId, safety) => void steps.push(["rewind_undo", sessionId, safety]),
    open: async (sessionId) => void steps.push(["open", sessionId]),
  });
  expect(steps).toEqual([["rewind_undo", "chat-1", "safe-2"]]);
});

test("a conversation-only rewind's Undo reopens the chat without touching files", async () => {
  const { io } = recorder();
  const undo = await applyRewind(
    5,
    { conversation: true, files: false },
    io({ sessionId: "fork-3", prompt: { text: "hi" }, undo: { sessionId: "chat-1" }, filesRestored: 0 }),
  );
  const steps: unknown[][] = [];
  await undoRewind(undo, {
    restoreFiles: async () => void steps.push(["rewind_undo"]),
    open: async (sessionId) => void steps.push(["open", sessionId]),
  });
  expect(steps).toEqual([["open", "chat-1"]]);
});

test("a refused rewind rejects with acpmux's reason and opens nothing", async () => {
  const opened: string[] = [];
  const refusal = Object.assign(new Error("refused"), { reason: "fork.unsupported" });
  await expect(
    applyRewind(
      5,
      { conversation: true, files: false },
      {
        original: "chat-1",
        rewind: () => Promise.reject(refusal),
        open: async (sessionId) => void opened.push(sessionId),
        restorePrompt: () => {},
      },
    ),
  ).rejects.toBe(refusal);
  expect(opened).toEqual([]);
});

test("a rewind that failed with its files still reset leaves their Undo; any other failure leaves none", () => {
  const stuck = Object.assign(new Error("no fork"), {
    data: {
      reason: "fork.unsupported",
      filesRolledBack: false,
      filesRestored: 3,
      undo: { safetyCheckpointId: "ckpt_s" },
    },
  });
  expect(undoAfterFailedRewind(stuck, "chat-1")).toEqual({
    original: "chat-1",
    conversation: false,
    safetyCheckpointId: "ckpt_s",
    files: 3,
  });
  const rolledBack = Object.assign(new Error("no fork"), { data: { filesRolledBack: true } });
  expect(undoAfterFailedRewind(rolledBack, "chat-1")).toBeUndefined();
  expect(undoAfterFailedRewind(new Error("refused"), "chat-1")).toBeUndefined();
  expect(undoAfterFailedRewind(undefined, "chat-1")).toBeUndefined();
});
