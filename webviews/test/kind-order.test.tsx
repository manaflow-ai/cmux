// The delineated diff reorders the file column once the stream settles, and the file the reader is
// on must stay under them. That only works if the anchor is measured in the order on screen and
// restored after the new order is in the DOM — two commits, not one. The first attempt flushed the
// reorder with `flushSync` inside the effect that measured it; React skips a flush from inside its
// own commit, so the restore ran against the old order and dropped the reader onto another file
// (2026-10-20 review of #22951). These tests fail on that shape: `restored` sees the old column.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
// Type-only: the hook itself is imported inside the test, after the DOM globals are in place.
import type { KindOrderHandlers } from "../src/diff-viewer/useKindOrder";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const UNGROUPED = "a.ts,bun.lock,a.test.ts";
const GROUPED = "a.ts,a.test.ts,bun.lock";

/**
 * Renders the file column in one of the two orders and records, for every call the hook makes,
 * what the column read at that moment.
 */
async function column(options: { scrolled?: boolean } = {}) {
  const { act, createElement, useRef } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { useKindOrder } = await import("../src/diff-viewer/useKindOrder");
  const seen: string[] = [];
  const text = () => dom.window.document.getElementById("column")?.textContent ?? "";
  function Column({ enabled, ready }: { enabled: boolean; ready: boolean }) {
    const handlers = useRef<KindOrderHandlers>({
      anchor: () => {
        seen.push(`measured in ${text()}`);
        return options.scrolled === false ? "" : "a.test.ts";
      },
      restore: (itemId) => seen.push(`restored ${itemId} in ${text()}`),
    });
    const grouped = useKindOrder({ enabled, ready, handlers });
    return createElement("div", { id: "column" }, grouped ? GROUPED : UNGROUPED);
  }
  const element = dom.window.document.getElementById("root")!;
  const root = createRoot(element);
  const show = async (enabled: boolean, ready: boolean) => {
    await act(async () => root.render(createElement(Column, { enabled, ready })));
  };
  return { seen, show, text, unmount: () => act(async () => root.unmount()) };
}

test("the reorder measures the reader's file in the old order and restores it in the new one", async () => {
  const { seen, show, text, unmount } = await column();
  // The diff is still streaming: grouping it would insert each new file into what is being read.
  await show(true, false);
  expect(text()).toBe(UNGROUPED);
  expect(seen).toEqual([]);
  // The last file arrives: the column reorders, and the reader's file comes back under them.
  await show(true, true);
  expect(text()).toBe(GROUPED);
  expect(seen).toEqual([`measured in ${UNGROUPED}`, `restored a.test.ts in ${GROUPED}`]);
  await unmount();
});

test("turning the grouping off keeps the reader's place too", async () => {
  const { seen, show, text, unmount } = await column();
  await show(true, true);
  seen.length = 0;
  await show(false, true);
  expect(text()).toBe(UNGROUPED);
  expect(seen).toEqual([`measured in ${GROUPED}`, `restored a.test.ts in ${UNGROUPED}`]);
  await unmount();
});

test("a reader who has not scrolled into the diff has nothing to restore", async () => {
  const { seen, show, text, unmount } = await column({ scrolled: false });
  await show(true, false);
  await show(true, true);
  expect(text()).toBe(GROUPED);
  expect(seen).toEqual([`measured in ${UNGROUPED}`]);
  await unmount();
});
