// The agent's reply right before a person's steer is that segment's end-of-turn reply, so it stays in
// sight wherever the turn's runs fold (Leo, 2026-10-31: "the delineation is between
// end-of-turn-that-had-a-steer-between vs otherwise"). A short interim note that no steer follows still
// folds into its run (turns.ts mergeShortNotes); the reply before a steer never does: not in a running
// turn's Codex-style runs, not in an ended turn's opened "Worked for".
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 9, 31, 20, 0, 0);
let at = START;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 10_000),
  ...extra,
});
const bash = (id: string) =>
  row(`a-${id}`, "activity", {
    items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
  });

// Short notes between runs: n1 is interim chatter, r1 is what the agent told the person before he
// steered, with a run after it that the steer came behind.
const running = [
  row("u", "user", { text: "Look at the fleet" }),
  bash("b0"),
  row("n1", "assistant", { text: "Reading the logs." }),
  bash("b1"),
  row("r1", "assistant", { text: "The minis are healthy." }),
  bash("b2"),
  row("s1", "user", { text: "also the runners", steer: "landed" }),
  bash("b3"),
];
const ended = [
  ...running,
  row("r2", "assistant", { text: "All three are healthy." }),
  row("sum", "turnSummary", { status: "completed" }),
];

const notesIn = (rows: AcpmuxRow[]) =>
  rows.flatMap((each) => (each.items ?? []).filter((item) => item.kind === "note").map((item) => item.text));

test("a running turn's Codex-style runs keep the reply before a steer; other chatter folds", () => {
  const view = turnView(running, new Set(), { working: true, liveRuns: true, now: START + 200_000 });
  expect(view.some((each) => each.id === "r1")).toBe(true);
  expect(notesIn(view)).not.toContain("The minis are healthy.");
  expect(view.some((each) => each.id === "n1")).toBe(false);
  expect(notesIn(view)).toContain("Reading the logs.");
});

test("an ended Codex turn keeps the reply before a steer in sight, closed or opened", () => {
  const options = { liveRuns: true, agentFamily: "codex", now: START + 400_000 };
  const closed = turnView(ended, new Set(), options).map((each) => each.id);
  expect(closed).toContain("r1");
  expect(closed).toContain("s1");
  expect(closed).not.toContain("n1");
  const open = turnView(ended, new Set([`${WORKED}-u`]), options);
  expect(open.some((each) => each.id === "r1")).toBe(true);
  expect(notesIn(open)).not.toContain("The minis are healthy.");
  expect(notesIn(open)).toContain("Reading the logs.");
});
