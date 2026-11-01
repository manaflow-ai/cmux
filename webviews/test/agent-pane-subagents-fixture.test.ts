// `debug.agent_pane seed_rows` with `fixture: "subagents"` walks the subagent tray through its life
// in the real app (subagentsFixture.ts), one step per call, so a capture mini can record the tray
// easing in, ticking and leaving beside a received message. What each step puts in the tray, read
// through the tray's own lists (subagents/runningTray.ts) as App.tsx reads them between turns.
import { expect, test } from "bun:test";
import {
  SUBAGENT_FIXTURE_MAX,
  SUBAGENT_TRAY_STEPS,
  subagentTrayRows,
} from "../src/agent-session/acpmux/subagentsFixture";
import { finishedTrayItems, trayItems } from "../src/agent-session/acpmux/subagents/runningTray";
import { subagentsIn } from "../src/agent-session/acpmux/subagents/subagentRows";

const AT = Date.UTC(2026, 9, 28, 9);

const tray = (step: number, count?: number) => {
  const rows = subagentTrayRows(step, AT, count);
  const agents = [...subagentsIn(rows).values()];
  return {
    rows,
    running: trayItems(agents, [], [], false).map((item) => item.id),
    finished: finishedTrayItems(agents, []).map((item) => item.id),
    messages: rows.filter((row) => row.kind === "user" && row.incoming?.kind === "message").length,
  };
};

test("each step puts in the tray what the capture records, beside the message from step 2", () => {
  expect(SUBAGENT_TRAY_STEPS).toBe(6);
  const steps = Array.from({ length: SUBAGENT_TRAY_STEPS }, (_, step) => tray(step));
  expect(steps.map(({ running }) => running)).toEqual([
    [],
    ["fixture-reviewer", "fixture-auditor"],
    ["fixture-reviewer", "fixture-auditor"],
    ["fixture-auditor"],
    [],
    [],
  ]);
  expect(steps.map(({ finished }) => finished)).toEqual([
    [],
    [],
    [],
    ["fixture-reviewer"],
    ["fixture-auditor", "fixture-reviewer"],
    [],
  ]);
  expect(steps.map(({ messages }) => messages)).toEqual([0, 0, 1, 1, 1, 1]);
});

test("the steps keep their rows' ids and times; the group's version moves with its subagents", () => {
  const first = subagentTrayRows(1, AT);
  const later = subagentTrayRows(3, AT);
  for (const row of first) {
    const same = later.find((other) => other.id === row.id)!;
    expect(same.at).toBe(row.at);
  }
  const group = (rows: typeof first) => rows.find((row) => row.id === "subagents-group")!;
  expect(group(later).version).toBeGreaterThan(group(first).version);
});

// `agents` lets a capture open 3 or more subagents' panes (design/pane-placement.md): past the
// reviewer and the auditor, helpers that run through every step. Unset, the fixture is unchanged.
test("agents starts that many running subagents; unset it starts the reviewer and the auditor", () => {
  expect(tray(1, 4).running).toEqual(["fixture-reviewer", "fixture-auditor", "fixture-helper-1", "fixture-helper-2"]);
  expect(tray(1).running).toEqual(tray(1, 2).running);
  expect(tray(4, 4).running).toEqual(["fixture-helper-1", "fixture-helper-2"]);
  expect(tray(1, 1).running).toHaveLength(2);
  expect(tray(1, 99).running).toHaveLength(SUBAGENT_FIXTURE_MAX);
  expect(tray(5, 4).running).toEqual([]);
});
