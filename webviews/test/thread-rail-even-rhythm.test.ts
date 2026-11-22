// The prompt rail's ticks read evenly spaced (Leo, 2026-11-06: "you guys didn't fix the spacing on
// this left side session rail thing"; leo-workspace design/session-rail.md). Every row is one pitch
// tall, so the drawn ticks are one pitch apart, and every resting tick draws at one weight: a tick
// drawn fainter than its neighbours reads as a gap, and the rail reads as pairs with wide gaps
// between them. The default arms, in Chromium, over the gallery's chats: a plain one scrolled into a
// list longer than the rail (agent-pane.thread-minimap seventy-prompts), and one with runs of
// messages from other chats between the person's prompts (agent-pane.thread-minimap-incoming-fold,
// agent-pane.thread-minimap-incoming).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-even-rhythm.test.ts", async () => {
  setDefaultTimeout(240_000);
  const WIDTH = 1040;
  const CASES = [
    { entry: "agent-pane.thread-minimap", variant: "seventy-prompts" },
    { entry: "agent-pane.thread-minimap-incoming-fold", variant: "rest" },
    { entry: "agent-pane.thread-minimap-incoming", variant: "states" },
  ] as const;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("prompt rail: even rhythm", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, CASES[0].entry, { browser, params: { variant: CASES[0].variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Tick = { y: number; tone: string; incoming: boolean; opacity: number; color: string };
  const read = async (entry: string, variant: string): Promise<{ pitch: number; ticks: Tick[] }> => {
    const page = await browser.newPage({ viewport: { width: WIDTH, height: 640 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: WIDTH, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      // Off the rail, so no tick is hovered.
      await page.mouse.move(WIDTH - 10, 600);
      await page.evaluate(() => Promise.all(document.getAnimations().map((animation) => animation.finished)));
      return await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
        const pitch = parseFloat(getComputedStyle(list).getPropertyValue("--acpmux-minimap-pitch"));
        const ticks = [...list.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => {
          const bar = tick.querySelector<HTMLElement>(".acpmux-minimap__bar")!;
          const style = getComputedStyle(bar);
          return {
            y: bar.getBoundingClientRect().top,
            tone: tick.dataset.tone ?? "",
            incoming: tick.hasAttribute("data-incoming"),
            opacity: Number(style.opacity),
            color: style.backgroundColor,
          };
        });
        return { pitch, ticks };
      });
    } finally {
      await page.close();
    }
  };

  for (const { entry, variant } of CASES) {
    test(`${entry} ${variant}: the ticks are one pitch apart and every resting tick draws at one weight`, async () => {
      const { pitch, ticks } = await read(entry, variant);
      expect(pitch).toBeGreaterThan(0);
      expect(ticks.length).toBeGreaterThan(8);
      const gaps = ticks.slice(1).map((tick, index) => Math.round((tick.y - ticks[index]!.y) * 100) / 100);
      expect(new Set(gaps)).toEqual(new Set([pitch]));
      const resting = ticks.filter((tick) => tick.tone === "rest");
      expect(resting.length).toBeGreaterThan(4);
      // The other chats' messages are on this rail too, at the person's weight.
      if (entry !== "agent-pane.thread-minimap") expect(resting.some((tick) => tick.incoming)).toBe(true);
      expect([...new Set(resting.map((tick) => `${tick.color} @ ${tick.opacity}`))]).toHaveLength(1);
    });
  }
});
