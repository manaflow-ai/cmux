import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/summary/summary.css"), "utf8");

test("summary keeps inline and popover geometry separate", () => {
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]");
  expect(css).toContain(".acpmux-summary-card[data-placement=popover]");
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]{position:relative");
  expect(css).toContain("border-radius:0");
  expect(css).toContain("box-shadow:none");
  expect(css).toContain("@keyframes acpmux-summary-popover-in");
  expect(css).toContain(".acpmux-summary-card[data-placement=inline] .acpmux-summary-card__body");
});
