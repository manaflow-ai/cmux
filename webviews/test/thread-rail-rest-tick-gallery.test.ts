// The gallery's compare of the prompt rail's resting ticks (threadMinimapRestTick.gallery.ts): every
// variant renders under every arm of restTick.experiment.ts, and the shipped `steady` arm draws each
// resting tick at one length (model.ts tickLength(0)) beside a pushed chat and in a narrow pane, where
// `squeeze` shortens them. With FAST_CHECKS_OUT set it keeps each state's rail as a PNG for the PR.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { tickLength } from "../src/agent-session/acpmux/threadMinimap/model";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-rest-tick-gallery.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.thread-minimap-rest-tick";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("prompt rail rest tick gallery", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "closed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const rest = Math.round(tickLength(0) * 10) / 10;
  for (const [variant, width] of [
    ["left-pushed", 1200],
    ["right-pushed", 1200],
    ["closed", 800],
  ] as const)
    for (const arm of ["steady", "squeeze", "inset-first"])
      test(`${variant} at ${width} px, ${arm}: renders, and steady ticks keep one length`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 640 }, colorScheme: "dark" });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, arm, width, reducedMotion: "true" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.mouse.move(width / 2, 600);
          await page.evaluate(() => Promise.all(document.getAnimations().map((animation) => animation.finished)));
          const read = await page.evaluate(() => {
            const nav = document.querySelector<HTMLElement>(".acpmux-minimap__rail:not(.acpmux-scrollmap)")!;
            const box = nav.getBoundingClientRect();
            const lengths = [...nav.querySelectorAll<HTMLElement>(".acpmux-minimap__bar")]
              .map((bar) => bar.getBoundingClientRect())
              .filter((bar) => bar.height > 0 && bar.bottom > box.top && bar.top < box.bottom)
              .map((bar) => Math.round(bar.width * 10) / 10);
            return { lengths: [...new Set(lengths)], left: Math.round(box.left), side: nav.dataset.side };
          });
          console.log(`REST-TICK-GALLERY ${variant} ${width} ${arm} ${JSON.stringify(read)}`);
          if (process.env.FAST_CHECKS_OUT) {
            const out = path.join(process.env.FAST_CHECKS_OUT, "rest-tick-gallery");
            await mkdir(out, { recursive: true });
            const x = read.side === "right" ? width - 360 : 0;
            await page.screenshot({
              path: path.join(out, `${variant}-${width}-${arm}.png`),
              clip: { x, y: 0, width: 360, height: 400 },
            });
          }
          expect(read.lengths.length).toBeGreaterThan(0);
          if (arm !== "squeeze") expect(read.lengths).toEqual([rest]);
        } finally {
          await page.close();
        }
      });
});
