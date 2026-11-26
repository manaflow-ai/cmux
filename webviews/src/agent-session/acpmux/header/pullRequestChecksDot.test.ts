import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// The dot beside the PR number is green, amber or red by its checks. The amber and red
// rules must not rank below the green one, or every dot is green.
const css = readFileSync(join(import.meta.dir, "header.css"), "utf8");

/** [ids, classes and attributes, elements] of one selector with no commas. */
function specificity(selector: string): [number, number, number] {
  const ids = selector.match(/#[\w-]+/g)?.length ?? 0;
  const attributes = selector.match(/\[[^\]]*\]/g)?.length ?? 0;
  const classes = selector.match(/\.[\w-]+/g)?.length ?? 0;
  const pseudoElements = selector.match(/::[\w-]+/g)?.length ?? 0;
  return [ids, attributes + classes, pseudoElements];
}

function dotRule(match: (selector: string) => boolean): { selector: string; at: number } {
  const rules = [...css.matchAll(/^(\.acpmux-header-pr\[data-checks[^{]*::after)\{/gm)];
  const rule = rules.find((found) => match(found[1] ?? ""));
  if (!rule) throw new Error("the checks dot rule is missing from header.css");
  return { selector: rule[1] ?? "", at: rule.index ?? 0 };
}

function outranks(later: { selector: string; at: number }, base: { selector: string; at: number }): boolean {
  const a = specificity(later.selector);
  const b = specificity(base.selector);
  for (let i = 0; i < 3; i += 1) {
    if (a[i] !== b[i]) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return later.at > base.at;
}

describe("the PR chip's checks dot", () => {
  const base = dotRule((selector) => selector.includes(":not([data-checks=none])"));
  for (const state of ["pending", "failing"]) {
    test(`is not green while checks are ${state}`, () => {
      const rule = dotRule((selector) => selector.includes(`[data-checks=${state}]`));
      expect(outranks(rule, base)).toBe(true);
    });
  }
});
