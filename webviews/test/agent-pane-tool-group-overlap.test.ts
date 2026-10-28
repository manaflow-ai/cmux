// l10n-allow-file: gallery fixture labels and test diagnostics.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-tool-group-overlap.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.tool-group-overlap";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "mixed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("mixed transcript rows never overlap while a tool group opens and closes", async () => {
    const captures = process.env.CMUX_OVERLAP_CAPTURES;
    if (captures) mkdirSync(captures, { recursive: true });
    const context = await browser.newContext({
      viewport: { width: 900, height: 680 },
      ...(captures ? { recordVideo: { dir: captures } } : {}),
    });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await page.goto(
      `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant: "mixed" })}`,
    );
    const group = page.locator('[data-row-id="mixed-tool-group"]');
    await group.locator("button.cv-tool").first().waitFor();
    await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
    await page.evaluate(() => {
      const samples: { before: string; after: string; overlap: number }[] = [];
      (window as unknown as { overlapSamples: typeof samples }).overlapSamples = samples;
      window.cmuxAfterPaint(() => {
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-thread > article[data-row-id]")].sort(
          (a, b) => Number(a.getAttribute("aria-posinset")) - Number(b.getAttribute("aria-posinset")),
        );
        for (let index = 1; index < rows.length; index += 1) {
          const before = rows[index - 1]!;
          const after = rows[index]!;
          const overlap = before.getBoundingClientRect().bottom - after.getBoundingClientRect().top;
          if (overlap > 1) samples.push({ before: before.dataset.rowId!, after: after.dataset.rowId!, overlap });
        }
      });
    });
    for (const open of [true, false, true]) {
      await group.locator("button.cv-tool").first().click();
      // The click can resolve before React commits the toggle and starts its layout-effect
      // animation. Observe the committed state before waiting for that animation to finish.
      await page.waitForFunction((expected) => {
        const line = document.querySelector('[data-row-id="mixed-tool-group"] button.cv-tool');
        return line?.getAttribute("aria-expanded") === String(expected);
      }, open);
      await page.waitForFunction(() => {
        const moving = document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
        if (moving.length) return false;
        return true;
      });
      await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
      expect(await group.locator("button.cv-tool").first().getAttribute("aria-expanded")).toBe(String(open));
      if (open) {
        const geometry = await group.evaluate((row) => ({
          bodyBottom: row.querySelector(".cv-tool-run")!.getBoundingClientRect().bottom,
          rowBottom: row.getBoundingClientRect().bottom,
        }));
        // Once open, the whole tool list fits in its row: clipping cannot make article bounds
        // appear separate while the actual tool content still extends behind the next bubble.
        expect(geometry.bodyBottom).toBeLessThanOrEqual(geometry.rowBottom + 1);
      }
    }
    if (captures) await page.screenshot({ path: path.join(captures, "tool-group-followed-by-prompt.png") });
    const overlaps = await page.evaluate(
      () =>
        (
          window as unknown as {
            overlapSamples: { before: string; after: string; overlap: number }[];
          }
        ).overlapSamples,
    );
    console.log("tool-group overlap painted frames:", JSON.stringify(overlaps));
    await context.close();
    expect(overlaps).toEqual([]);
  });
});
