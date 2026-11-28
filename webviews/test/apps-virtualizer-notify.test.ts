// The App Store's catalog holds back TanStack Virtual's private `notify` while it resizes a batch of
// grid rows (src/pages/apps/AppsPage.tsx, the cards' ResizeObserver), so a width step draws the
// catalog once instead of once per row above the view. `notify` is not public API. A TanStack
// without it still works (the page resizes rows one at a time, as before the batching), but the
// batching is then lost without a sound: this test fails first, on a real virtualizer of the
// installed package.
import { expect, test } from "bun:test";
import { Virtualizer, elementScroll, observeElementOffset, observeElementRect } from "@tanstack/react-virtual";
import { notifiesPrivately } from "../src/pages/apps/AppsPage";

const RECHECK =
  "@tanstack/react-virtual's Virtualizer has no `notify` method any more (a TanStack upgrade?). " +
  "src/pages/apps/AppsPage.tsx batches a grid's row resizes by swapping it (`notifiesPrivately`, " +
  "the cards' ResizeObserver); without it the catalog falls back to one draw per resized row. " +
  "Re-check in the new virtual-core that `resizeItem` still redraws through a per-instance " +
  "`notify(sync)` (or find what replaced it), then update the swap and this test.";

test("a real TanStack virtualizer has the private `notify` the App Store catalog batches", () => {
  const virtualizer = new Virtualizer<HTMLElement, HTMLElement>({
    count: 10,
    getScrollElement: () => null,
    estimateSize: () => 50,
    scrollToFn: elementScroll,
    observeElementRect,
    observeElementOffset,
  });
  const notify = (virtualizer as unknown as { notify?: unknown }).notify;
  if (typeof notify !== "function") throw new Error(`${RECHECK} (found: ${typeof notify})`);
  // The page swaps it on the instance: it must be the instance's own field, read at each call.
  if (!Object.prototype.hasOwnProperty.call(virtualizer, "notify"))
    throw new Error(`${RECHECK} (found: \`notify\` is not the instance's own field)`);
  expect(notifiesPrivately(virtualizer)).toBe(true);
});

test("the page's check refuses a virtualizer without a callable `notify`", () => {
  expect(notifiesPrivately({})).toBe(false);
  expect(notifiesPrivately({ notify: true })).toBe(false);
  expect(notifiesPrivately({ notify: () => undefined })).toBe(true);
});
