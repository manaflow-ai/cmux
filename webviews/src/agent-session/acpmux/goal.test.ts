import { expect, test } from "bun:test";
import { taskGoal } from "./goal";

test("normalizes a persisted Codex goal for the pane snapshot", () => {
  expect(
    taskGoal({ objective: "Keep typing responsive", status: "active", tokenBudget: 12_000, tokensUsed: 240 }),
  ).toEqual({ objective: "Keep typing responsive", status: "active", tokenBudget: 12_000, tokensUsed: 240 });
});

test("drops malformed goal metadata instead of rendering a stale banner", () => {
  expect(taskGoal({ objective: "", status: "active" })).toBeUndefined();
  expect(taskGoal({ objective: "Keep typing responsive", status: "unknown" })).toBeUndefined();
  expect(taskGoal({ objective: "Keep typing responsive", status: "active", tokenBudget: -1 })).toEqual({
    objective: "Keep typing responsive",
    status: "active",
  });
});
