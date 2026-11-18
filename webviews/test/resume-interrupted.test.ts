import { expect, test } from "bun:test";
import {
  interruptedResumeTarget,
  interruptedResumeRunner,
  resumeInterrupted,
  type InterruptedResumeState,
} from "../src/agent-session/acpmux/conversation/resumeInterrupted";

const stopped = { id: "stop-1", kind: "turnSummary", version: 1, at: 1, status: "interrupted", resumable: true };
const state = (fields: Partial<InterruptedResumeState> = {}): InterruptedResumeState => ({
  sessionId: "chat-a",
  selectedSessionId: "chat-a",
  drawnSessionId: "chat-a",
  canResume: true,
  family: "codex",
  rows: [stopped],
  ...fields,
});
const owner = { sessionId: "chat-a", rowId: "stop-1" };

function setup(fields: Partial<InterruptedResumeState> = {}) {
  let current = state(fields);
  const calls: unknown[] = [];
  const gesture = { promptId: "resume-1", ticket: Promise.resolve("bound-proof") };
  const deps = {
    read: () => current,
    bind: () => {
      calls.push("bind");
      return gesture;
    },
    emptyTurn: async (sessionId: string, promptId: string, ticket: string | undefined, current: () => boolean) => {
      expect(current()).toBe(true);
      calls.push(["empty", sessionId, promptId, ticket]);
    },
    textTurn: async (...args: unknown[]) => {
      calls.push(["text", ...args]);
    },
  };
  return {
    deps,
    calls,
    gesture,
    set: (fields: Partial<InterruptedResumeState>) => {
      current = { ...current, ...fields };
    },
  };
}

test("Codex continuation sends no Continue message and keeps its session-bound gesture", async () => {
  const run = setup();
  expect(await resumeInterrupted(owner, run.deps)).toBe(true);
  expect(run.calls).toEqual(["bind", ["empty", "chat-a", "resume-1", "bound-proof"]]);
});

test("Claude keeps its existing text continuation contract", async () => {
  const run = setup({ family: "claude" });
  expect(await resumeInterrupted(owner, run.deps)).toBe(true);
  expect(run.calls).toEqual(["bind", ["text", "chat-a", run.gesture]]);
});

test("only the current latest stopped result authorizes a resume", async () => {
  for (const fields of [
    { canResume: false },
    { selectedSessionId: "chat-b" },
    { drawnSessionId: "chat-b" },
    { rows: [{ ...stopped, status: "completed" }] },
    { rows: [{ ...stopped, resumable: undefined }] },
    { rows: [stopped, { id: "new", kind: "user", version: 1, at: 2, text: "Next" }] },
    { rows: [stopped, { ...stopped, id: "finished", status: "completed" }] },
  ]) {
    const run = setup(fields);
    expect(interruptedResumeTarget(run.deps.read())).toBeUndefined();
    expect(await resumeInterrupted(owner, run.deps)).toBe(false);
    expect(run.calls).toEqual([]);
  }
});

test("a stale footer identifier binds no gesture", async () => {
  const run = setup();
  expect(await resumeInterrupted({ ...owner, rowId: "old-stop" }, run.deps)).toBe(false);
  expect(run.calls).toEqual([]);
});

test("selection, stop state, permissions and harness are rechecked after the gesture resolves", async () => {
  for (const change of [
    { selectedSessionId: "chat-b" },
    { canResume: false },
    { family: "claude" },
    { rows: [{ ...stopped, id: "different-stop" }] },
  ]) {
    const run = setup();
    let accept!: (ticket: string) => void;
    const gesture = {
      promptId: "bound",
      ticket: new Promise<string>((resolve) => {
        accept = resolve;
      }),
    };
    const sent = resumeInterrupted(owner, { ...run.deps, bind: () => gesture });
    run.set(change);
    accept("proof");
    expect(await sent).toBe(false);
    expect(run.calls).toEqual([]);
  }
});

test("a refused continuation rejects rather than pretending work resumed", async () => {
  const run = setup();
  await expect(
    resumeInterrupted(owner, { ...run.deps, emptyTurn: () => Promise.reject(new Error("refused")) }),
  ).rejects.toThrow("refused");
});

test("one chat's accepted but incomplete Resume does not block another stopped chat", async () => {
  const run = setup();
  const requests: string[] = [];
  const finish = new Map<string, () => void>();
  const resume = interruptedResumeRunner({
    ...run.deps,
    emptyTurn: async (sessionId) => {
      requests.push(sessionId);
      await new Promise<void>((resolve) => {
        finish.set(sessionId, resolve);
      });
    },
  });
  const first = resume(owner);
  await Promise.resolve();
  expect(await resume(owner)).toBe(false);
  run.set({
    sessionId: "chat-b",
    selectedSessionId: "chat-b",
    drawnSessionId: "chat-b",
    rows: [{ ...stopped, id: "stop-b" }],
  });
  const second = resume({ sessionId: "chat-b", rowId: "stop-b" });
  await Promise.resolve();
  expect(requests).toEqual(["chat-a", "chat-b"]);
  finish.get("chat-b")!();
  expect(await second).toBe(true);
  finish.get("chat-a")!();
  expect(await first).toBe(true);
});
