// l10n-allow-file: recorded subagent and transcript fixtures.
// An end acpmux wrote after the fact (acpmux `subagents::expiry`: a daemon rebuilding a chat after a
// restart, a harness gone, a long silence) is history. Leo, 2026-11-22, after a restart showed 20+
// "Subagent disconnected: <old subagent>" lines and a start line of empty pills in his live turn:
// "and more bullshit somehow happened here".
import { expect, test } from "bun:test";
import { SubagentFold } from "../src/agent-session/acpmux/subagents/subagentFold";
import { withSubagentLines, type DoneLineCache } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_DONE, SUBAGENT_STARTED } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const row = (id: string, kind: string, at: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  at,
  version: 1,
  ...fields,
});

/// A chat whose subagent ran from 1 s to 3 s, a reply at 10 s, a new turn at 1 h, and the daemon's
/// recovered end appended at 1 h 1 s (after the restart).
function chat(end: Record<string, unknown>, others: Record<string, unknown>[] = []) {
  const fold = new SubagentFold();
  const groups = new Map<string, AcpmuxRow>();
  let seq = 0;
  const feed = (at: number, sessionUpdate: string, subagents: Record<string, unknown>[]) => {
    seq += 1;
    const update = { sessionUpdate };
    fold.reduce(
      { seq, at, msg: { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } } },
      update,
    );
    for (const group of fold.takeRows()) groups.set(group.id, group);
  };
  feed(1_000, "subagent_spawned", [
    { id: "old", parent: null, name: "Explore", task: "Explore the daemon", state: "running" },
  ]);
  feed(3_000, "subagent_progress", [{ id: "old", tokens: 120, toolUses: 3 }]);
  const restart = 3_600_000;
  feed(restart + 1_000, "subagent_state_update", [{ id: "old", ...end }, ...others]);
  const rows = [
    row("prompt", "user", 0, { text: "Look at the daemon" }),
    ...groups.values(),
    row("answer", "assistant", 10_000, { text: "Done.", assistantPhase: "final_answer" }),
    row("prompt-2", "user", restart, { text: "Next thing" }),
    row("live", "assistant", restart + 2_000, { text: "Working on it" }),
  ];
  return { fold, rows };
}

const doneLines = (rows: readonly AcpmuxRow[]) => rows.filter((entry) => entry.kind === SUBAGENT_DONE);
const indexOf = (rows: readonly AcpmuxRow[], id: string) => rows.findIndex((entry) => entry.id === id);

test("an end an older acpmux recovered (no time on it) ends the run where it was last heard, not in the live turn", () => {
  const { fold, rows } = chat({ state: "disconnected", reason: "harness_exit" });
  const agent = fold.all().find((entry) => entry.id === "old")!;
  expect(agent.state).toBe("disconnected");
  expect(agent.endedAt).toBe(3_000);
  const drawn = withSubagentLines(rows, new Map() as DoneLineCache);
  const line = drawn.findIndex((entry) => entry.kind === SUBAGENT_DONE);
  expect(line).toBeGreaterThan(-1);
  expect(line).toBeLessThan(indexOf(drawn, "answer"));
  expect(line).toBeLessThan(indexOf(drawn, "prompt-2"));
});

test("a recovered end with acpmux's times and true state reads them", () => {
  const { fold, rows } = chat({
    state: "completed",
    reason: "harness_exit",
    recovered: true,
    endedAt: 4_000,
    startedAt: 900,
  });
  const agent = fold.all().find((entry) => entry.id === "old")!;
  expect(agent).toMatchObject({ state: "completed", startedAt: 900, endedAt: 4_000 });
  const drawn = withSubagentLines(rows, new Map() as DoneLineCache);
  expect(doneLines(drawn)).toHaveLength(1);
  expect(drawn.findIndex((entry) => entry.kind === SUBAGENT_DONE)).toBeLessThan(indexOf(drawn, "answer"));
});

test("a recovered disconnected end of a run whose result the chat had is a finish", () => {
  const fold = new SubagentFold();
  let seq = 0;
  const feed = (at: number, sessionUpdate: string, subagents: Record<string, unknown>[]) => {
    seq += 1;
    const update = { sessionUpdate };
    fold.reduce(
      { seq, at, msg: { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } } },
      update,
    );
  };
  feed(1_000, "subagent_spawned", [{ id: "a", parent: null, name: "A", state: "running", toolCallId: "call-a" }]);
  feed(1_000, "subagent_spawned", [{ id: "b", parent: null, name: "B", state: "running", toolCallId: "call-b" }]);
  // The chat weighed a's task notification (its end reached the parent), but an older acpmux never
  // matched it to the spawn: a still read as running until the daemon's recovered end.
  fold.react("call-a", { turn: "t", weight: "result" });
  feed(9_000_000, "subagent_state_update", [
    { id: "a", state: "disconnected", reason: "harness_exit" },
    { id: "b", state: "disconnected", reason: "harness_exit" },
  ]);
  expect(fold.all().map(({ id, state }) => [id, state])).toEqual([
    ["a", "completed"],
    ["b", "disconnected"],
  ]);
});

test("a recovered end never overrides an end the harness gave live", () => {
  const fold = new SubagentFold();
  let seq = 0;
  const feed = (at: number, sessionUpdate: string, subagents: Record<string, unknown>[]) => {
    seq += 1;
    const update = { sessionUpdate };
    fold.reduce(
      { seq, at, msg: { method: "session/update", params: { update, _meta: { acpmux: { subagents } } } } },
      update,
    );
  };
  feed(1_000, "subagent_spawned", [{ id: "a", parent: null, name: "A", state: "running" }]);
  feed(5_000, "subagent_state_update", [{ id: "a", state: "completed" }]);
  feed(9_000_000, "subagent_state_update", [{ id: "a", state: "disconnected", reason: "harness_exit" }]);
  expect(fold.all()[0]).toMatchObject({ state: "completed", endedAt: 5_000 });
});

test("recovered ends of runs older than the loaded window draw nothing: no group, no start line, no burst", () => {
  const old = Array.from({ length: 24 }, (_, index) => ({
    id: `paged-${index}`,
    name: `Old helper ${index}`,
    state: "disconnected",
    reason: "harness_exit",
  }));
  const { fold, rows } = chat({ state: "disconnected", reason: "harness_exit" }, old);
  expect(fold.all().map((agent) => agent.id)).toEqual(["old"]);
  const drawn = withSubagentLines(rows, new Map() as DoneLineCache);
  expect(drawn.filter((entry) => entry.kind === SUBAGENT_STARTED)).toHaveLength(1);
  expect(doneLines(drawn)).toHaveLength(1);
  const live = indexOf(drawn, "prompt-2");
  expect(drawn.slice(live).some((entry) => entry.kind === SUBAGENT_DONE || entry.kind === SUBAGENT_STARTED)).toBe(
    false,
  );
});
