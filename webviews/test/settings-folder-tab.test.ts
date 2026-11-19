// The Settings sidebar's folder tab (pages/settings/look.css; Leo, 2026-11-12: "fixing up the whole,
// like, polish of the two-tone mode"): every rule that joins the current category to the content
// sits under Subtle Tone's container query, so One Color, the default, and an app that sends no tone
// draw the page exactly as before; and every color it draws is a token the host sends.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const look = readFileSync(new URL("../src/pages/settings/look.css", import.meta.url), "utf8").replace(
  /\/\*[\s\S]*?\*\//g,
  "",
);

/** The text of the block that opens at `head`, through its matching brace. */
function block(css: string, head: string): string {
  const start = css.indexOf(head);
  expect(start, head).toBeGreaterThanOrEqual(0);
  let depth = 0;
  for (let index = css.indexOf("{", start); index < css.length; index += 1) {
    if (css[index] === "{") depth += 1;
    else if (css[index] === "}" && --depth === 0) return css.slice(start, index + 1);
  }
  throw new Error(`unclosed ${head}`);
}

const tone = block(look, "@container style(--cmux-chrome-tone: 1)");
const count = (css: string, needle: string) => css.split(needle).length - 1;

test("the folder tab's rules apply only under Subtle Tone", () => {
  for (const needle of ["--cmux-folder-fill", "data-settings-folder-tab", ".section-link[aria-current]::before"]) {
    expect(count(tone, needle), needle).toBeGreaterThan(0);
    expect(count(look, needle), needle).toBe(count(tone, needle));
  }
});

test("the tab, the shade and the rim draw only the host's tokens", () => {
  expect(tone).not.toMatch(/rgba?\(|#[0-9a-f]{3,8}\b|color-mix\(/i);
  expect(tone).toContain("var(--cmux-sidebar-surface, transparent)");
  expect(tone).toContain("var(--polish-divider)");
  expect(look).toContain("--polish-divider: var(--ds-color-divider);");
  expect(look).toContain("--polish-edge: var(--ds-color-separator);");
});

test("a narrow pane's stacked strip keeps no folder tab", () => {
  expect(block(look, "@media (min-width: 601px)")).toContain("@container style(--cmux-chrome-tone: 1)");
});
