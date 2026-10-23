// Shell mode keeps the composer's one-line box (composerLocation.css, the composer pill's tokens):
// typing "!" in an empty prompt swaps the markdown prompt (a 20 px title line) for the shell field
// (a 22 px monospace line, composerStates.css). Each field centres its own line between the box's
// insets, so the box is 44 px either way (--acpmux-pill-icon + 2 * --acpmux-box-inset): entering
// shell mode neither grows the box nor clips the shell's line. Real Chromium on the gallery's
// composer; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-shell-box-height.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer shell box height", () => test("chromium", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  const ENTRY = "agent-pane.composer";
  const VARIANT = "quiet-chips";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The box, the field in it and the tokens that size a one-line box. */
  const measure = (page: Page, field: string) =>
    page.$eval(
      ".acpmux-composer-box",
      (box, selector) => {
        const element = box.querySelector<HTMLElement>(selector)!;
        const style = getComputedStyle(box);
        return {
          box: box.getBoundingClientRect().height,
          field: element.getBoundingClientRect().height,
          clipped: element.scrollHeight > element.clientHeight,
          oneLine:
            Number.parseFloat(style.getPropertyValue("--acpmux-pill-icon")) +
            2 * Number.parseFloat(style.getPropertyValue("--acpmux-box-inset")),
        };
      },
      field,
    );

  for (const width of [760, 420]) {
    test(`at ${width} px the shell field keeps the one-line box`, async () => {
      const context = await browser.newContext({ viewport: { width, height: 600 } });
      const page = await context.newPage();
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        // The box this test is about: the prompt and + share one grid row (.acpmux-composer-inner).
        expect(await page.locator(".acpmux-composer-box .acpmux-composer-inner").count()).toBe(1);
        const prompt = await measure(page, ".acpmux-md-field");
        expect(prompt.oneLine).toBe(44);
        expect(prompt.box).toBe(prompt.oneLine);

        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("!");
        await page.locator(".acpmux-shell-field").waitFor();
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const shell = await measure(page, ".acpmux-shell-field");
        expect(shell.box).toBe(prompt.box);
        expect(shell.field).toBe(shell.oneLine);
        expect(shell.clipped).toBe(false);

        await page.keyboard.type("ls -la");
        const typed = await measure(page, ".acpmux-shell-field");
        expect(typed.box).toBe(prompt.box);
        expect(typed.clipped).toBe(false);
      } finally {
        await context.close();
      }
    });
  }
});
