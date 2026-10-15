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

  test("every row step's width has its container query", () => {
    const rowWidths = [
      ...new Set(ROW_FIT_STEPS.map(({ step }) => COMPOSER_FIT_STEPS[step])),
      COMPOSER_FIT_STEPS.rowTight,
      COMPOSER_FIT_STEPS.barTight,
    ];
    expect(rowWidths.filter((width) => !blocks.some((block) => block.width === width))).toEqual([]);
  });
});
