// Leo (2026-11-01): "there's a layout shift when i expand it". Opening or folding the running tray
// over the composer moves no transcript row, on any painted frame; the reader's wheel past the end
// then brings the rows under what opened into view.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-expand-shift.test.ts", async () => {
  const ENTRY = "agent-pane.subagent-tray";
  const VARIANT = "expand-on-composer";
  setDefaultTimeout(180_000);
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
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  /** Folds the tray (the fixture's short list starts open) and returns to the latest row, so the
   *  room under the last row is the folded tray's: the reader scrolls up, then back to the end. */
  const foldAtLatest = async (page: Page) => {
    const head = page.locator(".acpmux-running-tray__head");
    if ((await head.getAttribute("aria-expanded")) === "true") {
      await head.click();
      await page.waitForFunction(() => !document.querySelector(".acpmux-running-tray__fold"));
    }
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 40);
    await page.mouse.wheel(0, -300);
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop > 100;
    });
    for (let turn = 0; turn < 6; turn++) await page.mouse.wheel(0, 240);
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
    // Two frames for the room to settle at the end.
    await page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
    );
  };

  /** Clicks the tray's header and returns, for each frame painted after it, how far the latest row
   *  moved and where the tray's top was drawn. */
  const toggle = (page: Page) =>
    page.evaluate(async () => {
      const latest = () =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-row")].at(-1)!.getBoundingClientRect().top;
      const trayTop = () => document.querySelector<HTMLElement>(".acpmux-running-tray")!.getBoundingClientRect().top;
      // After the frame paints: a task queued from its animation frame callback.
      const painted = () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => {
            const channel = new MessageChannel();
            channel.port1.onmessage = () => resolve();
            channel.port2.postMessage(0);
          }),
        );
      const before = latest();
      const trayBefore = trayTop();
      document.querySelector<HTMLElement>(".acpmux-running-tray__head")!.click();
      const frames: { moved: number; tray: number }[] = [];
      for (let index = 0; index < 20; index++) {
        await painted();
        frames.push({ moved: latest() - before, tray: trayTop() - trayBefore });
      }
      return frames;
    });

  test("opening and folding the tray at the latest row moves no transcript row", async () => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const head = page.locator(".acpmux-running-tray__head");
      await foldAtLatest(page);
      // The view is at the latest row, which runs past the pane.
      const scroller = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return { top: node.scrollTop, end: node.scrollHeight - node.clientHeight };
      });
      expect(scroller.end).toBeGreaterThan(0);
      expect(scroller.end - scroller.top).toBeLessThanOrEqual(2);

      const opened = await toggle(page);
      expect(await head.getAttribute("aria-expanded")).toBe("true");
      // It opened, up over the transcript's foot.
      expect(Math.min(...opened.map((frame) => frame.tray))).toBeLessThan(-20);
      for (const frame of opened) expect(Math.abs(frame.moved)).toBeLessThanOrEqual(0.5);

      const folded = await toggle(page);
      expect(await head.getAttribute("aria-expanded")).toBe("false");
      for (const frame of folded) expect(Math.abs(frame.moved)).toBeLessThanOrEqual(0.5);
    } finally {
      await page.close();
    }
  });

  test("the wheel past the end shows the rows under an opened tray", async () => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await foldAtLatest(page);
      await toggle(page);
      const covered = () =>
        page.evaluate(() => {
          const last = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].at(-1)!.getBoundingClientRect();
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!.getBoundingClientRect();
          return last.bottom - tray.top;
        });
      // What opened lies over the latest row's foot.
      expect(await covered()).toBeGreaterThan(0.5);
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + 40);
      for (let turn = 0; turn < 6; turn++) await page.mouse.wheel(0, 240);
      await page.waitForFunction(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
      });
      // At the end now, the latest row ends above the opened tray.
      expect(await covered()).toBeLessThanOrEqual(0.5);
    } finally {
      await page.close();
    }
  });
});
