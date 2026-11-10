// The prompt field's growth (composer/fieldGrowth.ts) obeys the motion gate while it runs, not only
// when it starts. Turning motion off mid-growth (`data-cmux-motion="off"`, the app's switch) lands the
// field at its height at once, and an edit that keeps the same end height never replays the motion:
// that edit took the same-target path, which ran before the motion check, so a growth started under
// full motion played on after the switch went off. Headless Chromium, the gallery's composer, the
// page's animations slowed so the growth spans many reads.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-grow-motion-off.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-grow-motion-off", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const FIELD = ".acpmux-composer-box .acpmux-md-field";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "codex-grow-line" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("motion turned off mid-growth lands the field, and a same-line edit after it never moves", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 1 });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant: "codex-grow-line" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.evaluate(() => document.fonts.ready);
      // A twentieth of the speed: the growth lasts seconds, far longer than the reads below.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Animation.enable");
      await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.05 });
      await page.locator(`${FIELD} .ProseMirror`).click();
      await page.keyboard.press("Control+End");
      const moving = () =>
        page.evaluate((selector) => document.querySelector(selector)!.getAnimations().length > 0, FIELD);
      await page.waitForFunction((selector) => document.querySelector(selector)!.getAnimations().length === 0, FIELD);

      await page.keyboard.press("Shift+Enter");
      expect(await moving()).toBe(true);
      await page.evaluate(() => document.documentElement.setAttribute("data-cmux-motion", "off"));
      // The gate changed: the growth lands within a frame or two, with no edit to wake it.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      expect(await moving()).toBe(false);
      // A character on the same line ends where the field already is: nothing moves.
      await page.keyboard.type("x");
      expect(await moving()).toBe(false);
    } finally {
      await page.close();
    }
  });
});
