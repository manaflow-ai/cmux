// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The New Tab Add Widget gallery in a short window (cmux#44995): on a DEV build with an 858 px tall
// window the gallery's 3rd and 4th rows (Weather, To Do) could not be reached, so Weather medium and
// To Do large could never be added. The shipped agent pane does not load ui/ui.css, so the sheet had
// no `.ui-sheet` overflow or bottom anchor: it sat 12vh down (ui/popupSurface.css), its rows ran past
// the window's bottom, and its body's `overflow: auto` never scrolled because nothing bounded its
// height. A debug scroll of the previews into view found no scroll box in the gallery at all.
//
// In real Chromium on the gallery frame, at window heights from 500 to 858 px, with ui.css (the
// gallery and other hosts) and without it (the shipped pane): the gallery's own scroller holds the
// rows, its last preview scrolls into view and is the element under its centre (so a click reaches
// it), and the title and Done stay inside the window. The sheet has its own surface there too (the
// sheet role's glass: a fill and a blur): on the DEV build the New Tab composer, its suggestions and
// the edit bar read through the bare sheet. CI fails the file when Chromium cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-widget-gallery-short-window-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "new-tab.widget-gallery";
  const WIDTH = 760;
  const HEIGHTS = [500, 640, 858];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "rows", colorScheme: "light" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("Add Widget gallery in a short window", () => {
    for (const shipped of [true, false])
      for (const height of HEIGHTS)
        test(`${shipped ? "as the shipped pane (no ui.css)" : "with ui.css"} at ${height}px: the last row scrolls into view under the title and Done`, async () => {
          const page = await browser!.newPage({ viewport: { width: WIDTH, height } });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(
              base + galleryFrame(ENTRY, { variant: "rows", colorScheme: "light", width: WIDTH, height }),
            );
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            // The shipped agent pane loads ui/popupSurface.css but not ui/ui.css: take its sheet away.
            if (shipped)
              await page.evaluate(() => {
                for (const style of document.querySelectorAll<HTMLStyleElement>("style[data-vite-dev-id]"))
                  if (style.dataset.viteDevId!.endsWith("/src/ui/ui.css")) style.remove();
              });
            await page.locator(".nt-widget-gallery .nt-widget-preview").last().waitFor();

            const layout = await page.evaluate(async () => {
              const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
              const sheet = document.querySelector<HTMLElement>(".nt-widget-gallery")!;
              const previews = [...sheet.querySelectorAll<HTMLElement>(".nt-widget-preview")];
              const last = previews.at(-1)!;
              // The nearest box that scrolls the rows (a long gallery overflows it).
              let scroller: HTMLElement | null = last.parentElement;
              while (scroller && scroller !== sheet.parentElement) {
                const overflowY = getComputedStyle(scroller).overflowY;
                if (/(auto|scroll)/.test(overflowY) && scroller.scrollHeight > scroller.clientHeight) break;
                scroller = scroller.parentElement;
              }
              const inSheet = !!scroller && scroller !== sheet.parentElement && sheet.contains(scroller);
              last.scrollIntoView({ block: "end" });
              await frame();
              await frame();
              const box = last.getBoundingClientRect();
              const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
              const visible = (selector: string) => {
                const el = sheet.querySelector(selector)!;
                const rect = el.getBoundingClientRect();
                const under = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
                return rect.top >= 0 && rect.bottom <= innerHeight && !!under && el.contains(under);
              };
              return {
                previews: previews.length,
                scroller: inSheet ? scroller!.className : null,
                scrollerOverflowY: inSheet ? getComputedStyle(scroller!).overflowY : null,
                lastInView: box.top >= 0 && box.bottom <= innerHeight + 0.5,
                lastHit: !!hit && last.contains(hit),
                title: visible(".nt-widget-gallery-title"),
                done: visible(".nt-widget-gallery-done"),
                sheetBottom: Math.floor(sheet.getBoundingClientRect().bottom),
                ...surface(),
              };
              // The sheet's own surface: a fill and the glass's blur, so what lies under it (the New Tab
              // composer, its suggestions and the edit bar on the DEV build) does not read through. The
              // point between the title and Done is the sheet's, not anything under it.
              function surface() {
                const style = getComputedStyle(sheet);
                const alpha = (() => {
                  const parts = style.backgroundColor.match(/[\d.]+/g)?.map(Number) ?? [];
                  if (style.backgroundColor === "transparent" || parts.length < 3) return 0;
                  return parts.length > 3 ? parts[3]! : 1;
                })();
                const head = sheet.querySelector<HTMLElement>(".nt-widget-gallery-head")!.getBoundingClientRect();
                const title = sheet.querySelector<HTMLElement>(".nt-widget-gallery-title")!.getBoundingClientRect();
                const under = document.elementFromPoint(title.right + 8, head.top + head.height / 2);
                return {
                  fillAlpha: alpha,
                  backdrop: style.backdropFilter,
                  underHeadIsSheet: !!under && sheet.contains(under),
                };
              }
            });

            expect(layout.previews).toBeGreaterThan(3);
            expect({
              scroller: layout.scroller,
              overflowY: layout.scrollerOverflowY,
              lastInView: layout.lastInView,
              lastHit: layout.lastHit,
              title: layout.title,
              done: layout.done,
              sheetInWindow: layout.sheetBottom <= height,
            }).toEqual({
              scroller: "nt-widget-gallery-scroll",
              overflowY: "auto",
              lastInView: true,
              lastHit: true,
              title: true,
              done: true,
              sheetInWindow: true,
            });
            // Its surface (frame 54 of the DEV tour: the composer, its suggestions and the edit bar read
            // through the bare sheet in the shipped pane): a fill and the glass's blur under it.
            expect({
              fill: layout.fillAlpha >= 0.4,
              blur: /blur\(/.test(layout.backdrop),
              underHeadIsSheet: layout.underHeadIsSheet,
            }).toEqual({ fill: true, blur: true, underHeadIsSheet: true });
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
