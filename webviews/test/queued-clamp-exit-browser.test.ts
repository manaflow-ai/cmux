// A queued prompt's text leaves with its actions. Leo, 2026-11-27 (ask-0b971a8f69), of the queued
// row's hover actions: "this animation for this coming out is a bit slow". cmux#62344 put the row's
// actions and the text's cover on the motion scale (in 120 ms, out 80 ms); router-review F1 found
// the text's cover still left in 180 ms, as `.ui-reveal-text` (ui/motion/motion.css) loads later at
// the same specificity and won. cmux#63281 scoped the leave rule under the row. This draws the
// composer gallery's two queued prompts and reads each row's computed timing: the text's cover and
// the actions leave in 80 ms (0 s under reduced motion) and come in on 120 ms when hovered.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("queued-clamp-exit-browser.test.ts", async () => {
  const ENTRY = "src/agent-session/acpmux/composer.gallery.ts";
  setDefaultTimeout(360_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, `/gallery/frame.html?entryPath=${ENTRY}`, { timeoutMs: 30_000, limit: 0 });
    await warmViteServer(vite, "/src/gallery/frame/main.ts", { timeoutMs: 120_000, limit: 200 });
    await warmViteServer(vite, `/${ENTRY}`, { timeoutMs: 120_000, limit: 600 });
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Timing = { cover: string; actions: string };

  /// Each queued row's computed transition durations, at rest and with the pointer on the first row.
  async function timings(reducedMotion: boolean): Promise<{ rest: Timing[]; hovered: Timing }> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await page.goto(
        `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer&entryPath=${ENTRY}` +
          `&variant=queued&colorScheme=dark&width=normal${reducedMotion ? "&reducedMotion=1" : ""}`,
        { timeout: 300_000 },
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 60_000,
      });
      await page.waitForSelector(".acpmux-queued .acpmux-queued-clamp", { timeout: 60_000 });
      const read = () =>
        page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-queued")].map((row) => ({
            cover: getComputedStyle(row.querySelector(".acpmux-queued-clamp")!).transitionDuration,
            actions: getComputedStyle(row.querySelector(".acpmux-queued-actions")!).transitionDuration,
          })),
        );
      const rest = await read();
      await page.hover(".acpmux-queued >> nth=0");
      const hovered = (await read())[0]!;
      return { rest, hovered };
    } finally {
      await page.close();
    }
  }

  test("the queued text's cover leaves in 80 ms with its actions, and comes in on 120 ms", async () => {
    const { rest, hovered } = await timings(false);
    expect(rest.length).toBe(2);
    for (const row of rest) expect(row).toEqual({ cover: "0.08s", actions: "0.08s" });
    expect(hovered).toEqual({ cover: "0.12s", actions: "0.12s" });
  });

  test("under reduced motion the queued row neither leaves nor comes in over time", async () => {
    const { rest, hovered } = await timings(true);
    expect(rest.length).toBe(2);
    for (const row of rest) expect(row).toEqual({ cover: "0s", actions: "0s" });
    expect(hovered).toEqual({ cover: "0s", actions: "0s" });
  });
});
