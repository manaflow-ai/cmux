// l10n-allow-file: test fixture subagent names, not shipped UI.
// The subagent surfaces of acpmux's retry (Leo 2026-10-26: "this needs to retry :("): the running
// tray and the end line's words, read from retryState.ts's one owner.
import { describe, expect, test } from "bun:test";
import { translate } from "../i18n";
import { retryKey } from "./retryState";
import { finishedTrayItems, trayItems } from "./runningTray";
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
  test("shows what acpmux retries with the running ones, never among the finished", () => {
    const agents = failedAgent({ retry: RETRY });
    expect(trayItems(agents, [], [], false).map((item) => item.id)).toEqual(["a"]);
    expect(finishedTrayItems(agents, [])).toEqual([]);
    const chat = { sessionId: "s", title: "Push relay", state: "failed" as const, retry: RETRY };
    expect(trayItems([], [], [chat], false).map((item) => item.id)).toEqual(["s"]);
    expect(finishedTrayItems([], [chat])).toEqual([]);
  });

  test("a failed one nothing retries is finished", () => {
    const agents = failedAgent({ retryable: true });
    expect(trayItems(agents, [], [], false)).toEqual([]);
    expect(finishedTrayItems(agents, []).map((item) => item.id)).toEqual(["a"]);
  });
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
  for (const key of ["retry.action", "retry.askParent", "retry.menu"] as const) expect(translate(key)).not.toBe(key);
  expect(translate("retry.retriedOut", { of: 4 })).toBe("gave up after 4 tries");
  expect(translate("retry.action")).toBe("Retry");
  expect(translate("retry.askParent")).toBe("Ask parent to retry");
});
