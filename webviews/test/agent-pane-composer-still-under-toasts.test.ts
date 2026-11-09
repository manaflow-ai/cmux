// cmux-web-test-timeout: 240
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// The composer never moves for a toast (Leo, 2026-11-07: "The composer should never ever rise up
// because there's some sort of ... tooltip type thing ... The composer should basically, like, never
// move ... If it needs to move because, like, the panes shift, sure, but otherwise, no."). A divider
// drag's modifier hint ("⇧ Snap: halves and thirds only") is a toast; before this, the pane gave the
// page the toasts' band (`__cmuxToastRoom`, `--cmux-toast-room`) and the shell padded its foot by it,
// so the stage shrank and the composer rose ~110 px while the hint showed. Now the toasts lift above
// the composer instead (the page reports its bottom stack, `pane.toastAvoidance`), and nothing the
// host says about toasts reaches the page's layout.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a seeded
// chat. Both ways the host used to give the band (the page function and the root variable) leave
// the composer's bottom and the stage's height where they were.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-composer-still-under-toasts.test.ts", async () => {
  setDefaultTimeout(220_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The composer card's bottom and the stage's height, in CSS pixels, after two frames.
  const measure = (page: Page) =>
    page.evaluate(async () => {
      // raf-read: the boxes come from getBoundingClientRect, which runs style and layout itself; the frames only let a
      // host call's effects (a variable, an animation start) land first, and nothing here needs a painted frame.
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      const composer = document.querySelector("form.acpmux-composer")!.getBoundingClientRect();
      const stage = document.querySelector(".acpmux-main > .acpmux-stage")!.getBoundingClientRect();
      return { composerBottom: composer.bottom, composerTop: composer.top, stage: stage.height };
    });

  test("a toast over the pane's foot moves neither the composer nor the stage", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(6))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.waitForSelector("form.acpmux-composer", { timeout: 60_000 });
    const before = await measure(page);
    expect(before.composerBottom).toBeGreaterThan(0);

    // What the host sent while a hint toast showed over the pane's foot (84 px band, at once).
    await page.evaluate(() => {
      (globalThis as any).__cmuxToastRoom?.(84, 0);
    });
    const shown = await measure(page);
    // And the band itself on the root, however it gets there.
    await page.evaluate(() => document.documentElement.style.setProperty("--cmux-toast-room", "84px"));
    const variable = await measure(page);
    // The toast went.
    await page.evaluate(() => {
      (globalThis as any).__cmuxToastRoom?.(0, 0);
      document.documentElement.style.removeProperty("--cmux-toast-room");
    });
    const gone = await measure(page);
    await page.close();
    console.log(`COMPOSER-UNDER-TOASTS ${JSON.stringify({ before, shown, variable, gone })}`);
    for (const after of [shown, variable, gone]) {
      expect(after.composerBottom).toBeCloseTo(before.composerBottom, 1);
      expect(after.composerTop).toBeCloseTo(before.composerTop, 1);
      expect(after.stage).toBeCloseTo(before.stage, 1);
    }
  });
});
