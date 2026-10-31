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
        // 820 pixels into a.test.ts: the reorder has to keep the offset too, not just the file.
        return options.scrolled === false ? null : { itemId: "a.test.ts", offset: 820 };
      },
      restore: (anchor) => seen.push(`restored ${anchor.itemId}+${anchor.offset} in ${text()}`),
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
  expect(seen).toEqual([`measured in ${UNGROUPED}`, `restored a.test.ts+820 in ${GROUPED}`]);
  await unmount();
});

test("turning the grouping off keeps the reader's place too", async () => {
  const { seen, show, text, unmount } = await column();
  await show(true, true);
  seen.length = 0;
  await show(false, true);
  expect(text()).toBe(UNGROUPED);
  expect(seen).toEqual([`measured in ${GROUPED}`, `restored a.test.ts+820 in ${UNGROUPED}`]);
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

// The reader's place inside the file, not just which file it is. Before this the restore scrolled
// the anchor file to the top of the viewport, so a reader 800 pixels into a long file was thrown
// back to its first line by a reorder they did not ask for. A kind reorder moves files past each
// other and never changes a file's own height, so the pixels of it above the viewport are exactly
// as good after the reorder as before: that is the anchor.
test("the anchor carries how far into the file the reader is, and the restore puts it back", async () => {
  const { itemScrollAnchor, itemScrollTarget } = await import("../src/diff-viewer/item-navigation");
  // The viewer says a.test.ts starts at 4,000 and the reader is at 4,820: 820 into the file.
  const tops: Record<string, number> = { "a.ts": 0, "bun.lock": 2_000, "a.test.ts": 4_000 };
  const anchor = itemScrollAnchor("a.test.ts", 4_820, (id) => tops[id]);
  expect(anchor).toEqual({ itemId: "a.test.ts", offset: 820 });
  // After the reorder the same file starts at 1,500; the reader belongs at 2,320, not at 1,500.
  // Pierre resolves an item target at align "start" to `top - offset`
  // (CodeView.resolveAlignedScrollPosition), which is what fixes the sign here.
  const target = itemScrollTarget(anchor!);
  expect(1_500 - (target.offset ?? 0)).toBe(2_320);
  expect(target).toMatchObject({ type: "item", id: "a.test.ts", align: "start", behavior: "instant" });
});

test("a file the viewer cannot measure anchors at its top, and no file anchors at all", async () => {
  const { itemScrollAnchor, itemScrollTarget } = await import("../src/diff-viewer/item-navigation");
  // Not measured yet (it has never been near the viewport): the file's top is the honest answer,
  // which is what the restore did for every file before the offset existed.
  expect(itemScrollAnchor("a.ts", 900, () => undefined)).toEqual({ itemId: "a.ts", offset: 0 });
  // Above the file's own top, which the binary search should never return: clamped rather than
  // scrolled backwards into the file before it.
  expect(itemScrollAnchor("a.ts", 10, () => 400)).toEqual({ itemId: "a.ts", offset: 0 });
  expect(itemScrollAnchor("", 900, () => 0)).toBeNull();
  expect(itemScrollTarget({ itemId: "a.ts", offset: 0 }).offset).toBe(0);
});
