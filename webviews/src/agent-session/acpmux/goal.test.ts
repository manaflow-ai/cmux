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
