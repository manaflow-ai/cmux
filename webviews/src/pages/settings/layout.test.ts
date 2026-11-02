// The page's layout at pane widths, from the two stylesheets in cascade order (styles.css, then
// layout.css). Regression: layout.css set the two-column grid after styles.css's narrow rule, so a
// pane under 600 px kept two columns while the sidebar took the stacked layout's 40vh cap and
// bottom edge: the categories were cut off and the column overlapped them in short panes.
import { Glob } from "bun";
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { stylesheet } from "./testDom";

type Rule = { selectors: string[]; media: string | null; declarations: Map<string, string> };

function rules(css: string): Rule[] {
  const out: Rule[] = [];
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  let index = 0;
  const parseBlock = (end: number, media: string | null) => {
    while (index < end) {
      const open = text.indexOf("{", index);
      if (open < 0 || open >= end) break;
      const prelude = text.slice(index, open).trim();
      if (prelude.startsWith("@media")) {
        let depth = 1;
        let close = open + 1;
        while (depth > 0) {
          if (text[close] === "{") depth += 1;
          else if (text[close] === "}") depth -= 1;
          close += 1;
        }
        index = open + 1;
        parseBlock(close - 1, prelude.slice(6).trim());
        index = close;
        continue;
      }
      const close = text.indexOf("}", open);
      if (!prelude.startsWith("@")) {
        const declarations = new Map<string, string>();
        for (const part of text.slice(open + 1, close).split(";")) {
          const colon = part.indexOf(":");
          if (colon > 0)
            declarations.set(
              part.slice(0, colon).trim(),
              part
                .slice(colon + 1)
                .trim()
                .replace(/\s+/g, " "),
            );
        }
        out.push({ selectors: prelude.split(",").map((selector) => selector.trim()), media, declarations });
      }
      index = close + 1;
    }
  };
  parseBlock(text.length, null);
  return out;
}

/** The value of `property` on exactly `selector` for a pane `width` px wide (source order wins). */
function computed(selector: string, property: string, width: number): string | undefined {
  let value: string | undefined;
  for (const rule of rules(stylesheet)) {
    if (!rule.selectors.includes(selector) || !rule.declarations.has(property)) continue;
    if (rule.media) {
      const max = /max-width:\s*(\d+)px/.exec(rule.media);
      if (!max || width > Number(max[1])) continue;
    }
    value = rule.declarations.get(property);
  }
  return value;
}

test("a narrow pane stacks the categories over one column; nothing is cut off", () => {
  expect(computed(".settings", "grid-template-columns", 480)).toBe("minmax(0, 1fr)");
  // The stacked categories are one horizontal strip, never a height-capped list.
  expect(computed(".section-list", "flex-direction", 480)).toBe("row");
  expect(computed(".sidebar", "max-height", 480) ?? "none").toBe("none");
});

test("a wide pane keeps the sidebar column, which scrolls in a short pane", () => {
  expect(computed(".settings", "grid-template-columns", 1000)).toBe("var(--sidebar-width) minmax(0, 1fr)");
  expect(computed(".sidebar", "overflow-y", 1000)).toBe("auto");
  expect(computed(".sidebar", "max-height", 1000) ?? "none").toBe("none");
});

/** The refined look (mount.tsx always sets it): its rules beat the base narrow block by specificity,
 *  so the stacked layout must be restated there. Value of `property` on exactly `selector` at `width`. */
const refinedSheet = readFileSync(new URL("./refined.css", import.meta.url), "utf8");
function refined(selector: string, property: string, width: number): string | undefined {
  let value: string | undefined;
  for (const rule of rules(refinedSheet)) {
    if (!rule.selectors.includes(`:root[data-settings-look="refined"] ${selector}`) || !rule.declarations.has(property))
      continue;
    if (rule.media) {
      const max = /max-width:\s*(\d+)px/.exec(rule.media);
      if (!max || width > Number(max[1])) continue;
    }
    value = rule.declarations.get(property);
  }
  return value;
}

test("the refined look stacks a narrow pane too: no side border, strip-sized tabs", () => {
  // macOS 15 tester (2026-10-19): the categories over a narrow Settings pane drew as a column
  // card: the sidebar kept its right border and 18 px padding, the tabs their 30 px rows, and the
  // content its left-cut corners and gap, all from the refined rules that outrank the narrow block.
  expect(refined(".settings > .sidebar", "border-right", 480)).toBe("0");
  expect(refined(".settings > .sidebar", "border-bottom", 480)).toBe("1px solid var(--polish-edge)");
  expect(refined(".settings > .sidebar", "padding", 480)).toBe("10px 12px 8px");
  expect(refined(".settings .section-link", "padding", 480)).toBe("4px 8px");
  expect(refined(".settings .section-link", "min-height", 480)).toBe("0");
  // The content pane paints no fill of its own (user, 2026-10-30: one background), so it needs no
  // inset gap at any width; a wide pane has no divider beside the sidebar either.
  expect(refined(".settings > .content", "margin", 480)).toBe("0");
  expect(refined(".settings > .sidebar", "border-right", 1000)).toBe("0");
});

test("the masked content pane draws no outline at any width", () => {
  // Live QA 7b: styles.css's scroll fade masks .content except the scrollbar's 14 px strip, so the
  // refined look's 1 px outline and 12 px corners showed only as a rounded fragment at the right edge.
  expect(computed(".content", "mask-image", 1000)).toBeDefined();
  for (const width of [480, 1000])
    for (const property of ["border", "border-left", "border-right", "border-top", "border-bottom", "border-radius"])
      expect(refined(".settings > .content", property, width)).toBeUndefined();
});

test("a setting row's Reset slot stays on its control's line", () => {
  // Live QA 7a: a three-choice segmented control (330 px) plus the slot passed the 60 % cap, so the
  // slot wrapped and the control sat in the slot's column, 30 px right and a line high.
  expect(computed(".row-control", "flex-wrap", 1000)).toBe("wrap");
  expect(computed(".row-control:has(> .reset-slot)", "flex-wrap", 1000)).toBe("nowrap");
  expect(computed(".row-control:has(> .reset-slot)", "max-width", 1000)).toBe("calc(60% + 30px)");
  expect(computed(".row-control:has(> .reset-slot)", "max-width", 480)).toBe("100%");
});

// The gallery split separately imported sheets into shared chunks and loaded layout.css before
// styles.css (and refined.css before both), so it drew the old switch, rows and titles. page.css
// holds them in cascade order; nothing else may import them.
test("only page.css imports the page's sheets", () => {
  const src = fileURLToPath(new URL("../../", import.meta.url));
  const sheets = new Set(
    ["styles.css", "layout.css", "refined.css"].map((name) => fileURLToPath(new URL(`./${name}`, import.meta.url))),
  );
  const importers: string[] = [];
  for (const file of new Glob("**/*.{ts,tsx,css}").scanSync(src)) {
    const path = join(src, file);
    for (const [, spec] of readFileSync(path, "utf8").matchAll(/(?:import\s*\(?|@import)\s*["'](\.[^"']+\.css)["']/g)) {
      if (sheets.has(resolve(dirname(path), spec!))) importers.push(relative(src, path));
    }
  }
  expect([...new Set(importers)]).toEqual(["pages/settings/page.css"]);
});
