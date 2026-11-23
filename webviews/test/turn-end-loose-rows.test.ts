// Every ended turn folds its work under its one closed "Worked for", whatever started it (hq#18554
// ask 4; Leo, 2026-11-22: "the notices/etc, they dont properly fold in when your turn ends"). In
// gallery entry agent-pane.turn-end-loose-rows, each of Leo's four shapes draws no thought or call
// row at rest: no `.cv-thought` and no tool row outside a closed fold.
//
// CMUX_LOOSE_ROWS_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes a 2x still of each
// variant, dark, for the before/after shots.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("turn-end-loose-rows.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.turn-end-loose-rows";
  const VARIANTS = ["a-wake-thought", "b-failed-step-send", "c-steer-thought", "d-bg-done-then-notice"];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("turn end loose rows", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0]! }, timeoutMs: 200_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 560, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const params = { variant, width: 560, theme: "Catppuccin Mocha", reducedMotion: "true" };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, params)}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  const artifacts = process.env.CMUX_LOOSE_ROWS_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;

  for (const variant of VARIANTS)
    test(`${variant}: no thought or call draws outside a closed Worked for`, async () => {
      const page = await open(variant);
      try {
        if (artifacts) {
          await mkdir(artifacts, { recursive: true });
          await page.screenshot({ path: path.join(artifacts, `loose-rows-${variant}.png`), fullPage: true });
        }
        const loose = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>("[data-row-id]")]
            .filter((row) => /^(activity|messageRun)-|-work$/.test(row.dataset.rowId ?? ""))
            .map((row) => row.dataset.rowId),
        );
        expect(loose).toEqual([]);
        const worked = await page.evaluate(
          () => [...document.querySelectorAll<HTMLElement>('[data-row-id^="worked-"]')].length,
        );
        expect(worked).toBeGreaterThan(0);
      } finally {
        await page.close();
      }
    });
});
