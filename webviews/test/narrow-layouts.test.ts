// cmux-web-test-timeout: 300
// Each width is a gallery page load plus a geometry play: the file took about 195 s on an idle
// Linux box, and the default 120 s killed it on the CI runner after six of its seven tests.
// Narrow panes (Leo 2026-10-14, "squashed composers"): the agent pane at the widths a split leaves
// it, 280, 360 and 480 px, and at interface scale 0.8 and 1.25. Each variant of the
// agent-pane.narrow gallery entry plays its geometry check in Chromium: no sideways page scroll, the
// composer's controls side by side inside their row, Send, Stop, Steer and the mic at full size,
// and text that does not fit ending in an ellipsis.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("narrow-layouts.test.ts", async () => {
  const VARIANTS = [
    "controls",
    "working",
    "pull-requests",
    "new-tab",
    "new-tab-wide-type",
    "new-tab-default",
    "controls-single-row",
    "code",
    "permission",
    "model-menu",
    "access-menu",
    "summary",
  ];
  const SIZES = [
    { width: 280, scale: 1 },
    { width: 360, scale: 1 },
    { width: 480, scale: 1 },
    { width: 360, scale: 1.25 },
    { width: 480, scale: 0.8 },
    // Wide panes show every chip in full (no tier applies).
    { width: 760, scale: 1 },
    { width: 1200, scale: 1 },
  ];

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("narrow-layouts: skipping (run `bunx playwright install chromium`)");
    describe.skip("narrow layouts", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.narrow", { variant })}`;

  // Interface scale is WKWebView.pageZoom in the app: the page lays out in width / scale CSS px,
  // media queries included, drawn at scale. (The gallery's own `scale` is CSS zoom, which media
  // queries do not see.)
  const play = async (variant: string, width: number, scale: number) => {
    const page = await browser!.newPage({
      viewport: { width: Math.round(width / scale), height: Math.round(560 / scale) },
      deviceScaleFactor: scale,
    });
    for (let attempt = 1; ; attempt++) {
      await page.goto(stageURL(variant));
      try {
        await page.waitForFunction(() => {
          const ready = document.documentElement.dataset.galleryReady;
          return ready === "1" || ready === "error";
        });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    return playFailures(report);
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test renders each state once (and a shared host can be out of inotify watches).
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.narrow", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const { width, scale } of SIZES)
    test(`the agent pane holds together at ${width} px, scale ${scale}`, async () => {
      // Four pages at a time: the file's seven sizes fit the runner's per-file limit.
      const failures: string[] = [];
      for (let start = 0; start < VARIANTS.length; start += 4)
        for (const [index, found] of (
          await Promise.all(VARIANTS.slice(start, start + 4).map((variant) => play(variant, width, scale)))
        ).entries())
          failures.push(...found.map((failure) => `${VARIANTS[start + index]}: ${failure}`));
      expect(failures).toEqual([]);
    });
});
