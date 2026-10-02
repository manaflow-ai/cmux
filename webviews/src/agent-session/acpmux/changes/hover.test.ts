import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { treeUnsafeCSS } from "../diffTheme";

// Every control in the changes view and the edited-files card answers the pointer and the
// keyboard: a hover step, a pressed step and a focus ring from theme tokens, eased with the
// Motion `hover` token, and nothing that moves the layout around it.
const css = ["../styles.css", "./changes.css"]
  .map((path) => readFileSync(new URL(path, import.meta.url), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, "");
/// Every rule as [selectors, declarations], media queries flattened.
const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((match) => ({
  selectors: match[1]!
    .split(",")
    .map((selector) => selector.replace(/@media[^{]*$/, "").trim())
    .filter(Boolean),
  body: match[2]!,
}));
const declares = (selector: string, pattern: RegExp) =>
  rules.some((rule) => rule.selectors.includes(selector) && pattern.test(rule.body));

const CONTROLS = [
  ".acpmux-diff-back",
  ".acpmux-diff-tool",
  "button.acpmux-diff-scope",
  ".acpmux-fh-btn",
  ".acpmux-file-menu-item",
  ".acpmux-changes-retry",
  ".acpmux-changes-banner-action",
  ".acpmux-changes-banner-refresh",
  ".acpmux-review-changes",
  "button.acpmux-edited-file",
  ".acpmux-edited-more",
];

describe("changes view hover states", () => {
  test("each control has a hover, pressed and focus state, eased with the Motion hover token", () => {
    const missing = CONTROLS.flatMap((control) =>
      [
        declares(`${control}:hover`, /background|color/) ? [] : [`${control}:hover`],
        declares(`${control}:active`, /background/) ? [] : [`${control}:active`],
        declares(`${control}:focus-visible`, /outline/) ? [] : [`${control}:focus-visible`],
        declares(control, /transition:[^;]*var\(--acpmux-motion-hover\)/) ? [] : [`${control} transition`],
      ].flat(),
    );
    expect(missing).toEqual([]);
  });

  test("a toggle that is on still answers hover, and the file filter shows focus", () => {
    expect(declares(".acpmux-diff-tool[aria-pressed=true]:hover", /background/)).toBe(true);
    expect(declares(".acpmux-diff-filter:hover", /border-color/)).toBe(true);
    expect(declares(".acpmux-diff-filter:focus-within", /border-color/)).toBe(true);
  });

  test("the file header's chevron fades in without moving the badges beside the name", () => {
    expect(declares(".acpmux-fh-chevron", /display:\s*block/)).toBe(true);
    expect(declares(".acpmux-fh-chevron", /opacity:\s*0\b/)).toBe(true);
    for (const reveal of [
      ".acpmux-file-header:hover .acpmux-fh-chevron",
      ".acpmux-fh-name:focus-visible .acpmux-fh-chevron",
      ".acpmux-fh-name[aria-expanded=false] .acpmux-fh-chevron",
    ])
      expect([reveal, declares(reveal, /opacity:\s*1/)]).toEqual([reveal, true]);
  });

  test("a file tree row's hover is a lighter step than the selected row", () => {
    const value = (name: string) => new RegExp(`${name}:\\s*([^;]+);`).exec(treeUnsafeCSS)?.[1]?.trim();
    expect(value("--trees-bg-muted-override")).toBeDefined();
    expect(value("--trees-bg-muted-override")).not.toBe(value("--trees-selected-bg-override"));
  });
});
