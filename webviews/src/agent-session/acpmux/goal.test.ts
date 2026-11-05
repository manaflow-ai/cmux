import { expect, test } from "bun:test";
import { taskGoal } from "./goal";

test("normalizes a persisted Codex goal for the pane snapshot", () => {
  expect(
    taskGoal({
      objective: "Keep typing responsive",
      status: "active",
      provider: "codex",
      startedAt: 1_700_000_000_000,
      elapsedMs: 1200,
      steps: [{ label: "Measure", status: "done" }],
      tokenBudget: 12_000,
      tokensUsed: 240,
    }),
  ).toEqual({
    objective: "Keep typing responsive",
    status: "running",
    provider: "codex",
    startedAt: 1_700_000_000_000,
    elapsedMs: 1200,
    steps: [{ label: "Measure", status: "done" }],
    tokenBudget: 12_000,
    tokensUsed: 240,
  });
});

test("normalizes Claude loop lifecycle and keeps its plan steps", () => {
  expect(
    taskGoal({
      objective: "Keep checking until the build is green",
      status: "stalled",
      provider: "claude",
      createdAt: 1_700_000_000,
      updatedAt: 1_700_000_012,
      timeUsedSeconds: 12,
      steps: ["Inspect", { content: "Test", status: "running" }, { nope: true }],
    }),
  ).toEqual({
    objective: "Keep checking until the build is green",
    status: "stalled",
    provider: "claude",
    startedAt: 1_700_000_000_000,
    updatedAt: 1_700_000_012_000,
    elapsedMs: 12_000,
    steps: [{ label: "Inspect" }, { label: "Test", status: "running" }],
  });
});

test("drops malformed goal metadata instead of rendering a stale banner", () => {
  expect(taskGoal({ objective: "", status: "active" })).toBeUndefined();
  expect(taskGoal({ objective: "Keep typing responsive", status: "unknown" })).toBeUndefined();
  expect(taskGoal({ objective: "Keep typing responsive", status: "active", tokenBudget: -1 })).toEqual({
    objective: "Keep typing responsive",
    status: "running",
  });
});

test("keeps Claude Code's /loop as a loop goal, with its next run and schedule", () => {
  expect(
    taskGoal({
      kind: "loop",
      objective: "check the deploy",
      status: "active",
      reason: "deploy still rolling out",
      nextRunAt: 1_790_000_270_000,
      schedule: "every 5 minutes",
    }),
  ).toEqual({
    kind: "loop",
    objective: "check the deploy",
    status: "active",
    reason: "deploy still rolling out",
    nextRunAt: 1_790_000_270_000,
    schedule: "every 5 minutes",
  });
  // An autonomous /loop has no prompt of the person's: it still shows as a loop.
  expect(taskGoal({ kind: "loop", objective: "", autonomous: true, status: "active" })).toEqual({
    kind: "loop",
    objective: "",
    autonomous: true,
    status: "active",
  });
  // A Codex goal names no kind and stays as it was.
  expect(taskGoal({ objective: "Ship", status: "active" })?.kind).toBeUndefined();
  expect(taskGoal({ kind: "other", objective: "Ship", status: "active" })?.kind).toBeUndefined();
});
