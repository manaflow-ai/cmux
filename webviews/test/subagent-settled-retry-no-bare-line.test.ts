// l10n-allow-file: recorded subagent and transcript fixtures.
// cmux#52916: after a daemon restart, two "Subagent  Failed" lines (0s, no reason) appeared under a
// reply. acpmux's restart settles each subagent retry it left open (`settle_subagent_retries`) with
// one more entry, `{id, state: "failed", agentId, retryable: false}`: no name, no error, and only
// the record's `_acpmuxRecovery` mark saying recovery wrote it. The pane had not read those
// subagents' spawns (an older page), so the fold met them first there and drew a nameless line
// that started and ended at that one event. These are the records of that chat (claude-sr2-260,
// seq 96661 and 96662), trimmed.
import { expect, test } from "bun:test";
import { SubagentFold } from "../src/agent-session/acpmux/subagents/subagentFold";
import { withSubagentLines, type DoneLineCache } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "01a20715-796a-720e-b116-7af26af4b742";
const LAPTOP = `${CHAT}/toolu_01AvHhv1UknUxmTIqWRx93dH`;
const JOURNEY = `${CHAT}/toolu_01K3vRvQRBDJ7XTT8EM1sdpF`;
const ERROR =
  "Agent terminated early due to an API error: API Error: Repeated 529 Overloaded errors. The API is at capacity.";

function feeder() {
  const fold = new SubagentFold();
  const groups = new Map<string, AcpmuxRow>();
  let seq = 0;
  const feed = (
    at: number,
    sessionUpdate: string,
    subagents: Record<string, unknown>[],
    extra: Record<string, unknown> = {},
  ) => {
    seq += 1;
    const update = { sessionUpdate };
    fold.reduce(
      {
        seq,
        at,
        msg: {
          method: "session/update",
          ...extra,
          params: { update, _meta: { acpmux: { subagents } } },
        },
      },
      update,
    );
    for (const group of fold.takeRows()) groups.set(group.id, group);
  };
  return { fold, groups, feed };
}

const settle = (id: string, agentId: string) => ({
  agentId,
  id,
  parent: null,
  retry: null,
  retryInFlight: null,
  retryable: false,
  state: "failed",
});

const doneLines = (rows: readonly AcpmuxRow[]) => rows.filter((entry) => entry.kind === SUBAGENT_DONE);

test("a restart's retry settle of a subagent whose spawn is on a page not loaded draws no line", () => {
  const { fold, groups, feed } = feeder();
  const at = 1_795_468_040_829;
  // An older acpmux's settle: only the record's recovery mark says it is after the fact.
  feed(at, "subagent_state_update", [settle(LAPTOP, "add483bc55fb3da4d")], {
    _acpmuxRecovery: true,
  });
  feed(at + 2, "subagent_state_update", [settle(JOURNEY, "a1c94e6b50cb40c7c")], {
    _acpmuxRecovery: true,
  });
  expect(fold.all()).toHaveLength(0);
  const rows = [
    {
      id: "reply",
      kind: "assistant",
      at: at - 1,
      version: 1,
      text: "Review Auto app and phone finished",
    },
    ...groups.values(),
  ] as AcpmuxRow[];
  expect(doneLines(withSubagentLines(rows, new Map() as DoneLineCache))).toHaveLength(0);
});

test("a bare end that names nothing draws no line even without the recovery mark", () => {
  // A live retry entry acpmux logged hours after the spawn, which the loaded window starts after.
  const { fold, feed } = feeder();
  feed(1_795_461_104_905, "subagent_state_update", [
    {
      ...settle(JOURNEY, "a1c94e6b50cb40c7c"),
      retryable: true,
      retry: { attempt: 4, of: 4, reason: "capacity" },
    },
  ]);
  expect(fold.all()).toHaveLength(0);
});

test("a settle that names its subagent and failure (acpmux now) still draws nothing it never met", () => {
  const { fold, feed } = feeder();
  feed(1_000, "subagent_state_update", [
    {
      ...settle(LAPTOP, "add483bc55fb3da4d"),
      recovered: true,
      task: "Auto mode laptop daemon",
      error: ERROR,
    },
  ]);
  expect(fold.all()).toHaveLength(0);
});

test("an end that names its subagent still draws, named, where the spawn is not loaded", () => {
  const { fold, feed } = feeder();
  feed(5_000, "subagent_state_update", [
    {
      ...settle(LAPTOP, "add483bc55fb3da4d"),
      retryable: true,
      name: "Auto mode laptop daemon",
      error: ERROR,
    },
  ]);
  const agent = fold.all().find((entry) => entry.id === LAPTOP);
  expect(agent?.name).toBe("Auto mode laptop daemon");
  expect(agent?.error).toContain("529");
});

test("a settle of a subagent the fold read keeps its line, named, with nothing left to retry", () => {
  const { fold, feed } = feeder();
  feed(1_000, "subagent_spawned", [
    {
      id: LAPTOP,
      parent: null,
      name: "Auto mode laptop daemon",
      state: "running",
      toolCallId: "toolu_01AvHhv1",
    },
  ]);
  feed(9_000, "subagent_state_update", [
    {
      id: LAPTOP,
      agentId: "add483bc55fb3da4d",
      state: "failed",
      error: ERROR,
      retryable: true,
      retry: { attempt: 1, of: 4, nextAt: 20_000, reason: "capacity" },
    },
  ]);
  feed(3_600_000, "subagent_state_update", [settle(LAPTOP, "add483bc55fb3da4d")], {
    _acpmuxRecovery: true,
  });
  const agent = fold.all().find((entry) => entry.id === LAPTOP)!;
  expect(agent).toMatchObject({ name: "Auto mode laptop daemon", state: "failed", endedAt: 9_000 });
  expect(agent.retry).toBeUndefined();
  expect(agent.retryable).toBe(false);
});

test("a nameless harness end that carries its failure still draws where the spawn is not loaded", () => {
  // The translator forgot the task (a restart between spawn and end): the end names only its error.
  const { fold, feed } = feeder();
  feed(7_000, "subagent_state_update", [{ id: LAPTOP, parent: null, state: "failed", error: ERROR }]);
  const agent = fold.all().find((entry) => entry.id === LAPTOP);
  expect(agent?.state).toBe("failed");
  expect(agent?.error).toContain("529");
});

test("a nameless completed end with a result still draws where the spawn is not loaded", () => {
  const { fold, feed } = feeder();
  feed(7_000, "subagent_state_update", [{ id: JOURNEY, parent: null, state: "completed", result: "Done." }]);
  expect(fold.all().find((entry) => entry.id === JOURNEY)?.state).toBe("completed");
});
