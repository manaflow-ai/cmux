// l10n-allow-file: test prose, not shipped UI.
// Jump to latest's fisheye glass frosts the words under it (Leo 2026-11-03, on the disc over the
// transcript: "this is a little too transparent maybe don't we inherit off the macos glass levels?").
// The lens (cmux#32577) bent the transcript under the disc with only a quarter-pixel blur and a 14%
// tint, so the words behind it read straight through. In the real gallery entry
// (agent-pane.jump-latest-lens, the variant that ships) over dense prose, in a dark and a light
// theme, the disc's middle (the arrow hidden, away from the rim's shading) is measured against an
// equal patch of the same prose beside it: the spread of luminance under the glass stays under a
// third of the spread beside it, so the text under it no longer reads. The glass still shows the
// page: the spread under it is above zero (never a solid fill), and the disc keeps the fisheye.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/jump-latest-lens-frost.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("jump-latest-lens-frost.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("jump-latest-lens-frost: skipping (run `bunx playwright install chromium`)");
    describe.skip("jump to latest lens frost", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.jump-latest-lens";
  const ENTRY_PATH = "src/agent-session/acpmux/jumpLatestLens.gallery.ts";
  const stageURL = (scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${ENTRY}&entryPath=${ENTRY_PATH}&variant=medium&colorScheme=${scheme}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const file of [ENTRY_PATH, "src/gallery/frame/agentPane.ts"])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} imports nothing; is it served?`);
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await warm.goto(stageURL("dark"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The standard deviation of relative luminance over a PNG's pixels inside `keep(x, y)`. */
  function spread(png: Buffer, keep: (x: number, y: number, w: number, h: number) => boolean): number {
    const image = PNG.sync.read(png);
    const lin = (c: number) => {
      const v = c / 255;
      return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    };
    const values: number[] = [];
    for (let y = 0; y < image.height; y++)
      for (let x = 0; x < image.width; x++) {
        if (!keep(x, y, image.width, image.height)) continue;
        const at = (y * image.width + x) * 4;
        values.push(
          0.2126 * lin(image.data[at]!) + 0.7152 * lin(image.data[at + 1]!) + 0.0722 * lin(image.data[at + 2]!),
        );
      }
    const mean = values.reduce((sum, v) => sum + v, 0) / values.length;
    return Math.sqrt(values.reduce((sum, v) => sum + (v - mean) ** 2, 0) / values.length);
  }

  for (const scheme of ["dark", "light"] as const)
    test(`${scheme}: the words under Jump to latest no longer read through its glass`, async () => {
      const page = await browser!.newPage({
        viewport: { width: 900, height: 700 },
        deviceScaleFactor: 2,
        colorScheme: scheme,
      });
      try {
        await page.goto(stageURL(scheme));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.waitForSelector(".acpmux-jump-latest[data-shown]");
        // The arrow (and its pool) off, so only the glass and what it shows are measured.
        await page.addStyleTag({ content: ".acpmux-jump-latest__arrow { visibility: hidden !important; }" });
        await page.evaluate(
          () =>
            new Promise((resolve) =>
              requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 500))),
            ),
        );
        const box = await page.locator(".acpmux-jump-latest").boundingBox();
        if (!box) throw new Error("Jump to latest did not render");
        const cx = box.x + box.width / 2;
        const cy = box.y + box.height / 2;
        // The middle of the disc, 22 css px across: inside the rim's lit arc and inner shade.
        const side = 22;
        const inDisc = (x: number, y: number, w: number, h: number) =>
          (x + 0.5 - w / 2) ** 2 + (y + 0.5 - h / 2) ** 2 <= (w / 2) ** 2;
        const under = spread(
          await page.screenshot({ clip: { x: cx - side / 2, y: cy - side / 2, width: side, height: side } }),
          inDisc,
        );
        // The same prose beside it, on both sides, clear of the disc and its shadow.
        const beside = Math.max(
          ...(await Promise.all(
            [-90, 90].map(async (dx) =>
              spread(
                await page.screenshot({ clip: { x: cx + dx - side / 2, y: cy - side / 2, width: side, height: side } }),
                inDisc,
              ),
            ),
          )),
        );
        const info = await page.evaluate(() => {
          const style = getComputedStyle(document.querySelector(".acpmux-jump-latest")!);
          return { backdrop: style.backdropFilter, fill: style.backgroundColor };
        });
        console.log(JSON.stringify({ scheme, under, beside, ratio: under / beside, ...info }));
        // The prose beside the button carries text (else the comparison says nothing).
        expect(beside).toBeGreaterThan(0.02);
        // Frosted: the words under the glass blur to a soft wash, under a third of the spread beside.
        expect(under / beside).toBeLessThan(1 / 3);
        // Still glass, never a solid disc: the page shows through.
        expect(under).toBeGreaterThan(0);
        // Still the fisheye lens (cmux#32577): its SVG filter stays the backdrop's first step.
        expect(info.backdrop).toContain("cmux-glass-fisheye");
      } finally {
        await page.close();
      }
    });
});
