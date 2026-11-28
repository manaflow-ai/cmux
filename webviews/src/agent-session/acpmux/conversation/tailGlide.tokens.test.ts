// A tail glide's clock reads its motion tokens through getComputedStyle once per page and theme
// (motionTokens.ts), not once per streamed record: read in the commit's layout pass after its writes,
// each read recalculated the page's style (vfp95: style forced by script 256 ms per 30 s of replay).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { arriveTiming, timing } from "./tailGlide";

function page() {
  const dom = new JSDOM(
    "<!doctype html><html><head><style>.thread{--agent-motion-arrive:123ms;--cmux-motion-settle:267ms;--cmux-ease-settle:ease;--agent-motion-in:91ms;--agent-ease-out:ease-out}</style></head><body><div class=thread></div></body></html>",
  );
  const view = dom.window;
  const thread = view.document.querySelector<HTMLElement>(".thread")!;
  let reads = 0;
  const real = view.getComputedStyle.bind(view);
  view.getComputedStyle = ((node: Element) => {
    reads += 1;
    return real(node);
  }) as typeof view.getComputedStyle;
  return { view, thread, reads: () => reads };
}

test("a glide per streamed record reads the thread's style once per token, not per record", () => {
  const { thread, reads } = page();
  const first = timing(thread, "arrive", 40);
  for (let record = 0; record < 200; record += 1) {
    expect(timing(thread, "arrive", 40)).toEqual(first);
    timing(thread, "glide", 40);
    timing(thread, "quick", 40);
    arriveTiming(thread, 40);
  }
  // Five tokens, each read once: 800 clocks forced no style.
  expect(reads()).toBeLessThanOrEqual(5);
  expect(first.ms).toBeGreaterThan(0);
});

test("a change of the root's inline tokens reads them again", () => {
  const { thread, reads, view } = page();
  timing(thread, "arrive", 40);
  const before = reads();
  view.document.documentElement.setAttribute("style", "--agent-motion-arrive: 0ms");
  thread.style.setProperty("--agent-motion-arrive", "0ms");
  expect(timing(thread, "arrive", 40).ms).toBe(0);
  expect(reads()).toBe(before + 1);
});
