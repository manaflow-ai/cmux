// POLISH rows are 26–28 px: Settings rows sit in that range in both looks (cx-bopcl).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "layout.css"), "utf8");

test("every Settings look sets its row minimum in the POLISH range", () => {
  const values = [...css.matchAll(/--row-min:\s*(\d+)px/g)].map((match) => Number(match[1]));
  expect(values.length).toBeGreaterThanOrEqual(2);
  for (const value of values) expect(value).toBeGreaterThanOrEqual(26);
  for (const value of values) expect(value).toBeLessThanOrEqual(28);
});
