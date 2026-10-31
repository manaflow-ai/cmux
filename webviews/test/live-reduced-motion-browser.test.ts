// l10n-allow-file: synthetic streaming replies and test descriptions.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import type {} from "./browser/live-reduced-motion.harness";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("live-reduced-motion-browser.test.ts", async () => {
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers: Browser[] = [];
  const reply = "The streaming reply respects the current motion preference. ".repeat(20).trim();
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/live-reduced-motion.html");
  }, 120_000);
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
    await vite?.close();
  });
  async function changeMotion(page: Page, reduced: boolean) {
    // Emulation can return before Chromium dispatches the media-query event. Observe
    // the first frame after that event, rather than a frame racing its delivery.
    const next = page.evaluate(
      (matches) =>
        new Promise<ReturnType<typeof window.liveReducedMotion.sample>>((resolve) => {
          const query = matchMedia("(prefers-reduced-motion: reduce)");
          query.addEventListener(
            "change",
            () => {
              requestAnimationFrame(() => resolve(window.liveReducedMotion.sample()));
            },
            { once: true },
          );
          if (query.matches === matches) throw new Error("motion preference must change");
        }),
      reduced,
    );
    await page.emulateMedia({ reducedMotion: reduced ? "reduce" : "no-preference" });
    return next;
  }
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    test(`${name}: live Reduced Motion settles the mounted reply by the next frame`, async () => {
      const browser = await engine.launch({ headless: true });
      browsers.push(browser);
      const page = await browser.newPage({ reducedMotion: "no-preference" });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/live-reduced-motion.html`);
        await page.waitForFunction(() => !!window.liveReducedMotion);
        const before = await page.evaluate((text) => {
          const h = window.liveReducedMotion;
          h.render(text);
          for (let i = 0; i < 4; i++) h.step();
          return h.sample();
        }, reply);
        expect(before.text.length).toBeGreaterThan(0);
        expect(before.text.length).toBeLessThan(reply.length);
        expect(before.pending).toBe(1);
        expect(before.fresh).toBeGreaterThan(0);
        const after = await changeMotion(page, true);
        console.log(JSON.stringify({ engine: name, before, after }));
        if (process.env.CMUX_MOTION_CAPTURE && name === "chromium") {
          const png = await page.screenshot();
          console.log(`MOTION_CAPTURE ${process.env.CMUX_MOTION_CAPTURE} ${png.toString("base64")}`);
        }
        expect(after).toEqual({ text: reply, fresh: 0, pending: 0 });
        const next = `${reply} A newly received partial wor`;
        const delta = await page.evaluate((text) => {
          window.liveReducedMotion.render(text);
          return window.liveReducedMotion.step();
        }, next);
        expect(delta).toEqual({ text: next, fresh: 0, pending: 0 });
        await changeMotion(page, false);
        const resumed = await page.evaluate((text) => {
          const h = window.liveReducedMotion;
          h.render(`${text} more words arrive for a paced reveal`);
          const scheduled = h.sample();
          const stepped = h.step();
          return { scheduled, stepped };
        }, next);
        expect(resumed.scheduled.pending).toBe(1);
        expect(resumed.stepped.pending).toBeGreaterThanOrEqual(0);
        await page.evaluate(() => window.liveReducedMotion.unmount());
        await page.emulateMedia({ reducedMotion: "reduce" });
        expect((await page.evaluate(() => window.liveReducedMotion.nextPaint())).pending).toBe(0);
      } finally {
        await page.close();
      }
    }, 120_000);
  }
});
