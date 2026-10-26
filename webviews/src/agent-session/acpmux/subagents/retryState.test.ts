// l10n-allow-file: test fixture subagent names and tasks, not shipped UI.
import { describe, expect, test } from "bun:test";
import { translate } from "../i18n";
import { sessionEntry } from "../sessionList";
import { SubagentFold } from "./subagentFold";
import { subsessionInfo } from "./subsessions";
import {
  askPrompt,
  isRetryContinuation,
  readRetry,
  retryActionOf,
  retrying,
  retryLabel,
  RETRY_METHOD,
  runRetry,
  type RetryTarget,
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
    expect(retrying({ state: "failed", retry })).toBe(retry);
    expect(retrying({ state: "disconnected", retry })).toBe(retry);
    for (const state of ["running", "completed", "cancelled"]) expect(retrying({ state, retry })).toBeUndefined();
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

  test("waiting, then retried out once acpmux clears the last try while it still failed", () => {
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
    change(fold, { retry: null });
    agent = fold.all()[0]!;
    expect(agent.retry).toBeUndefined();
    expect(agent.retriedOut).toEqual({ attempt: 2, of: 2, reason: "capacity" });
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
  expect(isRetryContinuation({ _meta: { provenance: { kind: "subsession_message" } } })).toBe(false);
  expect(isRetryContinuation({})).toBe(false);
});

describe("which rows get which Retry", () => {
  const failed: RetryTarget = {
    id: "a",
    parent: null,
    name: "Push relay",
    task: "Push relay for GCP lane bundles",
    state: "failed",
  };

  test("a Task subagent acpmux can retry goes to acpmux; one it cannot is asked of the parent", () => {
    expect(retryActionOf({ ...failed, retryable: true })).toBe("daemon");
    expect(retryActionOf(failed)).toBe("ask");
    expect(retryActionOf({ ...failed, retryable: false })).toBe("ask");
    expect(retryActionOf({ ...failed, state: "disconnected", retryable: true })).toBe("daemon");
  });

  test("a sub-session goes to acpmux; another family's shell run is asked of the parent", () => {
    expect(retryActionOf({ ...failed, child: "s2" })).toBe("daemon");
    expect(retryActionOf({ ...failed, harness: "codex" })).toBe("ask");
  });

  test("no Retry for a finished, running, stopped, nested or already-retrying row", () => {
    expect(retryActionOf({ ...failed, state: "completed" })).toBeUndefined();
    expect(retryActionOf({ ...failed, state: "running" })).toBeUndefined();
    expect(retryActionOf({ ...failed, state: "cancelled" })).toBeUndefined();
    expect(retryActionOf({ ...failed, parent: "b" })).toBeUndefined();
    expect(retryActionOf({ ...failed, retryable: true, retry: { attempt: 1, of: 4 } })).toBeUndefined();
  });

  test("the ask names the failed task and its description in one line", () => {
    expect(askPrompt(failed, translate)).toBe(
      'The subagent "Push relay" (Push relay for GCP lane bundles) failed on a transient error. Run it again.',
    );
    expect(askPrompt({ ...failed, task: "Push relay" }, translate)).toBe(
      'The subagent "Push relay" failed on a transient error. Run it again.',
    );
    expect(askPrompt({ ...failed, task: "Push relay\nfor GCP\n\nlane bundles" }, translate)).toBe(
      'The subagent "Push relay" (Push relay for GCP lane bundles) failed on a transient error. Run it again.',
    );
    expect(askPrompt({ ...failed, child: "s2" }, translate)).toBe(
      'The sub-session "Push relay" failed on a transient error. Send it its last prompt again.',
    );
  });
});

describe("Retry reaches acpmux, else the parent", () => {
  const failed: RetryTarget = { id: "a", parent: null, name: "Overview", state: "failed", retryable: true };
  const deps = (reject?: unknown) => {
    const calls: unknown[] = [];
    return {
      calls,
      request: (method: string, params: Record<string, unknown>) => {
        calls.push([method, params]);
        return reject ? Promise.reject(reject) : Promise.resolve({ promptId: "p", kind: "subagent" });
      },
      send: (text: string) => {
        calls.push(["send", text]);
        return Promise.resolve();
      },
    };
  };

  test("a subagent's Retry names it to acpmux; a sub-session's names its own session", async () => {
    const CHAT = "c1";
    const d = deps();
    expect(await runRetry(failed, CHAT, d, translate)).toBeUndefined();
    expect(await runRetry({ ...failed, child: "s2" }, CHAT, d, translate)).toBeUndefined();
    expect(d.calls).toEqual([
      [RETRY_METHOD, { sessionId: "c1", subagentId: "a" }],
      [RETRY_METHOD, { sessionId: "s2" }],
    ]);
  });

  test("a daemon without the method falls back to the ask", async () => {
    const CHAT = "c2";
    const d = deps({ code: -32601 });
    expect(await runRetry(failed, CHAT, d, translate)).toBeUndefined();
    expect(d.calls[1]).toEqual(["send", 'The subagent "Overview" failed on a transient error. Run it again.']);
  });

  test("acpmux's refusals are short notes, never an ask", async () => {
    const CHAT = "c3";
    expect(await runRetry(failed, CHAT, deps({ code: "retry.busy" }), translate)).toBe("retry.busy");
    const d = deps({ code: -32000, reason: "retry.nothing_failed" });
    expect(await runRetry(failed, CHAT, d, translate)).toBe("retry.nothingFailed");
    expect(d.calls).toHaveLength(1);
    expect(await runRetry(failed, CHAT, deps({ code: "native.timed_out" }), translate)).toBe("retry.failed");
  });

  test("a second Retry of the same target before acpmux answers does nothing; a refusal frees it", async () => {
    const CHAT = "c4";
    const d = deps();
    const target = { ...failed, id: "twice", child: "s9" };
    await runRetry(target, CHAT, d, translate);
    // The line and the card both offer it.
    await runRetry(target, CHAT, d, translate);
    expect(d.calls).toHaveLength(1);
    const busy = deps({ code: "retry.busy" });
    const other = { ...failed, id: "refused" };
    expect(await runRetry(other, CHAT, busy, translate)).toBe("retry.busy");
    expect(await runRetry(other, CHAT, busy, translate)).toBe("retry.busy");
    expect(busy.calls).toHaveLength(2);
  });

  test("acpmux's capabilities gate the call: named and missing asks the parent, never probes", async () => {
    const d = { ...deps(), capabilities: new Set(["turn-retry-v1"]) };
    const CHAT = "caps";
    await runRetry(failed, CHAT, d, translate);
    await runRetry({ ...failed, id: "child", child: "s3" }, CHAT, d, translate);
    expect(d.calls.map((call) => (call as unknown[])[0])).toEqual(["send", RETRY_METHOD]);
    const both = { ...deps(), capabilities: new Set(["turn-retry-v1", "subagent-retry-v1"]) };
    await runRetry({ ...failed, id: "sub" }, CHAT, both, translate);
    expect(both.calls).toEqual([[RETRY_METHOD, { sessionId: CHAT, subagentId: "sub" }]]);
  });

  test("a refusal's why reads in words; subagent_unsupported asks the parent", async () => {
    const why = (w: string) => ({ code: -32000, reason: "retry.nothing_failed", data: { why: w } });
    expect(await runRetry({ ...failed, id: "w1" }, "why", deps(why("running")), translate)).toBe("retry.running");
    expect(await runRetry({ ...failed, id: "w2" }, "why", deps(why("closed")), translate)).toBe("retry.gone");
    expect(await runRetry({ ...failed, id: "w3" }, "why", deps(why("not_retryable")), translate)).toBe(
      "retry.nothingFailed",
    );
    expect(await runRetry({ ...failed, id: "w4" }, "why", deps({ code: "retry.stopped" }), translate)).toBe(
      "retry.gone",
    );
    const old = deps({ code: "retry.subagent_unsupported" });
    expect(await runRetry({ ...failed, id: "w5" }, "why", old, translate)).toBeUndefined();
    expect((old.calls[1] as unknown[])[0]).toBe("send");
  });

  test("Ask parent to retry asks at once; a row with no Retry does nothing", async () => {
    const CHAT = "c5";
    const d = deps();
    await runRetry(failed, CHAT, d, translate, "ask");
    expect(d.calls.map((call) => (call as unknown[])[0])).toEqual(["send"]);
    expect(await runRetry({ ...failed, state: "completed" }, CHAT, d, translate)).toBeUndefined();
    expect(d.calls).toHaveLength(1);
  });

  test("the strings are in the catalog", () => {
    for (const key of [
      "retry.action",
      "retry.askParent",
      "retry.menu",
      "retry.busy",
      "retry.nothingFailed",
      "retry.failed",
      "retry.running",
      "retry.gone",
    ] as const)
      expect(translate(key)).not.toBe(key);
    expect(translate("retry.retriedOut", { of: 4 })).toBe("gave up after 4 tries");
    expect(translate("retry.action")).toBe("Retry");
    expect(translate("retry.askParent")).toBe("Ask parent to retry");
  });
});
