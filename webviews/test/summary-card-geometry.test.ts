import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/summary/summary.css"), "utf8");

test("summary keeps inline and popover geometry separate", () => {
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]");
  expect(css).toContain(".acpmux-summary-card[data-placement=popover]");
  // Both slide in from the right (ui/presence.ts); the inline column travels its own width.
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]{--ui-enter-distance:100%}");
  expect(css).toContain(".acpmux-summary-card[data-placement=inline] .acpmux-summary-card__body");
});
