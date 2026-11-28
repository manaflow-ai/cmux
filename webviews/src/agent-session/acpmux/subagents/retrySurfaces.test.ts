// l10n-allow-file: test fixture subagent names, not shipped UI.
// The subagent surfaces of acpmux's retry (Leo 2026-10-26: "this needs to retry :("): the running
// tray and the end line's words, read from retryState.ts's one owner.
import { describe, expect, test } from "bun:test";
import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { retryKey } from "./retryState";
import { finishedTrayItems, trayItems, withSubagentLines, type DoneLineCache } from "./runningTray";
import { SubagentFold } from "./subagentFold";

const RETRY = { attempt: 2, of: 4, reason: "capacity", nextAt: 1_792_000_060_000 };

let seq = 0;
const feed = (fold: SubagentFold, update: any, acpmux: Record<string, unknown>) => {
  seq += 1;
  return fold.reduce(
    { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
    update,
  );
};
const failedAgent = (fields: Record<string, unknown>) => {
  const fold = new SubagentFold();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Overview" }] });
  feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "failed", ...fields }] });
  return fold.all();
};

describe("the running tray", () => {
  test("capacity holds stay in their transcript group, not repeated in the live or finished tray", () => {
    for (const retry of [RETRY, null]) {
      const agents = failedAgent({ retry, capacityWait: { reason: "capacity", resumesAt: RETRY.nextAt } });
      expect(trayItems(agents, [], [], false)).toEqual([]);
      expect(finishedTrayItems(agents, [])).toEqual([]);
    }
  });
  test("shows what acpmux retries with the running ones, never among the finished", () => {
    const agents = failedAgent({ retry: RETRY });
    expect(trayItems(agents, [], [], false).map((item) => item.id)).toEqual(["a"]);
    expect(finishedTrayItems(agents, [])).toEqual([]);
    const chat = { sessionId: "s", title: "Push relay", state: "failed" as const, retry: RETRY, subsession: true };
    expect(trayItems([], [], [chat], false).map((item) => item.id)).toEqual(["s"]);
    expect(finishedTrayItems([], [chat])).toEqual([]);
  });

  test("a sub-session's retry, kept on its own session row, shows it with the running ones", () => {
    const [failed] = failedAgent({});
    const agents = [{ ...failed!, child: "c" }];
    const child = { sessionId: "c", title: "Overview", state: "failed" as const, retry: RETRY, subsession: true };
    const agentIds = (items: { kind: string; id: string }[]) =>
      items.filter((item) => item.kind === "agent").map((item) => item.id);
    const [item] = trayItems(agents, [], [child], false);
    expect(item?.kind === "agent" && item.agent.retry).toEqual(RETRY);
    expect(agentIds(trayItems(agents, [], [child], false))).toEqual(["a"]);
    expect(agentIds(finishedTrayItems(agents, [child]))).toEqual([]);
    // Once its chat runs again, or nothing retries it, its stale retry says nothing.
    const done = { ...child, retry: undefined };
    expect(agentIds(trayItems(agents, [], [done], false))).toEqual([]);
    expect(agentIds(finishedTrayItems(agents, [done]))).toEqual(["a"]);
  });

  test("a failed one nothing retries is finished", () => {
    const agents = failedAgent({ retryable: true });
    expect(trayItems(agents, [], [], false)).toEqual([]);
    expect(finishedTrayItems(agents, []).map((item) => item.id)).toEqual(["a"]);
  });
});

test("one cached start line transitions from finished to capacity-paused and back without duplicate rows", () => {
  const fold = new SubagentFold();
  const cache: DoneLineCache = new Map();
  feed(fold, { sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Overview" }] });
  const update = (fields: Record<string, unknown>) => {
    feed(fold, { sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", ...fields }] });
    const group: AcpmuxRow = { id: "helpers", kind: "subagents", version: seq, at: 1, subagents: [...fold.all()] };
    return withSubagentLines([group], cache);
  };

  const completed = update({ state: "completed" });
  expect(completed.map((row) => row.kind)).toEqual(["subagentStarted", "subagentDone"]);
  expect(completed[0]!.startedAllEnded).toBe(true);

  // Leo: "Keep one capacity indicator, not three." The same cache must drop the finished label
  // and the done line, while neither live nor finished trays repeat the transcript's held row.
  const paused = update({
    state: "failed",
    retry: RETRY,
    capacityWait: { reason: "capacity", resumesAt: RETRY.nextAt },
  });
  expect(paused.map((row) => row.kind)).toEqual(["subagentStarted"]);
  expect(paused[0]).not.toBe(completed[0]);
  expect(paused[0]!.startedAllEnded).toBeUndefined();
  for (const working of [false, true]) expect(trayItems(fold.all(), [], [], working)).toEqual([]);
  expect(finishedTrayItems(fold.all(), [])).toEqual([]);

  // A new provider deadline must also refresh the held row even though allEnded stays false.
  const later = RETRY.nextAt + 60_000;
  const extended = update({ capacityWait: { reason: "capacity", resumesAt: later } });
  expect(extended).toHaveLength(1);
  expect(extended[0]).not.toBe(paused[0]);
  expect(extended[0]!.subagents![0]!.capacityWait?.resumesAt).toBe(later);
  expect(extended[0]!.startedAllEnded).toBeUndefined();

  const recovered = update({ state: "completed", retry: null, capacityWait: null });
  expect(recovered.map((row) => row.kind)).toEqual(["subagentStarted", "subagentDone"]);
  expect(recovered[0]).not.toBe(extended[0]);
  expect(recovered[0]!.startedAllEnded).toBe(true);
  expect(recovered[0]!.subagents![0]!.capacityWait).toBeUndefined();
});

test("a change to any retry field redraws the line (its cache key)", () => {
  const [agent] = failedAgent({ retryable: true });
  const keys = new Set([
    retryKey(agent!),
    retryKey({ ...agent!, retry: RETRY }),
    retryKey({ ...agent!, retriedOut: { attempt: 4, of: 4 } }),
    retryKey({ ...agent!, retryable: false }),
    retryKey({ ...agent!, error: "503" }),
  ]);
  expect(keys.size).toBe(5);
});

test("the line's strings are in the catalog", () => {
  for (const key of ["retry.action", "retry.menu"] as const) expect(translate(key)).not.toBe(key);
  expect(translate("retry.retriedOut", { of: 4 })).toBe("gave up after 4 tries");
  expect(translate("retry.action")).toBe("Retry");
});
