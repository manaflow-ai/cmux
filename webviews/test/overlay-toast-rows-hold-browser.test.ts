// A stack of toasts taller than the room above the composer gives up its Details' height, never a
// toast's title row. Each toast was a flex column with min-height: 0, so in a short window an open
// Details squeezed the collapsed toasts beside it below their row: their Undo and close buttons
// drew outside the toast's rect, the one the page reports for the native click regions, so they
// overlapped the next toast and took no clicks (review of #37289 at a3f8a3de, F1). Laid out by
// Chromium from the real toasts.css and the design scale's tokens (pages/shared/desktop.css), in a
// stack shorter than its content:
// - every toast is at least as tall as its title row, and its buttons stay inside its rect;
// - the open toast's Details shrink and scroll instead;
// - when even the title rows do not fit above the floor, every toast stays on the page: the stack
//   runs on down over the floor, never off the page's top (review of #37289 at 74444fd5, F1: three
//   collapsed three-line toasts over a 140 px floor in a 300 px page put the oldest at -66 px).
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("overlay-toast-rows-hold-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("overlay-toast-rows-hold-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("overlay toast rows hold", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "pages/overlay/toasts/toasts.css"]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  /** Each toast's box, its title row's height and its buttons' boxes, in the page. */
  const measure = () =>
    [...document.querySelectorAll<HTMLElement>(".cmux-toast")].map((toast) => {
      const box = toast.getBoundingClientRect();
      const rowBox = toast.querySelector(".cmux-toast-row")!.getBoundingClientRect();
      const buttons = [...toast.querySelectorAll("button")].map((b) => b.getBoundingClientRect());
      const detail = toast.querySelector<HTMLElement>(".cmux-toast-detail");
      return {
        top: box.top,
        bottom: box.bottom,
        rowHeight: rowBox.height,
        buttons: buttons.map((b) => ({ top: b.top, bottom: b.bottom })),
        detailScrolls: detail ? detail.scrollHeight > detail.clientHeight + 1 : null,
      };
    });
  type Measured = ReturnType<typeof measure>;
  const page = (floor: number, toasts: string) =>
    `<html><head><style>body { margin: 0 } ${css}</style></head><body>` +
    `<div class="cmux-toasts" style="bottom: ${floor}px">${toasts}</div></body></html>`;
  const expectRowsHold = (toasts: Measured) => {
    for (const toast of toasts) {
      expect(toast.bottom - toast.top).toBeGreaterThanOrEqual(toast.rowHeight - 0.5);
      for (const b of toast.buttons) {
        expect(b.top).toBeGreaterThanOrEqual(toast.top - 0.5);
        expect(b.bottom).toBeLessThanOrEqual(toast.bottom + 0.5);
      }
    }
  };
  const button = (label: string) =>
    `<button class="cmux-toast-action" style="height: 28px; padding: 0 8px">${label}</button>`;
  const row = (message: string) =>
    `<div class="cmux-toast-row"><p class="cmux-toast-message">${message}</p>${button("Undo")}` +
    `<button class="cmux-toast-close" style="width: 28px; height: 28px">×</button></div>`;
  const collapsed = (message: string) => `<section class="cmux-toast">${row(message)}</section>`;
  const detail = Array.from({ length: 40 }, (_, line) => `Line ${line + 1} of the reason.`).join("\n");
  const open =
    `<section class="cmux-toast" data-open>${row("Couldn’t update cmux-tui on dev.")}` +
    `<div class="cmux-toast-detail"><p class="cmux-toast-detail-text">${detail}</p></div></section>`;

  test("a short stack shrinks only the open Details", async () => {
    // A short window: the stack (100 px over its 20 px floor) is shorter than its three toasts, the
    // open one's Details already capped at 40% of the window.
    const page_ = await browser.newPage({ viewport: { width: 600, height: 120 } });
    try {
      // The stack spans the page above its floor (`bottom`), as the app draws it.
      await page_.setContent(page(20, collapsed("Archived 3 chats.") + collapsed("Copied the link.") + open));
      const toasts = await page_.evaluate(measure);
      expect(toasts).toHaveLength(3);
      expectRowsHold(toasts);
      // The stack did not fit: the open toast's Details gave up the height and scroll.
      expect(toasts[2]!.detailScrolls).toBe(true);
    } finally {
      await page_.close();
    }
  });

  test("title rows that do not fit above the floor stay on the page", async () => {
    // The review's case: a 300 px page, the floor 140 px up (a tall composer), three collapsed toasts
    // of three lines each, taller together than the 160 px above the floor.
    const page_ = await browser.newPage({ viewport: { width: 420, height: 300 } });
    try {
      const long = (n: number) => `Toast ${n}: one\ntwo\nthree`;
      await page_.setContent(page(140, collapsed(long(1)) + collapsed(long(2)) + collapsed(long(3))));
      const toasts = await page_.evaluate(measure);
      expect(toasts).toHaveLength(3);
      expectRowsHold(toasts);
      for (const toast of toasts) {
        expect(toast.top).toBeGreaterThanOrEqual(-0.5);
        expect(toast.bottom).toBeLessThanOrEqual(300 + 0.5);
      }
      expect(toasts[2]!.bottom).toBeGreaterThan(300 - 140); // they did not fit above the floor
    } finally {
      await page_.close();
    }
  });

  test("a stack that fits rests on its floor", async () => {
    const page_ = await browser.newPage({ viewport: { width: 420, height: 300 } });
    try {
      await page_.setContent(page(40, collapsed("Archived 3 chats.") + collapsed("Copied the link.")));
      const toasts = await page_.evaluate(measure);
      expect(Math.abs(toasts[1]!.bottom - (300 - 40))).toBeLessThan(0.5);
      expect(toasts[0]!.bottom).toBeLessThanOrEqual(toasts[1]!.top + 0.5);
    } finally {
      await page_.close();
    }
  });

  afterAll(async () => {
    await browser.close();
  });
});
