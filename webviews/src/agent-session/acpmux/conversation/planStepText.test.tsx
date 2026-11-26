// A multi-line plan step names itself by its first line wherever one line names it (planStepText.ts).
// Leo, 2026-11-22, on a two-line ops note drawn as a plan's step: "these shouldn't have been shown
// like that."
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { planStepParts, planStepTitle } from "./planStepText";
import { earlierPlanHead, planHead } from "../subagents/subagentTrayModel";
import { ProgressSection } from "../session-info/ProgressSection";
import type { Translate } from "../i18n";

const note = "\n  Restart the relay  \nthen read its log for the 403s\nand say which host";

test("a step's first line with words is its title, the rest its detail", () => {
  expect(planStepParts(note)).toEqual({
    title: "Restart the relay",
    detail: "then read its log for the 403s\nand say which host",
  });
  expect(planStepParts("Update the docs")).toEqual({ title: "Update the docs", detail: "" });
  expect(planStepParts("  \n ")).toEqual({ title: "", detail: "" });
});

// A stand-in for the pane's strings: "{done} of {total}" as the English hat reads.
const t = ((key: string, args?: { done?: number; total?: number }) =>
  key === "plan.hat"
    ? `${args?.done} of ${args?.total}`
    : key === "plan.earlier.short"
      ? "Earlier plan"
      : key) as Translate;

test("the composer hat names a multi-line step by its title, on one line", () => {
  const head = planHead(t, [{ content: note, status: "in_progress" }]);
  expect(head).toBe("0 of 1 · Restart the relay");
  expect(head).not.toContain("\n");
  expect(earlierPlanHead(t, [{ content: note, status: "pending" }])).toBe("Earlier plan · 0 of 1");
});

test("the Session Info progress list draws a multi-line step as the chat's list does", () => {
  const out = renderToStaticMarkup(
    <ProgressSection plan={{ entries: [{ content: note, status: "in_progress" }], ended: false }} />,
  );
  expect(out).toContain('<span class="cv-plan__title">Restart the relay</span>');
  expect(out).toContain('<span class="cv-plan__detail">then read its log for the 403s');
  expect(planStepTitle(note)).toBe("Restart the relay");
});
