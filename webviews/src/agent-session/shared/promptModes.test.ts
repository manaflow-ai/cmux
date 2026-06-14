import { expect, test } from "bun:test";
import { promptTextWithPlanMode } from "./promptModes";

test("plan mode appends the Codex skill mention without changing visible input", () => {
  expect(promptTextWithPlanMode("write a plan", true)).toBe("write a plan\n\n[$plan](skill://plan)");
});

test("plan mode leaves prompts alone when disabled or already present", () => {
  expect(promptTextWithPlanMode("write a plan", false)).toBe("write a plan");
  expect(promptTextWithPlanMode("write a plan [$plan](skill://plan)", true)).toBe("write a plan [$plan](skill://plan)");
  expect(promptTextWithPlanMode("write a plan $plan", true)).toBe("write a plan $plan");
});
