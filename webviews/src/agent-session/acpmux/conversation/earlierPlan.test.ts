// The todo list from before the person's last message (turns.ts earlierTurnPlan, withEarlierPlan):
// Claude desktop's pinned task list keeps the earlier list in sight until the agent writes a new one.
import { expect, test } from "bun:test";
import type { AcpmuxPlanEntry, AcpmuxRow } from "../model";
import { earlierTurnPlan, withEarlierPlan } from "./turns";

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: `${kind}-${(n += 1)}`,
  version: 1,
  at: n,
  kind,
  ...fields,
});
const todo = (content: string, status: AcpmuxPlanEntry["status"]): AcpmuxPlanEntry => ({ content, status });
const stopped = () =>
  row("plan", { turnEnded: true, plan: [todo("Add retry", "completed"), todo("Cover it", "in_progress")] });

test("an ended list with steps left carries over once the person writes again", () => {
  const plan = stopped();
  expect(earlierTurnPlan([row("user"), plan, row("assistant"), row("user"), row("assistant")])).toBe(plan);
});

test("no carry-over before the person writes again", () => {
  expect(earlierTurnPlan([row("user"), stopped(), row("assistant")])).toBeUndefined();
});

test("a finished list stays folded in its own turn", () => {
  const done = row("plan", { turnEnded: true, plan: [todo("Add retry", "completed")] });
  expect(earlierTurnPlan([row("user"), done, row("user")])).toBeUndefined();
});

test("the running turn's own list ends the carry-over", () => {
  const live = row("plan", { plan: [todo("Change the backoff", "in_progress")] });
  expect(earlierTurnPlan([row("user"), stopped(), row("user"), live])).toBeUndefined();
});

test("a cleared list ends the carry-over", () => {
  expect(
    earlierTurnPlan([row("user"), stopped(), row("user"), row("plan", { turnEnded: true, plan: [] })]),
  ).toBeUndefined();
});

test("another session's message is not the person's", () => {
  const incoming = row("user", { incoming: { kind: "message" } as AcpmuxRow["incoming"] });
  expect(earlierTurnPlan([row("user"), stopped(), incoming])).toBeUndefined();
});

test("the copy pins over the live line, else last", () => {
  const plan = row("plan", { planEarlier: true });
  const reply = row("assistant");
  const line = row("working", { below: true });
  expect(withEarlierPlan([reply, line], plan)).toEqual([reply, plan, line]);
  expect(withEarlierPlan([reply], plan)).toEqual([reply, plan]);
  const rows = [reply];
  expect(withEarlierPlan(rows, undefined)).toBe(rows);
});
