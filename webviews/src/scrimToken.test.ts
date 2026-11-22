// Leo (2026-10-06): popups darkened the page too much. Every web modal scrim reads the one native
// token, `--cmux-scrim` (WebTheme: black at 12% light, 25% dark), never its own black.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const here = import.meta.dir;
const rules: [string, string][] = [
  ["agent-session/acpmux/styles.css", ".acpmux-shell[data-sidebar=open] .acpmux-sidebar-scrim"],
  ["pages/cloud/styles.css", ".cloud-sheet-backdrop"],
  ["ui/ui.css", ".ui-backdrop"],
  ["agent-session/acpmux/prototype/prototype.css", ".proto-scrim"],
];

function block(css: string, selector: string): string {
  const start = css.indexOf(`${selector}{`) >= 0 ? css.indexOf(`${selector}{`) : css.indexOf(`${selector} {`);
  expect(start).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf("}", start));
}

test("every modal scrim paints the shared scrim token", () => {
  for (const [file, selector] of rules) {
    const rule = block(readFileSync(join(here, file), "utf8"), selector);
    const background = /background(?:-color)?:\s*([^;}]+)/.exec(rule)?.[1] ?? "";
    expect(`${selector}: ${background.trim()}`).toBe(`${selector}: var(--cmux-scrim, rgb(0 0 0 / 12%))`);
  }
});
