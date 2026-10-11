// The page's layout at pane widths, from the two stylesheets in cascade order (styles.css, then
// layout.css). Regression: layout.css set the two-column grid after styles.css's narrow rule, so a
// pane under 600 px kept two columns while the sidebar took the stacked layout's 40vh cap and
// bottom edge: the categories were cut off and the column overlapped them in short panes.
import { expect, test } from "bun:test";
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
