// Bring your history: everything under a source's line starts at the title's left edge (Leo,
// 2026-11-05: "the buttons and the subtitle text is in a different indentation level"). The path
// already sits in the title's column; the counts, the row status, the error and the paste box (its
// help, Copy button, label and text box) each set their own start, so each must use the one inset.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/pages/import-history/styles.css", import.meta.url), "utf8");

/** The `margin-inline-start` of the first top-level rule whose selector list names `selector`. */
function inlineStart(selector: string): string | undefined {
  for (const [, selectors, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const list = selectors.split(",").map((part) => part.trim());
    if (!list.includes(selector)) continue;
    const value = body.match(/margin-inline-start:\s*([^;]+);/)?.[1].trim();
    if (value) return value;
  }
  return undefined;
}

const UNDER_THE_LINE = [".history-report", ".history-row-status", ".history-error-detail", ".history-paste"];

for (const selector of UNDER_THE_LINE) {
  test(`${selector} starts at the source title's edge`, () => {
    expect(inlineStart(selector)).toBe("var(--history-title-inset)");
  });
}

test("the title inset is the checkbox, the mark and their gaps", () => {
  expect(css).toContain(
    "--history-title-inset: calc(var(--ds-icon-14) + var(--ds-space-2) + var(--ds-control-compact) + var(--ds-space-2));",
  );
});
