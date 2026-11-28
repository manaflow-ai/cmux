// l10n-allow-file: test fixture subagent names and tasks, not shipped UI.
import { describe, expect, test, jest } from "bun:test";
import { translate } from "../i18n";
import { sessionEntry } from "../sessionList";
import { SubagentFold } from "./subagentFold";
import { subsessionInfo } from "./subsessions";
import { sessionStateText, sessionStatus } from "../session-info/childSessionRowsModel";
import {
  SUBAGENT_RETRY,
  sessionRetry,
  subagentRetry,
  isRetryContinuation,
  readRetry,
  retryActionOf,
  retrying,
  retryLabel,
  RETRY_METHOD,
  runRetry,
  type RetryTarget,
  untilNotBusy,
  type RetryNote,
} from "./retryState";

// The daemon's shapes (hb-acpmux, 2026-10-26): a subagent of `_meta.acpmux.subagents` carries
// `retry: {attempt, of, reason, nextAt}` while a retry waits and `retryable: true` when acpmux can
// retry it; a session row carries `retry: {attempt, of, reason, nextAt, promptId, turnId,
// subagentId?} | null`.
const FIXTURE = {
  subagentRetry: { attempt: 2, of: 4, reason: "capacity", nextAt: 1_792_000_060_000 },
  sessionRetry: {
    attempt: 1,
    of: 4,
    reason: "transport",
    nextAt: 1_792_000_010_000,
    promptId: "p1",
    turnId: "t1",
  },
};

describe("the adapter reads acpmux's retry", () => {
  test("a waiting retry, null once none waits, undefined when a record does not say", () => {
    expect(readRetry(FIXTURE.subagentRetry)).toEqual(FIXTURE.subagentRetry);
    expect(readRetry(FIXTURE.sessionRetry)).toEqual({
      attempt: 1,
      of: 4,
      reason: "transport",
      nextAt: 1_792_000_010_000,
    });
    expect(readRetry(null)).toBeNull();
    expect(readRetry(undefined)).toBeUndefined();
    expect(readRetry({ attempt: 0, of: 3 })).toBeUndefined();
    expect(readRetry({ attempt: "2", of: 3 })).toBeUndefined();
    // An attempt past `of` never reads "5/4".
    expect(readRetry({ attempt: 5, of: 4 })).toEqual({ attempt: 5, of: 5 });
  });

  test("only a failed or lost one is retrying; a running, finished or stopped one's stale retry is not", () => {
    const retry = { attempt: 1, of: 4 };
    expect(retrying({ parent: null, state: "failed", retry })).toBe(retry);
    expect(retrying({ parent: null, state: "disconnected", retry })).toBe(retry);
    for (const state of ["running", "completed", "cancelled"])
      expect(retrying({ parent: null, state, retry })).toBeUndefined();
    expect(retrying({ parent: "p", state: "failed", retry })).toBeUndefined();
  });

  test("the label names the try, how many, and why", () => {
    expect(retryLabel(translate, FIXTURE.subagentRetry)).toBe("Retrying (2/4) after a capacity error");
    expect(retryLabel(translate, { attempt: 1, of: 3, reason: "transport" })).toBe(
      "Retrying (1/3) after a connection error",
    );
    expect(retryLabel(translate, { attempt: 3, of: 3, reason: "agent_exited" })).toBe(
      "Retrying (3/3) after the agent exited",
    );
    expect(retryLabel(translate, { attempt: 1, of: 3, reason: "something_new" })).toBe("Retrying (1/3)");
  });

  test("the session list's row carries it", () => {
    expect(sessionEntry({ sessionId: "s", retry: FIXTURE.sessionRetry }).retry).toEqual({
      attempt: 1,
      of: 4,
      reason: "transport",
      nextAt: 1_792_000_010_000,
    });
    expect(sessionEntry({ sessionId: "s", retry: null }).retry).toBeUndefined();
  });

  test("a sub-session acpmux refused to retry stays failed and says why", () => {
    const failed = {
      sessionId: "s",
      startedBy: "chat",
      lane: { state: "failed", error: "folder is gone" },
      retry: null,
    };
    expect(subsessionInfo(sessionEntry(failed))).toMatchObject({ state: "failed", error: "folder is gone" });
    const waiting = { ...failed, retry: FIXTURE.sessionRetry };
    expect(subsessionInfo(sessionEntry(waiting)).error).toBeUndefined();
    // One owner says where it stands: retrying, settling (no Retry), failed with its Retry, or, on a
    // row that runs, nothing (a stale retry there says nothing).
    const phase = (entry: Record<string, unknown>) =>
      sessionRetry(subsessionInfo(sessionEntry({ ...failed, ...entry })));
    expect(phase({ retry: FIXTURE.sessionRetry }).kind).toBe("retrying");
    expect(phase({ retryDeciding: true })).toEqual({ kind: "settling" });
    expect(phase({})).toEqual({ kind: "failed" });
    expect(phase({ lane: { state: "working" }, retry: FIXTURE.sessionRetry, retryDeciding: true })).toEqual({
      kind: "none",
    });
  });
});

