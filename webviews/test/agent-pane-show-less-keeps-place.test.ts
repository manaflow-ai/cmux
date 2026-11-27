// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Closing a long output from its Show less, scrolled down to at the transcript's end, keeps the
// reader at the control they clicked (foldAnchor.ts `foldHoldTarget`): held by its row's top, the
// row closed up above the view and the kept room left the view blank (review BLOCK at 5e59e449).
// An opened call's line reads whole (Leo, ask-486cb2cec3: "why the fuck did you guys ffucking
// ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE"). Both are the transcript gallery's
// own plays, each failing its own check.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-show-less-keeps-place.test.ts", async () => {
  const ENTRY = "agent-pane.transcript";
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-show-less-keeps-place: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "show-less-keeps-place" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function play(variant: string): Promise<string[]> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 820, height: 640 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    return playFailures(report);
  }

  test("Show less at the transcript's end keeps the clicked control in view", async () => {
    expect(await play("show-less-keeps-place")).toEqual([]);
  });

  test("an opened call's line draws its whole label", async () => {
    expect(await play("cut-line-open")).toEqual([]);
  });
});
