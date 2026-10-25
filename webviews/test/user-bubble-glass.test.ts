// The person's own prompt bubble is glass, never opaque (Leo 2026-10-20: "don't make it opaque... I
// even hate opaque for my own messages right here"). The general scan (glass-never-opaque.test.ts)
// only sees a surface as glass by its blur or a class named glass in CSS; the bubble is glass through
// `.ui-glass` on its element, so a rule on `.cv-user__bubble` could paint it solid unseen, as the
// composer-colored fill it had before #23477 did. This pins both halves: every element drawn as the
// bubble carries `.ui-glass`, and every fill a `.cv-user__bubble` rule paints outside Reduce
// Transparency (its background, its glass tint, the landing highlight it flashes when the thread
// minimap jumps to it) is provably translucent.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { fillKind, glassContextRules } from "../scripts/check-glass-never-opaque";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../src");
const BUBBLE = "cv-user__bubble";
// The fills a bubble rule may paint: --glass-opaque is the Reduce Transparency fill and is solid on purpose.
const FILLS = new Set(["background", "background-color", "--glass-tint", "--acpmux-landing-highlight"]);

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sources(path);
    return entry.name.endsWith(".tsx") && !entry.name.includes(".test.") ? [path] : [];
  });
}

// The selector's subject is the bubble itself (`.acpmux-shell .cv-user__bubble`,
// `.cv-user__bubble--collapsed`), not something inside it.
function stylesBubble(selector: string): boolean {
  return selector.split(",").some((part) => {
    const subject =
      part
        .trim()
        .split(/[\s>+~]+/)
        .at(-1) ?? "";
    return new RegExp(`\\.${BUBBLE}(?![\\w])`).test(subject);
  });
}

test("every element drawn as the user bubble is liquid glass", () => {
  const bare: string[] = [];
  let seen = 0;
  for (const file of sources(SRC)) {
    for (const match of readFileSync(file, "utf8").matchAll(/["'`]([^"'`\n]*)["'`]/g)) {
      const classes = (match[1] ?? "").split(/\s+/);
      if (!classes.includes(BUBBLE)) continue;
      seen++;
      if (!classes.includes("ui-glass")) bare.push(`${relative(SRC, file)}: "${match[1]}"`);
    }
  }
  expect(seen).toBeGreaterThan(0);
  expect(bare).toEqual([]);
});

test("the user bubble's fills are translucent outside Reduce Transparency", () => {
  const fills = glassContextRules()
    .filter((rule) => stylesBubble(rule.selector))
    .flatMap((rule) =>
      rule.decls
        .filter((d) => FILLS.has(d.prop))
        .map((d) => ({
          at: `${rule.file}:${d.line}: ${rule.selector} { ${d.prop}: ${d.value} }`,
          prop: d.prop,
          value: d.value,
        })),
    );
  // Not vacuous: the bubble's tint and its landing highlight are both here.
  expect(fills.map((f) => f.prop)).toContain("--glass-tint");
  expect(fills.map((f) => f.prop)).toContain("--acpmux-landing-highlight");
  expect(fills.filter((f) => fillKind(f.value) !== "translucent").map((f) => f.at)).toEqual([]);
});

// The fill the bubble had before it was glass (the composer's tint mixed into the opaque base) fails.
test("the old composer-colored bubble fill is not translucent", () => {
  glassContextRules();
  expect(fillKind("color-mix(in srgb, var(--agent-text) 13%, var(--acpmux-base))")).not.toBe("translucent");
  expect(fillKind("color-mix(in srgb, var(--agent-text) 12%, transparent)")).toBe("translucent");
});
