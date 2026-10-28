// The attached queue and its fold continue the composer's surface. A narrow composer widens into
// its gutters; every joined piece must keep the same edges (Leo/Lawrence, ask-a1c7dd28ee).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("queue-composer-alignment.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "queued-long-open" } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const look of ["claude", "codex"] as const)
    for (const width of [720, 260])
      for (const scheme of ["light", "dark"] as const)
        test(look + ", " + width + "px, " + scheme + ": queue and fold share the box edges", async () => {
          const page = await browser.newPage({ viewport: { width, height: 600 } });
          try {
            await page.addInitScript((value) => localStorage.setItem("cmux.composer.look", value), look);
            const port = (vite.httpServer!.address() as { port: number }).port;
            await page.goto(
              "http://127.0.0.1:" +
                port +
                galleryFrame("agent-pane.composer", { variant: "queued-long-open", colorScheme: scheme }),
            );
            await page.waitForSelector(".acpmux-composer-queue[data-unfolded]");
            await page.waitForFunction(
              (value) =>
                (document.querySelector(".acpmux-composer")?.getAttribute("data-composer-look") ?? "claude") === value,
              look,
            );
            await page.evaluate(() => document.fonts.ready);
            for (const state of ["expanded", "collapsed"]) {
              if (state === "collapsed") {
                await page.locator(".acpmux-queue-fold").click();
                await page.waitForSelector(".acpmux-composer-queue:not([data-unfolded])");
              }
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              const measured = await page.evaluate(() => {
                const rect = (selector: string) => {
                  const box = document.querySelector(selector)!.getBoundingClientRect();
                  return { left: box.left, right: box.right, top: box.top, bottom: box.bottom, width: box.width };
                };
                return {
                  container: rect(".acpmux-composer"),
                  box: rect(".acpmux-composer-box"),
                  queue: rect(".acpmux-composer-queue"),
                  fold: rect(".acpmux-queue-foldbar"),
                  play: (window as Window & { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport,
                };
              });
              // Optional private evidence is captured before assertions, including the red baseline.
              const output = process.env.CMUX_ALIGNMENT_CAPTURE_DIR;
              if (output) {
                await mkdir(output, { recursive: true });
                const name = look + "-" + width + "-" + scheme + "-" + state;
                const png = await page.screenshot({ path: path.join(output, name + ".png") });
                await writeFile(
                  path.join(output, name + ".json"),
                  JSON.stringify({ ...measured, pngSha256: createHash("sha256").update(png).digest("hex") }, null, 2),
                );
              }
              console.log(JSON.stringify({ look, width, scheme, state, ...measured }));
              expect(measured.container.width <= 260).toBe(width === 260);
              for (const piece of [measured.queue, measured.fold]) {
                expect(Math.abs(piece.left - measured.box.left)).toBeLessThanOrEqual(1);
                expect(Math.abs(piece.right - measured.box.right)).toBeLessThanOrEqual(1);
              }
              expect(measured.fold.top).toBeGreaterThanOrEqual(measured.queue.bottom - 1);
            }
          } finally {
            await page.close();
          }
        });
});
