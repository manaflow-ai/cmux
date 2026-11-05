// Geometry coverage for the ChatGPT-style result-first subagent drill-in. The gallery's play also
// checks that a settling report leaves the transcript's top edge fixed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-result-header.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("subagent-result-header: skipping (run `bunx playwright install chromium`)");
    describe.skip("subagent result header", () => test("chromium", () => {}));
    return;
  }
  const entry = "agent-pane.subagent-result-header";
  const variants = ["split-long", "dock-long", "dock-short", "stream-stable", "one-tab"] as const;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      root: webviews,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [entry], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("long and short result heads keep the transcript reachable across pane sizes", async () => {
    let dockLongHeadHeight = 0;
    let dockShortHeadHeight = 0;
    for (const variant of variants) {
      const page = await browser!.newPage({
        viewport: {
          width: variant.startsWith("dock") || variant === "one-tab" ? 440 : 780,
          height: variant.startsWith("dock") || variant === "one-tab" ? 300 : 660,
        },
      });
      await page.goto(
        `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const geometry = await page.evaluate(() => {
        const scene = document.querySelector<HTMLElement>("[data-result-scene]")!;
        const head = scene.querySelector<HTMLElement>(".cv-subagent-result")!;
        const report = scene.querySelector<HTMLElement>(".cv-subagent-result__report")!;
        const transcript = scene.querySelector<HTMLElement>("[data-result-transcript]")!;
        const firstLine = report.querySelector<HTMLElement>(".cv-md > :first-child");
        const reportRect = report.getBoundingClientRect();
        const firstLineRect = firstLine?.getBoundingClientRect();
        const computedLineHeight = firstLine ? Number.parseFloat(getComputedStyle(firstLine).lineHeight) : 0;
        return {
          sceneHeight: scene.getBoundingClientRect().height,
          headHeight: head.getBoundingClientRect().height,
          reportClientHeight: report.clientHeight,
          reportScrollHeight: report.scrollHeight,
          transcriptHeight: transcript.getBoundingClientRect().height,
          transcriptTop: transcript.getBoundingClientRect().top,
          headBottom: head.getBoundingClientRect().bottom,
          reportLineHeight: Number.isFinite(computedLineHeight) ? computedLineHeight : firstLineRect?.height ?? 0,
          reportFirstLineVisible: Boolean(
            firstLineRect &&
              firstLineRect.height > 0 &&
              firstLineRect.bottom > reportRect.top + 0.5 &&
              firstLineRect.top < reportRect.bottom - 0.5,
          ),
        };
      });
      console.log(`subagent-result-header ${variant} ${JSON.stringify(geometry)}`);
      if (variant === "one-tab") {
        const bottomHit = await page.evaluate(() => {
          const report = document.querySelector<HTMLElement>(".cv-subagent-result__report")!;
          const lastLine = report.querySelector<HTMLElement>(".cv-md > :last-child");
          report.scrollTop = report.scrollHeight;
          const reportRect = report.getBoundingClientRect();
          const lastRect = lastLine?.getBoundingClientRect();
          if (!lastLine || !lastRect)
            return { scrollable: false, moved: false, lastVisible: false, inLastLine: false };
          const x = Math.max(
            reportRect.left + 1,
            Math.min(lastRect.left + lastRect.width / 2, reportRect.right - 1),
          );
          const y = Math.max(
            reportRect.top + 1,
            Math.min(lastRect.top + lastRect.height / 2, reportRect.bottom - 1),
          );
          const target = document.elementFromPoint(x, y);
          return {
            scrollable: report.scrollHeight > report.clientHeight,
            moved: report.scrollTop > 0,
            lastVisible:
              lastRect.top >= reportRect.top - 0.5 && lastRect.bottom <= reportRect.bottom + 0.5,
            inLastLine: Boolean(target && lastLine.contains(target)),
          };
        });
        expect(bottomHit.scrollable).toBe(true);
        expect(bottomHit.moved).toBe(true);
        expect(bottomHit.lastVisible).toBe(true);
        expect(bottomHit.inLastLine).toBe(true);
      }
      expect(geometry.transcriptHeight).toBeGreaterThan(0);
      expect(geometry.transcriptTop).toBeGreaterThanOrEqual(geometry.headBottom - 0.5);
      if (variant === "dock-long") {
        dockLongHeadHeight = geometry.headHeight;
        expect(geometry.reportScrollHeight).toBeGreaterThan(geometry.reportClientHeight);
      }
      if (variant === "dock-long" || variant === "dock-short") {
        expect(geometry.reportClientHeight).toBeGreaterThanOrEqual(geometry.reportLineHeight - 0.5);
        expect(geometry.reportFirstLineVisible).toBe(true);
      }
      if (variant === "dock-short") dockShortHeadHeight = geometry.headHeight;
      await page.close();
    }
    expect(dockShortHeadHeight).toBeGreaterThan(0);
    expect(dockShortHeadHeight).toBeLessThan(dockLongHeadHeight);
  });
});