describe("the fold keeps a subagent's retry", () => {
  let seq = 0;
  const feed = (fold: SubagentFold, update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    return fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
      update,
    );
  };
  const change = (fold: SubagentFold, fields: Record<string, unknown>) =>
    feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", ...fields }] });

  test("a capacity hold survives its fired retry and clears on recovery or a permanent failure", () => {
    for (const terminal of ["running", "completed", "cancelled", "failed"]) {
      const fold = new SubagentFold();
      feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Review" }] });
      change(fold, {
        state: "failed",
        error: "429 no non-exhausted claude accounts available",
        retry: FIXTURE.subagentRetry,
        capacityWait: { reason: "capacity", resumesAt: 1_792_000_060_000 },
      });
      change(fold, { retry: null, capacityWait: { reason: "capacity" } });
      expect(subagentRetry(fold.all()[0]!).kind).toBe("settling");
      expect(retryActionOf(fold.all()[0]!)).toBeUndefined();
      change(fold, {
        state: terminal,
        ...(terminal === "failed" ? { capacityWait: null, error: "401 unauthorized" } : {}),
      });
      const agent = fold.all()[0]!;
      expect(agent.capacityWait).toBeUndefined();
      expect(subagentRetry(agent).kind).toBe(terminal === "failed" ? "failed" : "none");
      if (terminal === "failed") expect(agent.error).toBe("401 unauthorized");
    }
  });

  test("waiting; a cleared wait is not a give-up until acpmux's exhausted step says so", () => {
    const fold = new SubagentFold();
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Push relay" }] });
    change(fold, {
      state: "failed",
      retryable: true,
      error: "503: no non-exhausted\nclaude accounts available",
      retry: { attempt: 1, of: 2, reason: "capacity" },
    });
    expect(fold.all()[0]!.error).toBe("503: no non-exhausted claude accounts available");
    let agent = fold.all()[0]!;
    expect([agent.state, agent.retry, agent.retryable]).toEqual([
      "failed",
      { attempt: 1, of: 2, reason: "capacity" },
      true,
    ]);
    // A progress report that says nothing of the retry keeps it.
    change(fold, { action: "Read relay.ts" });
    expect(fold.all()[0]!.retry?.attempt).toBe(1);
    change(fold, { retry: { attempt: 2, of: 2, reason: "capacity" } });
    // The last wait fires: its retry clears while the attempt runs, and nothing gave up.
    change(fold, { retry: null });
    fold.reduceRetryStep({ subagentId: "a", outcome: "fired", attempt: 2, of: 2, reason: "capacity" });
    agent = fold.all()[0]!;
    expect(agent.retry).toBeUndefined();
    expect(agent.retriedOut).toBeUndefined();
    // A fired attempt reads failed again; its Retry goes to acpmux, which refuses it busy meanwhile.
    expect(retryActionOf(agent)).toBe("daemon");
    // A sub-session's line reads its own session row: acpmux settling its retry offers nothing, and
    // one whose own chat runs again is no failure.
    const sub = { ...agent, child: "s" };
    expect(subagentRetry(sub, undefined, { state: "failed", retryDeciding: true })).toEqual({ kind: "settling" });
    expect(subagentRetry(sub, undefined, { state: "working" })).toEqual({ kind: "none" });
    expect(subagentRetry(sub, new Set([SUBAGENT_RETRY]), { state: "failed" })).toEqual({ kind: "failed" });
    fold.reduceRetryStep({ subagentId: "a", outcome: "exhausted", attempt: 2, of: 2, reason: "capacity" });
    expect(fold.all()[0]!.retriedOut).toEqual({ attempt: 2, of: 2, reason: "capacity" });
    expect(subagentRetry(fold.all()[0]!)).toEqual({
      kind: "failed",
      action: "daemon",
      gaveUp: { attempt: 2, of: 2, reason: "capacity" },
    });
    fold.reduceRetryStep({ subagentId: "a", outcome: "scheduled", attempt: 1, of: 2, reason: "capacity" });
    expect(fold.all()[0]!.retriedOut).toBeUndefined();
  });

  test("the summary card's started-chat rows and counts read it", () => {
    const chat = { sessionId: "s", title: "Push relay", state: "failed" as const, retry: FIXTURE.subagentRetry };
    expect(sessionStatus(chat)).toBe("running");
    expect(sessionStateText(translate, chat, () => true)).toMatchObject({
      text: "Retrying (2/4) after a capacity error",
      working: true,
    });
    // Before the retry has waited the shared bound, the row reads running: the turning ring, no word.
    expect(sessionStateText(translate, chat, () => false)).toMatchObject({ text: "", working: true });
    expect(sessionStatus({ ...chat, state: "idle" })).toBe("done");
  });

  test("a last try that succeeds is no give-up", () => {
    const fold = new SubagentFold();
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Overview" }] });
    change(fold, { state: "failed", retry: { attempt: 2, of: 2, reason: "capacity" } });
    change(fold, { state: "running", retry: null });
    expect(fold.all()[0]!.retriedOut).toBeUndefined();
  });

  test("a retry cleared before its last try is no give-up", () => {
    const fold = new SubagentFold();
    feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Overview" }] });
    change(fold, { state: "failed", retry: { attempt: 1, of: 4, reason: "capacity" } });
    change(fold, { state: "running", retry: null });
    expect(fold.all()[0]!.retriedOut).toBeUndefined();
  });
});

