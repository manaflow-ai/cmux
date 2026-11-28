// cmux-web-test-timeout: 300
// A turn's Timeline fills its header row's empty corner with the turn's total (Leo, 2026-11-07: "at
// the top, there's nothing. The top left, there's nothing. So you might as well just show that it's,
// like, okay, this is the total time taken for this turn"). The summary sits in the label column,
// on the axis labels' line and from the row labels' left edge, and truncates before it reaches the
// axis at any width; at a phone's width, where the rows stack, it takes its own line over the axis.
// Real Chromium and WebKit (the app's engine) on the gallery stage. Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/turn-waterfall-header-summary.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("turn-waterfall-header-summary.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.turn-waterfall";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: browsers.get("chromium"), params: { variant: "bars" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Box = { left: number; right: number; top: number; bottom: number };
  const measure = async (engine: string, width: number, theme: string) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "bars", frame: "component", width, theme })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.waitForSelector(".cv-waterfall__summary", { state: "attached", timeout: 10_000 });
    const found = await page.evaluate(() => {
      const box = (element: Element | null): Box | undefined => {
        if (!element) return undefined;
        const { left, right, top, bottom } = element.getBoundingClientRect();
        return { left, right, top, bottom };
      };
      const summary = document.querySelector(".cv-waterfall__summary")!;
      return {
        text: summary.textContent,
        summary: box(summary)!,
        section: box(document.querySelector(".cv-waterfall"))!,
        axis: [...document.querySelectorAll(".cv-waterfall__axis > span")].map((span) => box(span)!),
        label: box(document.querySelector(".cv-waterfall__label"))!,
        track: box(document.querySelector(".cv-waterfall__track"))!,
        color: getComputedStyle(summary).color,
        axisColor: getComputedStyle(document.querySelector(".cv-waterfall__axis")!).color,
      };
    });
    await page.close();
    return found;
  };
  const overlaps = (a: Box, b: Box) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

  describe("turn waterfall header summary", () => {
    for (const [engine] of engines)
      for (const theme of ["Catppuccin Mocha", "Catppuccin Latte"]) {
        for (const width of [480, 640, 820]) {
          test(`${engine} ${theme} ${width}px: the corner says the total, in the label column on the axis's line`, async () => {
            const found = await measure(engine, width, theme);
            // The gallery's turn: 10 calls, mixed kinds, over 1m 12s.
            expect(found.text).toBe("10 calls · 1m 12s");
            // From the row labels' left edge, never past the label column into the axis.
            expect(Math.abs(found.summary.left - found.label.left)).toBeLessThanOrEqual(0.5);
            expect(found.summary.right).toBeLessThanOrEqual(found.track.left + 0.5);
            for (const label of found.axis) expect(overlaps(found.summary, label)).toBe(false);
            // On the axis labels' line, in their muted ink.
            expect(Math.abs(found.summary.bottom - found.axis[0]!.bottom)).toBeLessThanOrEqual(1);
            expect(found.color).toBe(found.axisColor);
          });
        }
        test(`${engine} ${theme} 390px: at a phone's width the corner takes its own line over the axis`, async () => {
          const found = await measure(engine, 390, theme);
          expect(found.text).toBe("10 calls · 1m 12s");
          expect(found.summary.left).toBeGreaterThanOrEqual(found.section.left - 0.5);
          expect(found.summary.right).toBeLessThanOrEqual(found.section.right + 0.5);
          for (const label of found.axis) expect(overlaps(found.summary, label)).toBe(false);
          expect(found.summary.bottom).toBeLessThanOrEqual(found.axis[0]!.top + 0.5);
        });
      }
  });
});
