// l10n-allow-file: the gallery fixture supplies the transcript's rows.
// Closing a command row leaves no ghost band (Leo's 05:30Z video, 0:42: after a click on "Check
// whether lw#7020 ...", a band with a faint "Shell 0.0s" stayed under the closed row while it shut).
// The fold used to play height and opacity on one curve, so the leaving text tracked the share of
// height left: faint but visible on a band that took most of the fold to shut. Exit before move
// (exitLead.ts `exitThenClose`, design/chat-fold-motion.md) takes the ink to 0 while the height
// holds, then shuts the height. Leo, 2026-11-21: "we must hide text faster and sooner". The bar is
// what he objected to: once the height moves, no frame draws leaving text faint but visible on a
// band 12 px or taller. A fully transparent band shutting is the fold's own motion.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("command-close-no-ghost-band.test.ts", async () => {
  const ENTRY = "agent-pane.row-anatomy";
  const VARIANT = "one-rule";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("command-close-no-ghost-band: skipping (run `bunx playwright install chromium`)");
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    // A cold server can miss the frame's first dynamic import; the next warm finds it built.
    for (let tries = 0; ; tries++) {
      try {
        await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
        break;
      } catch (error) {
        if (tries >= 2) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    test(`closing a command row's card leaves no near-blank band (${colorScheme})`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 800, height: 1000 } });
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 760, colorScheme })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 60_000,
      });
      const header = page.locator("button[aria-expanded='true']", { hasText: /Listed workflow runs/ }).first();
      await header.waitFor();
      await page.evaluate(async () => {
        for (let i = 0; i < 20; i++) await window.cmuxPaintFrame();
      });
      // Every painted frame of the close: the body's drawn height and its opacity.
      await page.evaluate(() => {
        const button = [...document.querySelectorAll("button[aria-expanded]")].find((node) =>
          /Listed workflow runs/.test(node.textContent ?? ""),
        )!;
        const step = button.closest(".cv-step") ?? button.parentElement!;
        const fold = step.querySelector<HTMLElement>(".cv-fold")!;
        const frames: { h: number; o: number }[] = [];
        (window as unknown as { closeFrames: typeof frames }).closeFrames = frames;
        const start = performance.now();
        window.cmuxAfterPaint(() => {
          if (!fold.isConnected) return false;
          frames.push({ h: fold.getBoundingClientRect().height, o: Number(getComputedStyle(fold).opacity) });
          return performance.now() - start < 1500;
        });
      });
      await header.click();
      await page.waitForFunction(() => {
        const frames = (window as unknown as { closeFrames: { h: number }[] }).closeFrames;
        return frames.length > 0 && frames.at(-1)!.h < 0.5;
      });
      const frames = await page.evaluate(
        () => (window as unknown as { closeFrames: { h: number; o: number }[] }).closeFrames,
      );
      if (process.env.GHOST_BAND_FRAMES)
        console.log(colorScheme, JSON.stringify(frames.map((one) => [Math.round(one.h), +one.o.toFixed(2)])));
      const full = frames[0]!.h;
      // A card worth checking, and a close that played (frames between open and shut).
      expect(full).toBeGreaterThan(60);
      expect(frames.filter((one) => one.h > 0.5 && one.h < full - 0.5).length).toBeGreaterThan(2);
      // It fades out (Leo, 2026-10-24: "Fade out, yes").
      expect(frames.some((one) => one.h > 0.5 && one.o < 0.99)).toBe(true);
      // Once the height moves (after the exit lead), no frame draws faint leftover text on a band.
      const ghosts = frames.filter((one) => one.h < full - 0.5 && one.h >= 12 && one.o > 0.02 && one.o < 0.35);
      expect(ghosts.map((one) => `${one.h.toFixed(0)}px at ${one.o.toFixed(2)}`)).toEqual([]);
      await page.close();
    });
  }
});
