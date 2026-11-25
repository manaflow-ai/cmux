// cmux#51039: the composer hat's plan read "0 of 6 · Read prior fixes, find real cause" with no mark
// on the step in progress and nothing saying the chat ran (the person, 2026-11-22: "this is confusing i
// wasn't sure if this workspace was doing anything"). The step at work always draws a mark: the
// spinner while the turn runs, a plain ring between turns. A plan-only header spins and counts the
// turn's time while it runs. Every step of a six-step plan shows without scrolling.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { PlanList } from "./PlanList";
import { planHeadMark } from "../subagents/subagentTrayModel";
import type { AcpmuxPlanEntry, AcpmuxRow } from "../model";
import { liveTurnClockStart } from "./turns";

const plan: AcpmuxPlanEntry[] = [
  { content: "Read prior fixes, find real cause", status: "in_progress" },
  { content: "Write failing regression test", status: "pending" },
  { content: "Fix and get test green", status: "pending" },
  { content: "Dev build, repro and verify", status: "pending" },
  { content: "Open PR, post issue evidence", status: "pending" },
  { content: "Squash-merge once verified", status: "pending" },
];

const conversationCss = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
const subagentsCss = readFileSync(new URL("../subagents/subagents.css", import.meta.url), "utf8");

/// The selectors of every rule in `css` whose body holds `declaration`.
const selectorsWith = (css: string, declaration: string): string[] =>
  [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter((rule) => rule[2]!.includes(declaration))
    .map((rule) => rule[1]!.trim());

test("a running turn's step in progress spins", () => {
  const out = renderToStaticMarkup(<PlanList entries={plan} />);
  expect(out).toContain(
    'data-status="in_progress"><span class="cv-plan__mark" aria-hidden="true"><svg class="cv-spinner',
  );
  expect(out).not.toContain("data-still");
});

test("between turns the step in progress draws a plain ring, never a blank mark", () => {
  const out = renderToStaticMarkup(<PlanList entries={plan} still />);
  expect(out).toContain('class="cv-plan" data-still=""');
  expect(out).not.toContain("cv-spinner");
  // The rule that drops the ring for the spinner must not apply to a still list...
  const ringless = selectorsWith(conversationCss, "border-width: 0");
  const inProgress = ringless.filter((selector) => selector.includes('[data-status="in_progress"]'));
  expect(inProgress.length).toBeGreaterThan(0);
  for (const selector of inProgress) expect(selector).toContain("[data-still]");
  // ...and a still list's step in progress gets the plain ring an ended one has.
  expect(
    selectorsWith(conversationCss, "border-color: var(--cv-text-muted)").some((selector) =>
      selector.includes('.cv-plan[data-still] .cv-plan__item[data-status="in_progress"] .cv-plan__mark'),
    ),
  ).toBe(true);
});

test("a plan-only header spins and counts the turn's time while the turn runs, and rests between turns", () => {
  expect(planHeadMark({ working: true, turnSince: 1_000 })).toEqual({ spins: true, since: 1_000 });
  expect(planHeadMark({ working: false, turnSince: 1_000 })).toEqual({ spins: false, since: undefined });
});

test("the hat shows a six-step plan whole", () => {
  const rule = /\.acpmux-running-tray__plan \{[^}]*max-height: calc\((\d+) \* var\(--ui-row-height/.exec(subagentsCss);
  expect(rule).not.toBeNull();
  expect(Number(rule![1])).toBeGreaterThanOrEqual(plan.length);
});

test("the hat's clock counts the turn's current stretch, as the transcript's live line does", () => {
  const T = 1_790_000_000_000;
  const prompt: AcpmuxRow = { id: "p", version: 1, at: T, kind: "user", text: "fix it" };
  const reply: AcpmuxRow = { id: "r", version: 1, at: T + 1_000, kind: "assistant", text: "done" };
  const notice: AcpmuxRow = { id: "n", version: 1, at: T + 60_000, kind: "user", text: "task ended", untyped: true };
  // The harness's start leads; the prompt's time is the fallback.
  expect(liveTurnClockStart([prompt], T - 5)).toBe(T - 5);
  expect(liveTurnClockStart([prompt])).toBe(T);
  // A notice that set the agent going again after it replied starts a new stretch.
  expect(liveTurnClockStart([prompt, reply, notice], T)).toBe(T + 60_000);
  expect(liveTurnClockStart([])).toBeUndefined();
});
