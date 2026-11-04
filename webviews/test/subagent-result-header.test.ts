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
  const variants = ["split-long", "dock-long", "dock-short", "stream-stable"] as const;
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
    for (const variant of variants) {
      const page = await browser!.newPage({
        viewport: { width: variant.startsWith("dock") ? 440 : 780, height: variant.startsWith("dock") ? 260 : 660 },
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
        return {
          sceneHeight: scene.getBoundingClientRect().height,
          headHeight: head.getBoundingClientRect().height,
          reportClientHeight: report.clientHeight,
          reportScrollHeight: report.scrollHeight,
          transcriptHeight: transcript.getBoundingClientRect().height,
          transcriptTop: transcript.getBoundingClientRect().top,
          headBottom: head.getBoundingClientRect().bottom,
        };
      });
      console.log(`subagent-result-header ${variant} ${JSON.stringify(geometry)}`);
      expect(geometry.transcriptHeight).toBeGreaterThan(0);
      expect(geometry.transcriptTop).toBeGreaterThanOrEqual(geometry.headBottom - 0.5);
      if (variant === "dock-long") expect(geometry.reportScrollHeight).toBeGreaterThan(geometry.reportClientHeight);
      await page.close();
    }
  });
});
