import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { inlineChatFloor } from "../src/agent-session/acpmux/summary/cardState";

const css = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/summary/summary.css"), "utf8");

test("summary keeps inline and popover geometry separate", () => {
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]");
  expect(css).toContain(".acpmux-summary-card[data-placement=popover]");
  // Both slide in from the right (ui/presence.ts); the inline column travels its own width.
  expect(css).toContain(".acpmux-summary-card[data-placement=inline]{--ui-enter-distance:100%}");
  expect(css).toContain(".acpmux-summary-card[data-placement=inline] .acpmux-summary-card__body");
});

// Leo, 2026-10-20: with the summary column open, the column ran ~95px past the window's right
// edge. The shell was `overflow: hidden`, which still scrolls from script: a `scrollIntoView` or a
// focus anywhere in the pane can scroll it sideways, sliding the column past the edge with no way
// back. `overflow: clip` cuts the same way but never scrolls.
test("the pane's shell clips and cannot be scrolled sideways", () => {
  const styles = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");
  const shell = /\.acpmux-shell\{position:relative;[^}]*\}/.exec(styles)?.[0] ?? "";
  expect(shell).toContain("overflow:clip");
});

test("the inline summary keeps the chat's whole Chat Text Width column, at the effective page scale", () => {
  // The default 800px column at 1.25x zoom: its 640 CSS px cap, above the 528 readable floor.
  expect(inlineChatFloor({ min: 720 / 1.25, max: 800 / 1.25 }, 1.25)).toBe(640);
  // A narrow Chat Text Width keeps the readable floor; Full Width has no cap and keeps the floor too.
  expect(inlineChatFloor({ min: 480, max: 480 }, 1)).toBe(660);
  expect(inlineChatFloor({ min: 0, max: Infinity }, 1.25)).toBe(528);
  expect(inlineChatFloor({ min: 720, max: 960 }, 1)).toBe(960);
});

test("summary room measurement reruns when the effective page scale changes", () => {
  const source = readFileSync(path.join(import.meta.dir, "../src/agent-session/acpmux/summary/cardState.ts"), "utf8");
  expect(source).toContain("const { scale } = useChatSizing();");
  expect(source).toContain("[shell, blocked, display, scale]");
  expect(source).toContain("inlineChatFloor(chatColumnOf(display, scale), scale)");
});
