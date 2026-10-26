import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const src = resolve(import.meta.dir, "../src/agent-session/acpmux");
const chat = readFileSync(resolve(src, "markdownField.css"), "utf8");
const newTab = readFileSync(resolve(src, "newtab/screen.css"), "utf8");

test("all composer fields share the Goldilocks twelve-line, forty-percent cap", () => {
  expect(chat).toContain("* 12 + var(--cmux-control-height, 23px)");
  expect(chat).toContain("min(calc(");
  expect(newTab).toContain("12 * 1lh + 32px");
  expect(newTab).toContain("min(calc(");
});
