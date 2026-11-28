import { expect, test } from "bun:test";
import { projectGoal } from "../src/pages/home-channels/goal";
import type { RunEntry } from "../src/pages/home-channels/runs";
import type { HomeRun } from "../src/pages/home-channels/types";

const run = (overrides: Partial<HomeRun> = {}): HomeRun => ({
  id: "run-1",
  conversation: "conversation-1",
  author: "chief-1",
  status: "running",
  startedAt: 1_000,
  updatedAt: 2_000,
  rev: 1,
  stepCount: 0,
  answers: [],
  ...overrides,
});

const entry = (value: HomeRun): RunEntry => ({ run: value, steps: [], complete: false });

test("projects the newest unresolved run as a working goal", () => {
  const goal = projectGoal([entry(run({ title: "Ship the strip" }))], 2_001);
  expect(goal?.state).toBe("working");
  expect(goal?.title).toBe("Ship the strip");
});

test("projects a quiet running run as stalled", () => {
  const goal = projectGoal([entry(run({ title: "Recover the owner", updatedAt: 0 }))], 2_001);
  expect(goal?.state).toBe("working");

  const stalled = projectGoal([entry(run({ title: "Recover the owner", updatedAt: 1 }))], 30 * 60_000 + 2);
  expect(stalled?.state).toBe("stalled");
  expect(stalled?.detail).toBeUndefined();
});

test("keeps failed work visible and completed work folded away", () => {
  const failed = projectGoal([entry(run({ status: "failed", error: "Owner stopped" }))], 2_001);
  expect(failed?.state).toBe("failed");
  expect(projectGoal([entry(run({ status: "done" }))], 2_001)).toBeUndefined();
});

test("does not expose an answer message id as the goal title", () => {
  const goal = projectGoal([entry(run({ answers: ["message-internal-id"] }))], 2_001);
  expect(goal?.title).toBe("");
});
