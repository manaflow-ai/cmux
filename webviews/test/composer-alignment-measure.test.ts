// Before/after evidence for the composer's alignment (composer-alignment-centers.test.ts pins it):
// measures every control's drawn center in Chromium and writes the numbers and a still of the
// composer to webviews/artifacts/composer-alignment/ (the fleet step returns them as artifacts).
// It asserts nothing: the centers test does. Light and dark, normal and narrow panes.
import { afterAll, beforeAll, describe, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { measureComposerAlignment, type ComposerAlignment } from "./support/composerAlignment";

await requireBrowserLane("composer-alignment-measure.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-alignment-measure: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer alignment measure", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "composer-alignment");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (scheme: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-row", { variant, theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "claude-auto" } });
    mkdirSync(outDir, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["claude-auto", "grid-running"])
  for (const width of [720, 420])
    for (const scheme of ["light", "dark"])
      test(`measure ${variant} at ${width} px (${scheme})`, async () => {
        const page = await browser!.newPage({ viewport: { width, height: 300 }, deviceScaleFactor: 2 });
        await page.goto(stageURL(scheme, variant));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".acpmux-composer-box .acpmux-md-placeholder").first().waitFor();
        await page.evaluate(() => document.fonts.ready);
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const measured: ComposerAlignment = await page.evaluate(measureComposerAlignment);
        const stem = `${variant}-${width}-${scheme}`;
        writeFileSync(path.join(outDir, `${stem}.json`), `${JSON.stringify(measured, null, 2)}\n`);
        await page
          .locator(".acpmux-composer")
          .first()
          .screenshot({ path: path.join(outDir, `${stem}.png`) });
        console.log(JSON.stringify({ variant, width, scheme, measured }));
        await page.close();
      });
});
