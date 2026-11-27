// The composer hat's strip, its "^ 20" pull tab and its tuck chevron do not flip under one pointer
// (Leo, 2026-11-27, on a recording where the hat went strip, pill, list, strip, pill with the pointer
// on the same spot: "this isn't great"). The pull tab and the hat's tuck chevron stand at the same
// place on the composer's top edge, and the hat remounts on the pull tab's click, so its chevron
// showed under the stationary pointer and the next click there tucked it again.
//
// Real Chromium (Playwright), gallery `agent-pane.subagent-tray`, variant `tucked-count`: a pointer
// click on the pull tab brings the hat back with its tuck chevron still away; a pointer that only
// moves over the hat changes nothing; a second click at the same point opens or leaves the hat, never
// tucks it; once the pointer has left and returned, the chevron shows as before.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tray-pull-click-no-flip.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.subagent-tray";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "tucked-count" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  test("a click on the pull tab leaves no tuck chevron under the pointer; leaving and returning brings it back", async () => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "tucked-count" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const tab = await page.locator(".acpmux-tray-pull__tab").boundingBox();
      const x = tab!.x + tab!.width / 2;
      const y = tab!.y + tab!.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.up();
      await page.waitForSelector(".acpmux-running-tray");
      expect(await page.locator(".acpmux-tray-pull").count()).toBe(0);
      const tuck = () =>
        page.evaluate(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-running-tray__tuck")!;
          const style = getComputedStyle(node);
          return { opacity: style.opacity, events: style.pointerEvents };
        });
      // The pointer only passes over the hat: nothing flips, the chevron stays away.
      for (const dx of [1, 3, -2, 5]) await page.mouse.move(x + dx, y + 1);
      await page.waitForTimeout(400);
      expect(await tuck()).toEqual({ opacity: "0", events: "none" });
      expect(await page.locator(".acpmux-tray-pull").count()).toBe(0);
      // Left once and back: the chevron is revealed as before.
      await page.mouse.move(x, 5);
      await page.mouse.move(x + 150, y);
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".acpmux-running-tray__tuck")!).opacity === "1",
      );
      expect((await tuck()).events).toBe("auto");
    } finally {
      await page.close();
    }
  });
});
