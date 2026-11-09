// Leo 2026-11-08: "when we have the composer grow a bit if it's not long enough to actually be
// scrollable stop showing a flash of the thumb scrollbar". The prompt field keeps its minimal
// scroller's thumb whenever its text overflows (scrollers.ts MINIMAL_SCROLLER_CSS), and while it
// grows to a new line (composer/fieldGrowth.ts) the text is already a line taller than the moving
// box, so the thumb drew for the length of the motion although nothing is left to scroll once it
// lands. Read from the pixels of the scroller's lane in headless Chromium, with its scrollbars
// drawn (no --hide-scrollbars) and the page's animations slowed so the motion spans many reads:
//
// - Shift-Return in a one-line draft: some read mid-motion has the text overflowing the field
//   (scrollHeight > clientHeight), and no read, during or after, shows ink in the lane.
// - A draft past the field's cap: the thumb shows (the fix hides only a move the text fits).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-grow-no-thumb.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-grow-no-thumb", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  /** A blank page that decodes the lane captures, so the stage under test does no extra work. */
  let decoder: Page;
  const FIELD = ".acpmux-composer-box .acpmux-md-field";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    // The scrollbars drawn, as in the app: Playwright hides them by default.
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "codex-grow-line" } });
    decoder = await browser.newPage();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The most any pixel of the field's scrollbar lane differs from the lane's own commonest colour:
   *  near 0 for a clear lane, the thumb's ink (38% of the text colour) when it is drawn. The lane's
   *  middle only, where the thumb draws: its 2 px transparent border at each side (and the box's rim
   *  beside it), and the track's 10 px inset at each end (the box's rounded corners). */
  const laneInk = async (page: Page) => {
    const lane = await page.evaluate((selector) => {
      const field = document.querySelector<HTMLElement>(selector)!;
      const r = field.getBoundingClientRect();
      const lane = field.offsetWidth - field.clientWidth;
      return { x: r.right - lane + 2, y: r.top + 10, width: lane - 4, height: r.height - 20, lane };
    }, FIELD);
    expect(lane.lane).toBeGreaterThan(4);
    const png = await page.screenshot({ clip: { x: lane.x, y: lane.y, width: lane.width, height: lane.height } });
    return decoder.evaluate(async (data) => {
      const image = new Image();
      image.src = `data:image/png;base64,${data}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, image.width, image.height).data;
      const counts = new Map<number, number>();
      for (let i = 0; i < pixels.length; i += 4) {
        const color = (pixels[i]! << 16) | (pixels[i + 1]! << 8) | pixels[i + 2]!;
        counts.set(color, (counts.get(color) ?? 0) + 1);
      }
      let base = 0;
      let most = -1;
      for (const [color, count] of counts) if (count > most) [base, most] = [color, count];
      let ink = 0;
      for (let i = 0; i < pixels.length; i += 4)
        ink = Math.max(
          ink,
          Math.abs(pixels[i]! - (base >> 16)) +
            Math.abs(pixels[i + 1]! - ((base >> 8) & 255)) +
            Math.abs(pixels[i + 2]! - (base & 255)),
        );
      return ink;
    }, png.toString("base64"));
  };

  const fit = (page: Page) =>
    page.evaluate((selector) => {
      const field = document.querySelector<HTMLElement>(selector)!;
      return {
        scroll: field.scrollHeight,
        client: field.clientHeight,
        moving: field.getAnimations().length > 0,
      };
    }, FIELD);

  const rest = (page: Page) =>
    page.waitForFunction((selector) => document.querySelector(selector)!.getAnimations().length === 0, FIELD);

  const open = async (theme: string) => {
    const page = await browser.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 1 });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant: "codex-grow-line", theme })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    // A tenth of the speed: the growth (a spring of a few hundred ms) spans many lane reads.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.1 });
    await page.locator(`${FIELD} .ProseMirror`).click();
    await page.keyboard.press("Control+End");
    await page.mouse.move(0, 0);
    await rest(page);
    return page;
  };

  for (const theme of ["Apple System Colors", "Apple System Colors Light"])
    test(`${theme}: a field that grows by a line it fits draws no thumb; one past its cap does`, async () => {
      const page = await open(theme);
      try {
        const before = await fit(page);
        expect(before.scroll).toBeLessThanOrEqual(before.client);
        const clear = await laneInk(page);
        expect(clear).toBeLessThan(24);

        await page.keyboard.press("Shift+Enter");
        await page.keyboard.type("and the 404 one");
        const reads: { scroll: number; client: number; moving: boolean; ink: number }[] = [];
        for (let index = 0; index < 60; index++) {
          const state = await fit(page);
          const ink = await laneInk(page);
          reads.push({ ...state, ink });
          if (!state.moving && index > 2) break;
        }
        await rest(page);
        const after = await fit(page);
        console.log(`GROW_NO_THUMB ${theme} ${JSON.stringify({ before, after, reads })}`);
        // It grew by a line, and still fits.
        expect(after.client).toBeGreaterThan(before.client);
        expect(after.scroll).toBeLessThanOrEqual(after.client);
        // The motion was caught mid-way with the text overflowing its moving box: the state that
        // drew the thumb.
        expect(reads.some((read) => read.moving && read.scroll > read.client + 1)).toBe(true);
        for (const read of reads) expect(read.ink, JSON.stringify(read)).toBeLessThan(24);
        expect(await laneInk(page)).toBeLessThan(24);

        // Past the cap, the thumb shows once the field rests, and scrolling still works.
        for (let line = 0; line < 24; line++) {
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.type(`line ${line}`);
        }
        await rest(page);
        const capped = await fit(page);
        expect(capped.scroll).toBeGreaterThan(capped.client + 1);
        expect(await laneInk(page)).toBeGreaterThanOrEqual(24);
        const scrolled = await page.evaluate((selector) => {
          const field = document.querySelector<HTMLElement>(selector)!;
          field.scrollTop = 0;
          return field.scrollTop === 0 && field.scrollHeight > field.clientHeight;
        }, FIELD);
        expect(scrolled).toBe(true);
      } finally {
        await page.close();
      }
    });
});
