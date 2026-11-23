// A plan step's words (PlanList.tsx PlanStep). Leo, 2026-11-22, on a two-line ops note drawn as plain
// wrapped text: ">1 line is ok IFF it's rendered and styled properly".
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { PlanList } from "./PlanList";

const html = (content: string) => renderToStaticMarkup(<PlanList entries={[{ content, status: "in_progress" }]} />);

test("a step's first line is its title, its GitHub references chips, the rest its muted detail", () => {
  const out = html("Close cmux#45720 as included\nSay which commit carries `abc123`.");
  expect(out).toContain('<span class="cv-plan__title">Close <a');
  expect(out).toContain('href="https://github.com/manaflow-ai/cmux/pull/45720"');
  expect(out).toMatch(/<span class="cv-plan__detail">Say which commit carries <code[^>]*>abc123<\/code>\.<\/span>/);
  // The whole text is its tooltip.
  expect(out).toContain('title="Close cmux#45720 as included\nSay which commit carries `abc123`."');
});

test("a one-line step has no detail", () => {
  const out = html("Update the docs");
  expect(out).toContain('<span class="cv-plan__title">Update the docs</span>');
  expect(out).not.toContain("cv-plan__detail");
});
