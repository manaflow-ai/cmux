// l10n-allow-file: gallery fixture text, not shipped UI.
// cmux-web-test-timeout: 300
// Capture the actual composer row at first detection and prolonged outages. The same
// harness records the old row so the before/after visibility receipt is reproducible.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("peer-reconnect-gallery.test.ts", async () => {
  setDefaultTimeout(240_000);
  const entry = "agent-pane.machine-link";
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT || path.join(webviews, "artifacts", "peer-reconnect");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const measurements: unknown[] = [];

  beforeAll(async () => {
    mkdirSync(out, { recursive: true });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, {
      browser,
      params: { variant: "outage-1s" },
    });
  });
  afterAll(async () => {
    writeFileSync(path.join(out, "reconnect-visibility.json"), JSON.stringify(measurements, null, 2));
    await browser?.close();
    await vite?.close();
  });

  async function paintedLabel(row: import("playwright").Locator): Promise<{ text: string; painted: boolean }> {
    return row.evaluate((element) => {
      const style = getComputedStyle(element);
      const text = element.textContent ?? "";
      const range = document.createRange();
      range.selectNodeContents(element);
      const rects = [...range.getClientRects()];
      const tail = document.createRange();
      const textNodes: Text[] = [];
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) textNodes.push(walker.currentNode as Text);
      const last = textNodes.at(-1);
      if (!last || last.length < 4) return { text, painted: false };
      tail.setStart(last, Math.max(0, last.length - 4));
      tail.setEnd(last, last.length);
      const tailBox = tail.getBoundingClientRect();
      const visible = style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity) !== 0;
      const viewport = { width: window.innerWidth, height: window.innerHeight };
      const intersects = (a: DOMRect, b: { left: number; top: number; right: number; bottom: number }) =>
        a.right > b.left && a.left < b.right && a.bottom > b.top && a.top < b.bottom;
      if (
        !visible ||
        rects.length === 0 ||
        !rects.some((rect) =>
          intersects(rect, {
            left: 0,
            top: 0,
            right: viewport.width,
            bottom: viewport.height,
          }),
        )
      )
        return { text, painted: false };
      for (let ancestor = element.parentElement; ancestor; ancestor = ancestor.parentElement) {
        const ancestorStyle = getComputedStyle(ancestor);
        const clips = [ancestorStyle.overflow, ancestorStyle.overflowX, ancestorStyle.overflowY].some((value) =>
          ["hidden", "clip", "scroll", "auto"].includes(value),
        );
        if (clips) {
          const box = ancestor.getBoundingClientRect();
          if (
            !rects.some((rect) => intersects(rect, box)) ||
            tailBox.right > box.right + 1 ||
            tailBox.left < box.left - 1
          )
            return { text, painted: false };
        }
      }
      return { text, painted: true };
    });
  }

  for (const variant of [
    "before",
    "baseline-1s",
    "outage-1s",
    "outage-3s",
    "outage-10s",
    "outage-120s",
    "outage-long-name",
  ])
    for (const width of [360, 760])
      test(`${variant} at ${width}px`, async () => {
        const page = await browser.newPage({
          viewport: { width, height: 140 },
          deviceScaleFactor: 2,
        });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme: "Apple System Colors" })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.evaluate(() => document.fonts.ready);
          await page.emulateMedia({ reducedMotion: "reduce" });
          const row = page.locator("[data-peer-reconnecting]");
          await page.screenshot({
            path: path.join(out, `${variant}-${width}.png`),
          });
          if (variant === "before" || variant === "baseline-1s") {
            expect(await row.count()).toBe(0);
            if (variant === "baseline-1s")
              expect(await page.locator(".acpmux-machine-link[data-quiet]").count()).toBe(1);
          } else {
            await row.waitFor({ state: "visible" });
            const label = await paintedLabel(row);
            const seconds = variant === "outage-long-name" ? "3" : variant.slice(7, -1);
            expect(label.text).toContain(` · ${seconds} s`);
            expect(label.painted, `reconnect label is not painted for ${variant} at ${width}px`).toBe(true);
            expect(await page.locator(".acpmux-machine-link").getAttribute("data-quiet")).toBeNull();
          }
          measurements.push({
            variant,
            width,
            text: await row.allTextContents(),
          });
        } finally {
          await page.close();
        }
      });
});
