// Surface tokens a look sets (Leo, 2026-11-22: "we need to send out a lot of lanes to make repos of
// customiztion themes that go broad strokes blank cheque on proper redesigns of lots of stuff"). A
// look's stylesheet (agent-pane/theme.css and the other surface sheets) restyles every button and
// field through a few CSS variables (ui/controls.css THEME HOOKS; docs/cmux-next/theme-recipes.md
// "Surface tokens"). This holds three things:
//   - each token is read only with the fallback below, which is what the rule drew before the token
//     existed, so with no look set nothing moves;
//   - a shadow token sits in a rule of no specificity (`:where(...)`), so a variant's own edge and
//     every focus ring still win over a look's shadow;
//   - the page that documents the tokens names every one of them.
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";

const root = path.resolve(import.meta.dir, "../..");
const controls = readFileSync(path.join(root, "webviews/src/ui/controls.css"), "utf8");
const docs = readFileSync(path.join(root, "docs/cmux-next/theme-recipes.md"), "utf8");

/** Each token, the selector of every rule that reads it, and the value that rule drew before. */
const TOKENS: { name: string; reads: { selector: string; property: string; fallback: string }[] }[] = [
  {
    name: "--cmux-button-radius",
    reads: [
      { selector: ".ui-button.ui-btn", property: "border-radius", fallback: "var(--ds-radius-control)" },
      { selector: '.ui-btn[data-size="sm"]', property: "border-radius", fallback: "var(--ds-radius-control)" },
      { selector: '.ui-btn[data-size="lg"]', property: "border-radius", fallback: "var(--ds-radius-control)" },
    ],
  },
  {
    name: "--cmux-button-border",
    reads: [{ selector: ".ui-button.ui-btn", property: "border", fallback: "0" }],
  },
  {
    name: "--cmux-button-shadow",
    reads: [{ selector: ":where(.ui-btn)", property: "box-shadow", fallback: "none" }],
  },
  {
    name: "--cmux-input-radius",
    reads: [
      { selector: ".ui-input", property: "border-radius", fallback: "var(--ds-radius-md)" },
      { selector: '.ui-input[data-size="sm"]', property: "border-radius", fallback: "var(--ds-radius-sm)" },
      { selector: '.ui-input[data-size="lg"]', property: "border-radius", fallback: "var(--ds-radius-lg)" },
    ],
  },
  {
    name: "--cmux-input-border",
    reads: [{ selector: ".ui-input", property: "border", fallback: "0" }],
  },
  {
    name: "--cmux-input-shadow",
    reads: [{ selector: ":where(.ui-input)", property: "box-shadow", fallback: "none" }],
  },
];

type Decl = { selector: string; property: string; value: string };

/** Every top-level rule's declarations (controls.css has no nesting and no at-rule around these). */
function declarations(css: string): Decl[] {
  const out: Decl[] = [];
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rule = /([^{}]+)\{([^{}]*)\}/g;
  for (const match of text.matchAll(rule)) {
    const selector = match[1].trim().replace(/\s+/g, " ");
    for (const part of match[2].split(";")) {
      const colon = part.indexOf(":");
      if (colon < 0) continue;
      out.push({ selector, property: part.slice(0, colon).trim(), value: part.slice(colon + 1).trim() });
    }
  }
  return out;
}

const decls = declarations(controls);

describe("surface tokens", () => {
  for (const token of TOKENS) {
    test(`${token.name} falls back to what the rule drew before`, () => {
      const reading = decls.filter((d) => d.value.includes(token.name));
      expect(reading.map((d) => `${d.selector} { ${d.property} }`).sort()).toEqual(
        token.reads.map((r) => `${r.selector} { ${r.property} }`).sort(),
      );
      for (const read of token.reads) {
        const decl = reading.find((d) => d.selector === read.selector && d.property === read.property);
        expect(decl?.value).toBe(`var(${token.name}, ${read.fallback})`);
      }
    });

    test(`${token.name} is on the theme recipes page`, () => {
      expect(docs).toContain(`\`${token.name}\``);
    });
  }

  test("a shadow token is read only at no specificity", () => {
    for (const d of decls.filter((d) => /--cmux-(button|input)-shadow/.test(d.value))) {
      expect(d.selector).toMatch(/^:where\([^)]*\)$/);
    }
  });

  test("no token is read under a name the table does not know", () => {
    const known = new Set(TOKENS.map((t) => t.name));
    const used = new Set([...controls.matchAll(/var\((--cmux-(?:button|input)-[a-z-]+)/g)].map((m) => m[1]));
    expect([...used].filter((name) => !known.has(name))).toEqual([]);
  });
});