test("acpmux's continuations are recognized; a person's prompt is not", () => {
  expect(isRetryContinuation({ _meta: { provenance: { kind: "auto_resume", attempt: 1, manual: true } } })).toBe(true);
  expect(isRetryContinuation({ _meta: { provenance: { kind: "subagent_retry", subagentId: "a" } } })).toBe(true);
  expect(isRetryContinuation({ _meta: { provenance: { kind: "subagent_resume", subagentId: "a" } } })).toBe(true);
  expect(isRetryContinuation({ _meta: { provenance: { kind: "subsession_message" } } })).toBe(false);
  expect(isRetryContinuation({})).toBe(false);
});

describe("which rows get which Retry", () => {
  const failed: RetryTarget = { id: "a", parent: null, state: "failed" };

  // Leo, 2026-11-14: "we maybe want to remove the "ask parent to retry" if we haven't already".
  test("a Task subagent acpmux can retry goes to acpmux; one it cannot offers no Retry", () => {
    expect(retryActionOf({ ...failed, retryable: true })).toBe("daemon");
    expect(retryActionOf(failed)).toBeUndefined();
    expect(retryActionOf({ ...failed, retryable: false })).toBeUndefined();
    expect(retryActionOf({ ...failed, state: "disconnected", retryable: true })).toBe("daemon");
    expect(subagentRetry(failed)).toEqual({ kind: "failed" });
  });

  test("a sub-session goes to acpmux; another family's shell run offers no Retry", () => {
    expect(retryActionOf({ ...failed, child: "s2" })).toBe("daemon");
    expect(retryActionOf({ ...failed, harness: "codex" })).toBeUndefined();
    expect(retryActionOf({ ...failed, harness: "codex", retryable: true })).toBeUndefined();
  });

  test("no Retry for a finished, running, stopped, nested or already-retrying row", () => {
    expect(retryActionOf({ ...failed, state: "completed" })).toBeUndefined();
    expect(retryActionOf({ ...failed, state: "running" })).toBeUndefined();
    expect(retryActionOf({ ...failed, state: "cancelled" })).toBeUndefined();
    expect(retryActionOf({ ...failed, parent: "b" })).toBeUndefined();
    expect(retryActionOf({ ...failed, retryable: true, retry: { attempt: 1, of: 4 } })).toBeUndefined();
  });

  test('the catalog has no "Ask parent to retry" and none of its prompts', () => {
    for (const key of ["retry.askParent", "retry.ask", "retry.askTask"]) expect(translate(key as never)).toBe(key);
  });
});

