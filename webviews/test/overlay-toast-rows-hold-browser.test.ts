// A stack of toasts taller than the room above the composer gives up its Details' height, never a
// toast's title row. Each toast was a flex column with min-height: 0, so in a short window an open
// Details squeezed the collapsed toasts beside it below their row: their Undo and close buttons
// drew outside the toast's rect, the one the page reports for the native click regions, so they
// overlapped the next toast and took no clicks (review of #37289 at a3f8a3de, F1). Laid out by
// Chromium from the real toasts.css, in a stack shorter than its content:
// - every toast is at least as tall as its title row, and its buttons stay inside its rect;
// - the open toast's Details shrink and scroll instead.
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
  const css = readFileSync(path.resolve(import.meta.dir, "../src/pages/overlay/toasts/toasts.css"), "utf8");
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
    const page = await browser.newPage({ viewport: { width: 600, height: 120 } });
    try {
      // The stack spans the page above its floor (`bottom`), as the app draws it.
      await page.setContent(
        `<html><head><style>body { margin: 0; font: 13px/18px sans-serif } ${css}</style></head><body>` +
          `<div class="cmux-toasts" style="bottom: 20px">${collapsed("Archived 3 chats.")}${collapsed("Copied the link.")}${open}</div>` +
          `</body></html>`,
      );
      const toasts = await page.evaluate(() =>
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
        }),
      );
      expect(toasts).toHaveLength(3);
      for (const toast of toasts) {
        expect(toast.bottom - toast.top).toBeGreaterThanOrEqual(toast.rowHeight - 0.5);
        for (const b of toast.buttons) {
          expect(b.top).toBeGreaterThanOrEqual(toast.top - 0.5);
          expect(b.bottom).toBeLessThanOrEqual(toast.bottom + 0.5);
        }
      }
      // The stack did not fit: the open toast's Details gave up the height and scroll.
      expect(toasts[2]!.detailScrolls).toBe(true);
    } finally {
      await page.close();
    }
  });

  afterAll(async () => {
    await browser.close();
  });
});
