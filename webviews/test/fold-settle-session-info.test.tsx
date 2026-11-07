// l10n-allow-file: test fixture names, not shipped UI.
// Session Info's folds that #37845 left popping in move as one motion on the settle (Leo, 2026-11-07:
// "they dont overshoot but they decelerate at the end. i think that might be the key"): Usage's View
// all / Show fewer, Context's lists, a workflow's phases, its "N finished" and a finished agent's
// output. Each box's height (and, opening from nothing, its opacity) moves over --cmux-motion-settle
// on --cmux-ease-settle, the rows that go stay drawn until it has closed and nothing mounts after;
// the chevron is one glyph that turns on the same curve; under Reduce Motion it is one frame.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { ContextBreakdownView, type Breakdown } from "../src/agent-session/acpmux/session-info/ContextSection";
import { USAGE_SHOWN, UsageSection } from "../src/agent-session/acpmux/session-info/UsageSection";
import type { UsageEntry } from "../src/agent-session/acpmux/session-info/usageEntries";
import { WorkflowAgentRow, WorkflowTasks } from "../src/agent-session/acpmux/session-info/WorkflowTasks";
import { createWorkflowAdapter } from "../src/agent-session/acpmux/summary/foldWorkflows";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";
import { click, expectSettle, fold, reduceMotion, render, useFoldPage } from "./foldSettleHarness";

useFoldPage();

const NOW = 1_800_000_000_000;
const $ = (selector: string) => fold.container.querySelector<HTMLElement>(selector);
const $$ = (selector: string) => [...fold.container.querySelectorAll<HTMLElement>(selector)];

const sessions: UsageEntry[] = Array.from({ length: USAGE_SHOWN + 3 }, (_, index) => ({
  sessionId: `s${index}`,
  title: `chat ${index}`,
  usageStats: { autocompact: "capped", contextTokens: 1000 * (index + 1), costUsd24h: index + 1, updatedAt: NOW },
}));

const breakdown: Breakdown = {
  rows: [{ name: "System prompt", tokens: 4000, kind: "used", share: 0.02 }],
  lists: [
    {
      id: "skills",
      items: [
        { name: "review", tokens: 120 },
        { name: "deploy", tokens: 80 },
      ],
    },
  ],
};

const workflow = (stage: "running" | "finished") => createWorkflowAdapter()(workflowFixture(stage, NOW), "s1")[0]!;

/// Each fold: what draws it, its toggle, and the rows it opens (counted open and closed).
const folds: Array<{
  name: string;
  draw: () => void;
  toggle: string;
  rows: string;
  closed: number;
  open: number;
  startsOpen?: boolean;
}> = [
  {
    name: "Usage's View all",
    draw: () => render(<UsageSection sessions={sessions} />),
    toggle: "button.acpmux-session-info-usage-fold",
    rows: ".acpmux-session-info-usage li",
    closed: USAGE_SHOWN,
    open: USAGE_SHOWN + 3,
  },
  {
    name: "a Context list",
    draw: () => render(<ContextBreakdownView breakdown={breakdown} bar={false} />),
    toggle: "button.acpmux-context-breakdown__fold",
    rows: ".acpmux-context-breakdown__items li",
    closed: 0,
    open: 2,
  },
  {
    name: "a workflow's phase",
    draw: () => render(<WorkflowTasks workflows={[workflow("running")]} onStop={async () => undefined} />),
    toggle: "button.acpmux-workflow-phase__head:not(:disabled)",
    rows: ".acpmux-workflow-phase__agents > li",
    closed: 0,
    open: 3,
  },
  {
    name: "a workflow's N finished",
    draw: () => render(<WorkflowTasks workflows={[workflow("running")]} onStop={async () => undefined} />),
    toggle: "button.acpmux-workflow-finished__fold",
    rows: ".acpmux-workflow-finished__agents > li",
    closed: 0,
    open: 3,
    startsOpen: true,
  },
  {
    name: "a finished agent's output",
    draw: () => {
      const run = workflow("finished");
      const agent = run.agents.find((each) => each.state === "completed")!;
      render(
        <ul>
          <WorkflowAgentRow workflow={run} agent={agent} now={NOW} />
        </ul>,
      );
    },
    toggle: "button.acpmux-workflow-agent__disclosure",
    rows: ".acpmux-workflow-agent__output",
    closed: 0,
    open: 1,
  },
];

/// One toggle: the box moves on the settle; opening, its rows are drawn at once; closing, they stay
/// drawn until it has closed over them and go on the frame it ends.
function step(toggle: string, rows: string, opening: boolean, open: number, closed: number) {
  const before = fold.animations.length;
  click($(toggle)!);
  expect(fold.animations.length).toBe(before + 1);
  const animation = fold.animations.at(-1)!;
  expectSettle(animation);
  expect($$(rows).length).toBe(open);
  animation.finish();
  expect($$(rows).length).toBe(opening ? open : closed);
}

for (const { name, draw, toggle, rows, closed, open, startsOpen = false } of folds) {
  test(`${name} opens and closes on the settle, its rows drawn until it has closed and none after`, () => {
    draw();
    expect($$(rows).length).toBe(startsOpen ? open : closed);
    step(toggle, rows, !startsOpen, open, closed);
    step(toggle, rows, startsOpen, open, closed);
    // The motion ended at its final layout: nothing more runs, mounts or stays clipped.
    expect(fold.animations.length).toBe(2);
    expect($("[data-folding]")).toBeNull();
  });

  test(`${name} opens and closes in one frame under Reduce Motion`, () => {
    reduceMotion();
    draw();
    click($(toggle)!);
    expect($$(rows).length).toBe(startsOpen ? closed : open);
    click($(toggle)!);
    expect($$(rows).length).toBe(startsOpen ? open : closed);
    expect(fold.animations).toEqual([]);
  });
}

const css = (file: string) =>
  readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/session-info", file), "utf8");

test("the folds' chevrons are one glyph that turns on the settle, at once under Reduce Motion", () => {
  render(<ContextBreakdownView breakdown={breakdown} bar={false} />);
  const chevron = () => $("button.acpmux-context-breakdown__fold svg")!;
  expect(chevron().getAttribute("data-icon")).toBe("disclosure.collapsed");
  click($("button.acpmux-context-breakdown__fold")!);
  // Not swapped for another glyph: the same one turns.
  expect(chevron().getAttribute("data-icon")).toBe("disclosure.collapsed");
  const turns =
    /transition: rotate var\(--cmux-motion-settle, 265ms\) var\(--cmux-ease-settle, cubic-bezier\(0\.16, 1, 0\.3, 1\)\)/;
  for (const [file, chevrons] of [
    ["ContextSection.css", [".acpmux-context-breakdown__fold"]],
    [
      "WorkflowTasks.css",
      [".acpmux-workflow-phase__head", ".acpmux-workflow-agent__disclosure", ".acpmux-workflow-finished__fold"],
    ],
  ] as const) {
    const text = css(file);
    for (const selector of chevrons) expect(text).toContain(`${selector}[aria-expanded="true"] > svg`);
    // The turn is only under no-preference and the page's motion switch on.
    const guarded = text.slice(text.indexOf("@media (prefers-reduced-motion: no-preference)"));
    expect(guarded).toMatch(turns);
    expect(guarded).toContain('[data-cmux-motion="reduced"]');
  }
});
