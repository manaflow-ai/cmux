// cmux-web-test-timeout: 900
// l10n-allow-file: gallery browser assertions.
// Scrolling the composer's folder menu moves its rows and nothing else (Leo, 2026-11-06: "when i
// scroll through this it flickers and the composer flickers"). While the wheel scrolls the list
// under a resting pointer, and while the pointer crosses rows, the popup keeps its class and box,
// the composer under it is not touched at all, and the scroll only moves forward.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Trace = {
  popupClass: string[];
  popupStyle: number;
  composer: string[];
  boxes: number;
  scrolls: number[];
  highlighted: number;
  rowsMounted: number;
};

await requireBrowserLane("folder-menu-scroll-steady.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers: [string, Browser][] = [];
  const scenes = [
    ["agent-pane.composer-context", "folder-long-list", ".acpmux-folder-popover"],
    ["agent-pane.composer-context", "repo-worktrees", ".acpmux-folder-popover"],
    ["agent-pane.new-chat-composer", "folder-menu", ".acpmux-folder-popover"],
  ] as const;

  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browsers.push(["chromium", await chromium.launch({ headless: true })]);
    browsers.push(["webkit", await webkit.launch({ headless: true })]);
    for (const [entry, variant] of scenes)
      await warmGalleryFrame(vite, entry, { browser: browsers[0]![1], params: { variant } });
  }, 600_000);
  afterAll(async () => {
    for (const [, browser] of browsers) await browser.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"] as const)
    for (const [entry, variant, selector] of scenes)
      test(`${engine} ${variant}: scrolling the folder menu repaints only its rows`, async () => {
        const browser = browsers.find(([name]) => name === engine)![1];
        const page = await browser.newPage({ viewport: { width: 620, height: 300 }, deviceScaleFactor: 2 });
        try {
          const { port } = vite.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 620, height: 300 })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(selector).waitFor({ state: "visible" });
          const viewport = page.locator(`${selector} .ui-combobox-viewport`);
          const box = (await viewport.boundingBox())!;
          expect(box).not.toBeNull();
          // Rest the pointer on the list, then start recording.
          await page.mouse.move(box.x + box.width / 2, box.y + 6);
          await page.waitForTimeout(100);
          await page.evaluate((selector) => {
            const popup = document.querySelector<HTMLElement>(selector)!;
            const composer = document.querySelector("form.acpmux-composer, .nt-composer, .acpmux-composer-context");
            const scroller = popup.querySelector<HTMLElement>(".ui-combobox-viewport")!;
            const trace: Trace = {
              popupClass: [],
              popupStyle: 0,
              composer: [],
              boxes: 0,
              scrolls: [],
              highlighted: 0,
              rowsMounted: 0,
            };
            (window as unknown as { scrollTrace: Trace }).scrollTrace = trace;
            new MutationObserver((records) => {
              for (const record of records) {
                const target = record.target as Element;
                if (target === popup && record.attributeName === "class")
                  trace.popupClass.push(`${record.oldValue} -> ${popup.className}`);
                else if (target === popup && record.attributeName === "style") trace.popupStyle += 1;
                else if (composer?.contains(target) && !popup.contains(target))
                  trace.composer.push(
                    `${target.nodeName}.${(target as HTMLElement).className}@${record.attributeName ?? record.type}`,
                  );
                if (record.attributeName === "data-highlighted") trace.highlighted += 1;
                if (record.type === "childList" && scroller.contains(target))
                  trace.rowsMounted += record.addedNodes.length;
              }
            }).observe(document.documentElement, {
              subtree: true,
              attributes: true,
              attributeOldValue: true,
              childList: true,
              characterData: true,
            });
            let last = JSON.stringify(popup.getBoundingClientRect());
            const frame = () => {
              const now = JSON.stringify(popup.getBoundingClientRect());
              if (now !== last) trace.boxes += 1;
              last = now;
              trace.scrolls.push(scroller.scrollTop);
              requestAnimationFrame(frame);
            };
            requestAnimationFrame(frame);
          }, selector);
          // A trackpad scroll: small wheel steps under a resting pointer, which moves rows under it.
          for (let step = 0; step < 16; step += 1) {
            await page.mouse.wheel(0, 18);
            await page.waitForTimeout(24);
          }
          // Then the pointer crosses rows as a hand drifts while scrolling.
          for (let step = 0; step < 12; step += 1) {
            await page.mouse.move(box.x + box.width / 2, box.y + 6 + step * 9);
            await page.mouse.wheel(0, 12);
            await page.waitForTimeout(24);
          }
          // And past the list's edge and back while still scrolling: the pointer leaves the rows
          // (onto the list's padding and the field), which clears the highlight, then re-enters one.
          for (let step = 0; step < 8; step += 1) {
            await page.mouse.move(box.x + box.width / 2, step % 2 ? box.y + box.height / 2 : box.y - 6);
            await page.mouse.wheel(0, 12);
            await page.waitForTimeout(24);
          }
          await page.waitForTimeout(200);
          const trace = await page.evaluate(() => (window as unknown as { scrollTrace: Trace }).scrollTrace);
          console.log(`${engine} ${variant}`, JSON.stringify({ ...trace, scrolls: trace.scrolls.length }));
          const backwards = trace.scrolls.filter((top, index) => index > 0 && top < trace.scrolls[index - 1]! - 0.5);
          expect({
            popupClass: trace.popupClass,
            popupBoxChanges: trace.boxes,
            composer: trace.composer,
            backwards: backwards.length,
          }).toEqual({ popupClass: [], popupBoxChanges: 0, composer: [], backwards: 0 });
        } finally {
          await page.close();
        }
      });
});