describe("Retry reaches acpmux, and only acpmux", () => {
  const failed: RetryTarget = { id: "a", parent: null, state: "failed", retryable: true };
  const deps = (reject?: unknown) => {
    const calls: unknown[] = [];
    return {
      calls,
      request: (method: string, params: Record<string, unknown>) => {
        calls.push([method, params]);
        return reject ? Promise.reject(reject) : Promise.resolve({ promptId: "p", kind: "subagent" });
      },
    };
  };

  test("a subagent's Retry names it to acpmux; a sub-session's names its own session", async () => {
    const CHAT = "c1";
    const d = deps();
    expect(await runRetry(failed, CHAT, d)).toBeUndefined();
    expect(await runRetry({ ...failed, child: "s2" }, CHAT, d)).toBeUndefined();
    expect(d.calls).toEqual([
      [RETRY_METHOD, { sessionId: "c1", subagentId: "a" }],
      [RETRY_METHOD, { sessionId: "s2" }],
    ]);
  });

  test("a daemon without the method, or one that cannot retry a subagent, says Retry failed", async () => {
    const CHAT = "c2";
    const d = deps({ code: -32601 });
    expect(await runRetry(failed, CHAT, d)).toBe("retry.failed");
    expect(d.calls).toHaveLength(1);
    const sub = deps({ code: -32601 });
    expect(await runRetry({ ...failed, child: "s2" }, CHAT, sub)).toBe("retry.failed");
    expect(sub.calls).toHaveLength(1);
    const old = deps({ code: "retry.subagent_unsupported" });
    expect(await runRetry(failed, CHAT, old)).toBe("retry.failed");
    expect(old.calls).toHaveLength(1);
  });

  test("acpmux's refusals are short notes", async () => {
    const CHAT = "c3";
    expect(await runRetry(failed, CHAT, deps({ code: "retry.busy" }))).toBe("retry.busy");
    const d = deps({ code: -32000, reason: "retry.nothing_failed" });
    expect(await runRetry(failed, CHAT, d)).toBe("retry.nothingFailed");
    expect(d.calls).toHaveLength(1);
    expect(await runRetry(failed, CHAT, deps({ code: "native.timed_out" }))).toBe("retry.failed");
  });

  test("runRetry keeps no state: acpmux's busy refusal is the second Retry's answer", async () => {
    const CHAT = "c4";
    const busy = deps({ code: "retry.busy" });
    const other = { ...failed, id: "refused" };
    expect(await runRetry(other, CHAT, busy)).toBe("retry.busy");
    expect(await runRetry(other, CHAT, busy)).toBe("retry.busy");
    expect(busy.calls).toHaveLength(2);
  });

  test("acpmux's capabilities gate the call: named and missing offers no Retry, never probes", async () => {
    const d = { ...deps(), capabilities: new Set(["turn-retry-v1"]) };
    const CHAT = "caps";
    expect(await runRetry(failed, CHAT, d)).toBeUndefined();
    await runRetry({ ...failed, id: "child", child: "s3" }, CHAT, d);
    expect(d.calls).toEqual([[RETRY_METHOD, { sessionId: "s3" }]]);
    const both = { ...deps(), capabilities: new Set(["turn-retry-v1", "subagent-retry-v1"]) };
    await runRetry({ ...failed, id: "sub" }, CHAT, both);
    expect(both.calls).toEqual([[RETRY_METHOD, { sessionId: CHAT, subagentId: "sub" }]]);
  });

  test("a row offers acpmux's Retry only where acpmux names it", () => {
    const turnOnly = new Set(["turn-retry-v1"]);
    expect(retryActionOf({ ...failed, retryable: true }, turnOnly)).toBeUndefined();
    expect(retryActionOf({ ...failed, child: "s" }, turnOnly)).toBe("daemon");
    // Only acpmux retries a chat's turn: without TURN_RETRY a sub-session offers no Retry.
    expect(retryActionOf({ ...failed, child: "s" }, new Set())).toBeUndefined();
    expect(retryActionOf({ ...failed, retryable: true }, undefined)).toBe("daemon");
  });

  test("a refusal's why reads in words", async () => {
    const why = (w: string) => ({ code: -32000, reason: "retry.nothing_failed", data: { why: w } });
    expect(await runRetry({ ...failed, id: "w1" }, "why", deps(why("running")))).toBe("retry.running");
    expect(await runRetry({ ...failed, id: "w2" }, "why", deps(why("closed")))).toBe("retry.gone");
    expect(await runRetry({ ...failed, id: "w3" }, "why", deps(why("not_retryable")))).toBe("retry.nothingFailed");
    expect(await runRetry({ ...failed, id: "w4" }, "why", deps({ code: "retry.stopped" }))).toBe("retry.gone");
  });

  test("a Retry the pane can no longer reach is refused with a note, never taken as sent", async () => {
    const CHAT = "c6";
    // The pane moved to another chat, or reconnects: nothing is sent, and the row says so.
    const away = { ...deps(), reaches: () => false };
    expect(await runRetry(failed, CHAT, away)).toBe("retry.failed");
    expect(away.calls).toEqual([]);
  });

  test("a row acpmux can't retry, or with no Retry, does nothing", async () => {
    const CHAT = "c5";
    const d = deps();
    expect(await runRetry({ ...failed, retryable: false }, CHAT, d)).toBeUndefined();
    expect(await runRetry({ ...failed, state: "completed" }, CHAT, d)).toBeUndefined();
    expect(d.calls).toEqual([]);
  });

  test("the strings are in the catalog", () => {
    for (const key of ["retry.busy", "retry.nothingFailed", "retry.failed", "retry.running", "retry.gone"] as const)
      expect(translate(key)).not.toBe(key);
  });
});

