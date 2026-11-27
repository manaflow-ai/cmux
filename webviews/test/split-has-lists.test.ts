// HAS-LIST (scripts/postcss/splitHasLists.mjs): no stylesheet ships a selector list with a `:has(...)` in it,
// because the minifier wraps such a list in a forgiving `:is(...)` and WebKit then restyles the pane on every key
// typed in the composer (bench composer-typing WebKit L0: keydown to keypress 2.8 ms, 0.5 without the wrap).
//
// The detector: every stylesheet under src/ through the build's postcss plugins, then Lightning CSS minified at
// Vite's default build targets, has no rule whose whole selector is one `:is(...)` holding a `:has(`.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { Glob } from "bun";
import { transform } from "lightningcss";
import postcss from "postcss";
import focusRingGate from "../scripts/postcss/focusRingGate.mjs";
import splitHasLists, { hasListParts } from "../scripts/postcss/splitHasLists.mjs";

const webviews = path.resolve(import.meta.dir, "..");
// Vite's default build.cssTarget (baseline widely available): Firefox 114 has no `:has`, which is why the
// minifier wraps a list holding one.
const v = (major: number, minor = 0) => (major << 16) | (minor << 8);
const VITE_TARGETS = { chrome: v(111), edge: v(111), firefox: v(114), safari: v(16, 4), ios_saf: v(16, 4) };

/** True when `selector` is a single `:is(...)` around a list with a `:has(` in it: the minifier's wrap. */
export function isWrappedHasList(selector: string): boolean {
  if (!selector.startsWith(":is(") || !selector.includes(":has(")) return false;
  let depth = 0;
  for (let i = 0; i < selector.length; i += 1) {
    if (selector[i] === "(") depth += 1;
    else if (selector[i] === ")" && --depth === 0) return i === selector.length - 1;
  }
  return false;
}

function minified(css: string, from: string): string {
  const gated = postcss([focusRingGate(), splitHasLists()]).process(css, { from }).css;
  return transform({
    code: Buffer.from(gated),
    filename: from,
    minify: true,
    targets: VITE_TARGETS,
    errorRecovery: true,
  }).code.toString();
}

function wrappedRules(css: string): string[] {
  const out: string[] = [];
  postcss.parse(css).walkRules((rule) => {
    if (isWrappedHasList(rule.selector)) out.push(rule.selector);
  });
  return out;
}

describe("split-has-lists", () => {
  test("a list with a :has is written one rule per selector, in order", () => {
    const root = postcss([splitHasLists()]).process(".h:has(.x) .r, .r.on { opacity: 1 } .a, .b { color: red }", {
      from: undefined,
    }).root;
    expect(root.nodes.map((node) => (node as postcss.Rule).selector)).toEqual([".h:has(.x) .r", ".r.on", ".a, .b"]);
  });

  test("a rule with nested rules is left alone", () => {
    const rule = postcss.parse(".a:has(.b), .c { & .d { color: red } }").first as postcss.Rule;
    expect(hasListParts(rule)).toBeUndefined();
  });

  test("the minifier wraps an unsplit list, and not the split one", () => {
    const raw = ".h:has(:focus-visible) .r, .r:focus-visible { --x: 0s }";
    const wrapped = transform({
      code: Buffer.from(raw),
      filename: "a.css",
      minify: true,
      targets: VITE_TARGETS,
    }).code.toString();
    expect(wrappedRules(wrapped)).toHaveLength(1);
    expect(wrappedRules(minified(raw, "a.css"))).toEqual([]);
  });

  test("no stylesheet under src ships a wrapped :has list", () => {
    const found: string[] = [];
    for (const file of new Glob("src/**/*.css").scanSync({ cwd: webviews })) {
      const from = path.join(webviews, file);
      for (const selector of wrappedRules(minified(readFileSync(from, "utf8"), from)))
        found.push(`${file}: ${selector.slice(0, 160)}`);
    }
    expect(found).toEqual([]);
  });
});
