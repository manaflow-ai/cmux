import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { treeUnsafeCSS } from "../diffTheme";

// Every control in the changes view and the edited-files card answers the pointer and the
// keyboard: a hover step, a pressed step and a focus ring from theme tokens, eased with the
// Motion `hover` token, and nothing that moves the layout around it.
const source = ["../styles.css", "./changes.css"]
  .map((path) => readFileSync(new URL(path, import.meta.url), "utf8"))
  .join("\n")
  .replace(/\/\*[\s\S]*?\*\//g, "");

/// The top-level rules in source order; rules inside @media (or any other at-rule) apply only
/// sometimes, so they are left out.
function topLevelRules(css: string) {
  const rules: { selectors: string[]; declarations: [string, string][] }[] = [];
  let depth = 0;
  let start = 0;
  let prelude = "";
  for (let index = 0; index < css.length; index += 1) {
    const char = css[index];
    if (char === "{") {
      if (depth === 0) prelude = css.slice(start, index).trim();
      depth += 1;
      start = index + 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0 && !prelude.startsWith("@")) {
        const body = css.slice(start, index);
        rules.push({
          selectors: prelude.split(",").map((selector) => selector.trim()),
          declarations: body
            .split(";")
            .map((part) => part.split(/:(.*)/s).map((piece) => piece.trim()) as [string, string])
            .filter(([name, value]) => name && value),
        });
      }
      start = index + 1;
    }
  }
  return rules;
}
const rules = topLevelRules(source);

/// The value the last top-level rule for exactly `selector` gives `property`, as the cascade
/// would for rules of one selector.
function value(selector: string, property: string): string | undefined {
  let found: string | undefined;
  for (const rule of rules)
    if (rule.selectors.includes(selector))
      for (const [name, declared] of rule.declarations) if (name === property) found = declared;
  return found;
}
const fills = (selector: string) =>
  [value(selector, "background"), value(selector, "background-color"), value(selector, "color")].some(
    (declared) => declared !== undefined && declared !== "none" && declared !== "inherit",
  );
const ring = (selector: string) => {
  const outline = value(selector, "outline");
  return outline !== undefined && outline !== "none" && outline !== "0";
};

const CONTROLS = [
  ".acpmux-diff-back",
  ".acpmux-diff-tool",
  "button.acpmux-diff-scope",
  ".acpmux-fh-btn",
  ".acpmux-fh-name",
  ".acpmux-file-menu-item",
  ".acpmux-changes-retry",
  ".acpmux-changes-banner-action",
  ".acpmux-changes-banner-refresh",
  ".acpmux-review-changes",
  "button.acpmux-edited-file",
  ".acpmux-edited-more",
  ".acpmux-hunk-undo",
  ".acpmux-hunk-reject",
  ".acpmux-hunk-accept",
  ".acpmux-revert-send",
];
/// Menu rows show focus with the hover fill rather than a ring, as native menus do.
const FOCUS_BY_FILL = new Set([".acpmux-file-menu-item"]);

describe("changes view hover states", () => {
  test("each control has a hover, pressed and focus state, eased with the Motion hover token", () => {
    const missing = CONTROLS.flatMap((control) =>
      [
        fills(`${control}:hover`) ? [] : [`${control}:hover`],
        fills(`${control}:active`) ? [] : [`${control}:active`],
        (FOCUS_BY_FILL.has(control) ? fills(`${control}:focus-visible`) : ring(`${control}:focus-visible`))
          ? []
          : [`${control}:focus-visible`],
        /var\(--acpmux-motion-hover\)/.test(value(control, "transition") ?? "") ? [] : [`${control} transition`],
      ].flat(),
    );
    expect(missing).toEqual([]);
  });

  test("a toggle that is on still answers hover and press, and the file filter shows focus", () => {
    expect(value(".acpmux-diff-tool[aria-pressed=true]:hover", "background")).toBe("var(--acpmux-step-on-hover)");
    // The on toggle's hover rule outranks :active, so its press needs its own rule.
    expect(value(".acpmux-diff-tool[aria-pressed=true]:active", "background")).toBe("var(--acpmux-step-pressed)");
    expect(value(".acpmux-diff-filter:hover", "border-color")).toBeDefined();
    expect(value(".acpmux-diff-filter:focus-within", "border-color")).toContain("--agent-accent");
  });

  test("pressed is a deeper step than hover on the control's own base", () => {
    // A light hover over the transcript presses lightly, not a flash to the toolbar's step.
    expect(value("button.acpmux-edited-file:active", "background")).toBe(
      "color-mix(in srgb,var(--agent-text) 9%,transparent)",
    );
    // Controls filled over the page press over the page, so the step is opaque like their rest.
    for (const control of [
      "button.acpmux-diff-scope",
      ".acpmux-changes-retry",
      ".acpmux-changes-banner-action",
      ".acpmux-review-changes",
      ".acpmux-edited-more",
    ])
      expect([control, value(`${control}:active`, "background")]).toEqual([
        control,
        "var(--acpmux-step-pressed-on-page)",
      ]);
  });

  test("the file header's chevron fades in without moving the badges beside the name", () => {
    expect([value(".acpmux-fh-chevron", "display"), value(".acpmux-fh-chevron", "opacity")]).toEqual(["block", "0"]);
    for (const reveal of [
      ".acpmux-file-header:hover .acpmux-fh-chevron",
      ".acpmux-fh-name:focus-visible .acpmux-fh-chevron",
      ".acpmux-fh-name[aria-expanded=false] .acpmux-fh-chevron",
    ])
      expect([reveal, value(reveal, "opacity")]).toEqual([reveal, "1"]);
  });

  test("a file tree row's hover is a lighter step of the pane's text color than the selected row", () => {
    const step = (name: string) => {
      const declared = new RegExp(`${name}:\\s*([^;]+);`).exec(treeUnsafeCSS)?.[1] ?? "";
      return Number(/var\(--agent-text[^)]*\)\s+(\d+)%/.exec(declared)?.[1] ?? Number.NaN);
    };
    expect(step("--trees-bg-muted-override")).toBeLessThan(step("--trees-selected-bg-override"));
  });
});
