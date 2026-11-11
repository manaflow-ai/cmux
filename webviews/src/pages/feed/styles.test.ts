// An approval's command keeps its line breaks: with whitespace collapsed, `echo safe\nrm -rf ./important`
// reads as one harmless echo right above Allow.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "styles.css"), "utf8");

function rule(selector: string): string {
  const start = css.indexOf(`${selector} {`);
  expect(start, selector).toBeGreaterThanOrEqual(0);
  return css.slice(start, css.indexOf("}", start));
}

test("an approval's command keeps its line breaks and spacing", () => {
  expect(rule(".feed-code-text")).toMatch(/white-space:\s*pre-wrap;/);
});