describe("a Retry acpmux refuses as busy is asked again on its own", () => {
  const fast = { firstMs: 1, maxMs: 2, random: () => 0, visible: () => true };

  test("it asks until acpmux takes it, and answers what acpmux said then", async () => {
    const answers: (RetryNote | undefined)[] = ["retry.busy", "retry.busy", undefined];
    let asked = 0;
    const { answer } = untilNotBusy(async () => answers[asked++], fast);
    expect(await answer).toBeUndefined();
    expect(asked).toBe(3);
  });

  test("any other refusal ends the wait with its note", async () => {
    let asked = 0;
    const { answer } = untilNotBusy(async () => (asked++ === 0 ? "retry.busy" : "retry.gone"), fast);
    expect(await answer).toBe("retry.gone");
    expect(asked).toBe(2);
  });

  test("stop ends the wait: nothing more is asked", async () => {
    // The backoff spacing is the behavior: fake timers step it instead of the wall clock.
    jest.useFakeTimers();
    try {
      let asked = 0;
      const { stop } = untilNotBusy(async () => {
        asked++;
        return "retry.busy";
      }, fast);
      const settle = async () => {
        for (let turn = 0; turn < 10; turn++) await Promise.resolve();
      };
      for (let step = 0; step < 5; step++) {
        await settle();
        jest.advanceTimersByTime(fast.maxMs);
      }
      await settle();
      expect(asked).toBeGreaterThan(1);
      stop();
      const seen = asked;
      for (let step = 0; step < 10; step++) {
        jest.advanceTimersByTime(fast.maxMs * 10);
        await settle();
      }
      expect(asked).toBe(seen);
    } finally {
      jest.useRealTimers();
    }
  });
});
