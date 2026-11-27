// The composer row's steps live in one table (composerRowFit.ts COMPOSER_FIT_STEPS), but container
// queries cannot read a variable: composerLocation.css repeats the widths as literals. Every
// `@container composer` width in it is a width of the table, and every step of the row's
// collapse order (ROW_FIT_STEPS) is applied at its width.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { COMPOSER_FIT_STEPS, ROW_FIT_STEPS } from "../src/agent-session/acpmux/composerRowFit";

const css = fs.readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8");

/** Each `@container composer (max-width: Npx) { ... }` block: its width and its body. */
function containerBlocks(text: string): { width: number; body: string }[] {
  const blocks: { width: number; body: string }[] = [];
  const query = /@container\s+composer\s*\(\s*max-width:\s*(\d+(?:\.\d+)?)px\s*\)\s*\{/g;
  for (let match = query.exec(text); match; match = query.exec(text)) {
    let depth = 1;
    let index = query.lastIndex;
    while (depth > 0 && index < text.length) {
      if (text[index] === "{") depth++;
      else if (text[index] === "}") depth--;
      index++;
    }
    blocks.push({ width: Number(match[1]), body: text.slice(query.lastIndex, index - 1) });
  }
  return blocks;
}

describe("composer fit steps", () => {
  const blocks = containerBlocks(css);
  const widths = new Set<number>(Object.values(COMPOSER_FIT_STEPS));

  test("every pane container query is a width of the table", () => {
    expect(blocks.length).toBeGreaterThan(0);
    expect(blocks.map((block) => block.width).filter((width) => !widths.has(width))).toEqual([]);
  });

  test("every step of the row is applied at its width", () => {
    const missing = ROW_FIT_STEPS.filter(({ step, unit, to }) => {
      const selector = `[data-fit-part="${unit}"]:not([data-fit-forms~="${to}"])`;
      return !blocks.some((block) => block.width === COMPOSER_FIT_STEPS[step] && block.body.includes(selector));
    }).map(({ step }) => step);
    expect(missing).toEqual([]);
  });

  test("a width step skips the quiet row without outranking the hiding rules", () => {
    // The guard skips the plain quiet row only: ComposerFoot draws the same
    // `.acpmux-composer-bar.acpmux-composer-foot` in both footer looks, so it reads
    // `data-footer-look` on that element, and with the plain footer off the row still takes every
    // step. New Tab's row takes the steps in either footer look.
    // The steps come after the rules that lay a part of another form out of the row, so they must stay
    // less specific than those: the row's measured fit (#24151, data-fit-model="icon" at a width whose
    // step only asks for "family") has to keep winning. A bare `:not([data-footer-look="plain"])` adds
    // an attribute, ties the hiding rule at (0,4,0) and brings back a label the fit had taken away.
    const GUARD = ':where(:not(.acpmux-composer-foot[data-footer-look="plain"]))';
    const bare = blocks
      .filter(({ body }) =>
        /:not\((\.acpmux-composer-foot)?\[data-footer-look="plain"\]\)/.test(body.replaceAll(GUARD, "")),
      )
      .map(({ width }) => width);
    expect(bare, `use ${GUARD}, which adds no specificity`).toEqual([]);
    // Every rule that lays a label out of the row carries the guard. The widths' other rules (the
    // row's gaps and insets) are the row's spacing, which both looks take.
    const unguarded = blocks
      .filter(({ body }) =>
        body
          .split("}")
          .some(
            (rule) =>
              rule.includes("[data-fit-part=") && rule.includes(".acpmux-composer-bar") && !rule.includes(GUARD),
          ),
      )
      .map(({ width }) => width);
    expect(unguarded, "every label step skips the quiet row").toEqual([]);
    // And the element itself is never the guard: that would skip the steps in both looks.
    expect(
      blocks.filter(({ body }) => /:not\(\.acpmux-composer-foot\)/.test(body)).map(({ width }) => width),
      "the quiet row is the plain look, not .acpmux-composer-foot",
    ).toEqual([]);
  });

  test("every row step's width has its container query", () => {
    const rowWidths = [
      ...new Set(ROW_FIT_STEPS.map(({ step }) => COMPOSER_FIT_STEPS[step])),
      COMPOSER_FIT_STEPS.rowTight,
      COMPOSER_FIT_STEPS.barTight,
      COMPOSER_FIT_STEPS.newTabModelMark,
    ];
    expect(rowWidths.filter((width) => !blocks.some((block) => block.width === width))).toEqual([]);
  });
});
