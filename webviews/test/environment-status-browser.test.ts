// cmux-web-test-timeout: 300
// Live machine/environment picker captures: the gallery owns the three status variants and this
// test records the menu in both shipped browser engines for before/after review.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("environment-status-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const usable: [string, BrowserType][] = [];
  for (const pair of engines) {
    try {
      await (await pair[1].launch({ headless: true })).close();
      usable.push(pair);
    } catch {
      console.warn(`environment picker: ${pair[0]} cannot launch here`);
    }
  }
  if (usable.length === 0) {
    describe.skip("environment picker browser", () => test("browsers", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const entries =
    process.env.CMUX_MACHINES_BEFORE === "1"
      ? ["environment-picker"]
      : ["environment-picker", "environment-status-matrix", "environment-needs-update", "environment-needs-login"];
  const captures = process.env.CMUX_GALLERY_CAPTURE_DIR;
  const stageURL = (variant: string) => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    return `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-context", { frame: "component", variant, width: "760", height: "620", theme: "Apple System Colors" })}`;
  };
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of usable) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.composer-context", {
      browser: [...browsers.values()][0],
      params: { variant: entries[0], frame: "component" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });
  for (const [engine] of usable)
    for (const variant of entries) {
      test(`${engine} ${variant}: renders explicit machine state`, async () => {
        const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 620 } });
        await page.goto(stageURL(variant));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        await page.locator(".acpmux-env-popover").waitFor();
        await installPaintedFrames(page);
        await page.evaluate(async () => {
          await document.fonts.ready;
          const running = document
            .getAnimations()
            .filter(
              (animation) =>
                animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
            );
          await Promise.allSettled(running.map((animation) => animation.finished));
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
        });
        const states = await page.$$eval(".acpmux-env-status", (rows) =>
          rows.map((row) => row.getAttribute("data-status")),
        );
        expect(states.length).toBeGreaterThan(0);
        if (captures) await page.screenshot({ path: path.join(captures, `${variant}-${engine}.png`), fullPage: true });
        await page.close();
      });
    }
});
