// Component tokens (tier 3; schemas/component-tokens/component-tokens.json): a token named for one
// component family that points at the system token the family drew with before (Leo, 2026-11-22: "we
// need to send out a lot of lanes to make repos of customiztion themes that go broad strokes blank
// cheque on proper redesigns of lots of stuff"). A look's stylesheet (agent-pane/theme.css and the other
// surface sheets) restyles every button, field, menu, tooltip or dialog through a few CSS variables
// (webviews/src/ui/README.md "Component tokens"; docs/cmux-next/theme-recipes.md "Surface tokens"). This
// holds three things:
//   - each token is read only with the fallback the schema names, which is what the rule drew before the
//     token existed, so with no look set nothing moves;
//   - a shadow token sits in a rule of no specificity (`:where(...)`), so a variant's own edge and
//     every focus ring still win over a look's shadow;
//   - the README names every token.
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, test } from "bun:test";

const root = path.resolve(import.meta.dir, "../..");
const readme = readFileSync(path.join(root, "webviews/src/ui/README.md"), "utf8");

type Read = { selector: string; property: string; fallback: string };
type Token = { name: string; kind: string; for: string; reads: Read[] };
type Family = { name: string; file: string; prefix?: string; tokens: Token[] };
const FAMILIES: Family[] = JSON.parse(
  readFileSync(path.join(root, "schemas/component-tokens/component-tokens.json"), "utf8"),
).families;

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

describe("component tokens", () => {
  for (const family of FAMILIES) {
    const css = readFileSync(path.join(root, family.file), "utf8");
    const decls = declarations(css);
    for (const token of family.tokens) {
      test(`${token.name} falls back to what the rule drew before`, () => {
        const reading = decls.filter((d) => new RegExp(`var\\(${token.name}[,)]`).test(d.value));
        expect(reading.map((d) => `${d.selector} { ${d.property} }`).sort()).toEqual(
          token.reads.map((r) => `${r.selector} { ${r.property} }`).sort(),
        );
        for (const read of token.reads) {
          const decl = reading.find((d) => d.selector === read.selector && d.property === read.property);
          expect(decl?.value).toBe(`var(${token.name}, ${read.fallback})`);
        }
      });

      test(`${token.name} is in the README`, () => {
        expect(readme).toContain(`\`${token.name}\``);
      });
    }

    if (family.prefix) {
      test(`no ${family.prefix}* token is read under a name the schema does not know`, () => {
        const known = new Set(FAMILIES.flatMap((f) => f.tokens.map((t) => t.name)));
        const used = new Set([...css.matchAll(new RegExp(`var\\((${family.prefix}[a-z-]+)`, "g"))].map((m) => m[1]));
        expect([...used].filter((name) => !known.has(name))).toEqual([]);
      });
    }

    const shadows = family.tokens.filter((t) => t.kind === "box-shadow").map((t) => t.name);
    if (shadows.length)
      test(`a ${family.name} shadow token is read only at no specificity`, () => {
        for (const d of decls.filter((d) => shadows.some((name) => d.value.includes(name)))) {
          expect(d.selector).toMatch(/^:where\([^)]*\)$/);
        }
      });
  }
});
