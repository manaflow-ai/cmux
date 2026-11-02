// HQ#5914: a tab reopening a chat adopted the host's prewarmed page while Chromium held that page
// hidden. The page's paint report waited for an animation frame, which a hidden document never
// runs, and the host kept the page covered (and so hidden) until the report: the cover stayed for
// the ~15 s give-up on every reopen. The report runs on a task when the page is hidden
// (acpmux/paintReport.ts).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { afterDrawnFrame } from "../src/agent-session/acpmux/paintReport";

/// A document whose visibility the test sets, with animation frames it runs by hand.
function page(visibility: "visible" | "hidden") {
  const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const doc = dom.window.document;
  let state = visibility;
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => state });
  const frames: Array<() => void> = [];
  (dom.window as unknown as { requestAnimationFrame: (run: () => void) => number }).requestAnimationFrame = (run) =>
    frames.push(run);
  return {
    doc,
    frames,
    hide() {
      state = "hidden";
      doc.dispatchEvent(new dom.window.Event("visibilitychange"));
    },
  };
}

/// The next task: the report runs on the task its frame (or its hidden page) queued, which comes first.
const task = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a hidden page reports its paint although it draws no frame", async () => {
  const hidden = page("hidden");
  let reports = 0;
  afterDrawnFrame(() => (reports += 1), hidden.doc);
  await task();
  expect(hidden.frames).toHaveLength(0);
  expect(reports).toBe(1);
});

test("a shown page reports after the frame that drew it, on the task after it", async () => {
  const shown = page("visible");
  let reports = 0;
  afterDrawnFrame(() => (reports += 1), shown.doc);
  await task();
  expect(reports).toBe(0);
  expect(shown.frames).toHaveLength(1);
  shown.frames[0]!();
  expect(reports).toBe(0);
  await task();
  expect(reports).toBe(1);
});

test("a page hidden while it waits for its frame reports once, then not again when the frame comes", async () => {
  const shown = page("visible");
  let reports = 0;
  afterDrawnFrame(() => (reports += 1), shown.doc);
  shown.hide();
  await task();
  expect(reports).toBe(1);
  shown.frames[0]!();
  await task();
  expect(reports).toBe(1);
});
