// The composer hat shows the running turn's plan; an earlier turn's plan leaves it unless a step in
// it is still in progress, and then only as a collapsed chip (earlierPlanHat.experiment.ts; Leo,
// 2026-11-25: "uhh do we still want these tasks? should we just remove them?", "well do we want to
// render it like that tho in teh composer hat is the question").
import { expect, test } from "bun:test";
import type { AcpmuxPlanEntry } from "../model";
import { hatPlanOf, type ChatTaskList } from "../chatTaskList";
import { earlierPlanHat, earlierPlanShown } from "./earlierPlanHat.experiment";
import { planHeadMark } from "./subagentTrayModel";

const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });
const reminder = [todo("Check back on the CI run", "pending")];
const stopped = [todo("Add retry", "completed"), todo("Cover it", "in_progress"), todo("Docs", "pending")];
const list = (items: AcpmuxPlanEntry[], source: ChatTaskList["source"] = "harness"): ChatTaskList => ({
  source,
  done: items.filter((entry) => entry.status === "completed").length,
  total: items.length,
  items,
  updatedAt: 1,
});

test("ships the chip arm: no hat without a step in progress", () => {
  expect(earlierPlanHat.defaultArm).toBe("chip");
});

test("an earlier plan of pending reminders leaves the hat once the new turn runs (Leo's 0 of 1)", () => {
  expect(hatPlanOf({ working: true, earlier: reminder })).toBeUndefined();
  expect(hatPlanOf({ working: true, list: list(reminder) })).toBeUndefined();
  expect(hatPlanOf({ working: true, earlier: reminder, list: list(reminder) })).toBeUndefined();
});

test("an earlier plan with a step still in progress stays, marked earlier", () => {
  expect(hatPlanOf({ working: true, earlier: stopped })).toEqual({ plan: stopped, earlier: true, kept: false });
  expect(hatPlanOf({ working: true, list: list(stopped) })).toEqual({ plan: stopped, earlier: true, kept: false });
});

test("the chip goes once that step completes", () => {
  const finished = stopped.map((entry) =>
    entry.status === "in_progress" ? { ...entry, status: "completed" as const } : entry,
  );
  expect(hatPlanOf({ working: true, earlier: finished })).toBeUndefined();
});

test("the new turn's own plan replaces it", () => {
  const live = [todo("Change the backoff", "in_progress")];
  expect(hatPlanOf({ working: true, live, earlier: stopped })).toEqual({ plan: live, earlier: false, kept: false });
});

test("the none arm never shows an earlier plan; before keeps any with steps left", () => {
  expect(hatPlanOf({ working: true, earlier: stopped, earlierArm: "none" })).toBeUndefined();
  expect(hatPlanOf({ working: true, earlier: reminder, earlierArm: "before" })?.earlier).toBe(true);
  expect(earlierPlanShown("fade", stopped)).toBe(true);
  expect(earlierPlanShown("fade", reminder)).toBe(false);
});

test("a list the Chief or the agent keeps is current, not earlier: unchanged", () => {
  expect(hatPlanOf({ working: true, list: list(reminder, "chief") })).toEqual({
    plan: reminder,
    earlier: false,
    kept: false,
  });
});

test("an earlier chip neither spins nor counts the turn (no 7s timer)", () => {
  // SubagentTray passes working && !earlierChip.
  expect(planHeadMark({ working: false, turnSince: 1_000 })).toEqual({ spins: false, since: undefined });
});
