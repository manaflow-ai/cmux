// The summary card's body fades the edge that has rows past it (summary/scrollEdges.ts): under
// macOS's hidden scrollbars the fade is the only sign a capped card scrolls.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";

const scope = globalThis as Record<string, unknown>;
const saved = ["ResizeObserver", "MutationObserver"].map((key) => [key, scope[key]] as const);
let window: JSDOM["window"];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=body></div>").window;
  scope.ResizeObserver = class {
    observe() {}
    disconnect() {}
  };
  scope.MutationObserver = window.MutationObserver;
});

afterAll(() => {
  for (const [key, value] of saved) scope[key] = value;
  window.close();
});

const sized = (scrollHeight: number, clientHeight: number) => {
  const node = window.document.getElementById("body")!;
  Object.defineProperty(node, "scrollHeight", { configurable: true, value: scrollHeight });
  Object.defineProperty(node, "clientHeight", { configurable: true, value: clientHeight });
  Object.defineProperty(node, "scrollTop", { configurable: true, value: 0 });
  return node;
};

test("rows below a capped card fade its bottom edge, and scrolling to the end moves it to the top", async () => {
  const { followScrollEdges } = await import("../src/agent-session/acpmux/summary/scrollEdges");
  const node = sized(600, 200);
  const stop = followScrollEdges(node);
  expect([node.hasAttribute("data-fade-top"), node.hasAttribute("data-fade-bottom")]).toEqual([false, true]);
  Object.defineProperty(node, "scrollTop", { configurable: true, value: 400 });
  node.dispatchEvent(new window.Event("scroll"));
  expect([node.hasAttribute("data-fade-top"), node.hasAttribute("data-fade-bottom")]).toEqual([true, false]);
  stop();
});

test("a card whose rows all fit fades neither edge", async () => {
  const { followScrollEdges } = await import("../src/agent-session/acpmux/summary/scrollEdges");
  const node = sized(200, 200);
  followScrollEdges(node)();
  expect([node.hasAttribute("data-fade-top"), node.hasAttribute("data-fade-bottom")]).toEqual([false, false]);
});

test("the card body is the scroller that follows its edges, and Reduce Transparency drops the fade", () => {
  const dir = path.join(import.meta.dir, "../src/agent-session/acpmux/summary");
  expect(readFileSync(path.join(dir, "SummaryCard.tsx"), "utf8")).toContain(
    '<div className="acpmux-summary-card__body" ref={edges}>',
  );
  const css = readFileSync(path.join(dir, "summary.css"), "utf8");
  expect(css).toContain(".acpmux-summary-card__body[data-fade-bottom]{--acpmux-summary-fade-bottom:22px}");
  expect(css).toContain(":root[data-reduce-transparency] .acpmux-summary-card__body[data-fade-top]");
});
