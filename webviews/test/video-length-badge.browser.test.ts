// Every video tile's length badge, at every size the pane draws one, sits on one line inside its
// tile's bottom-right corner and never over the play glyph's centre, or is not drawn (Leo,
// 2026-11-11, of a 36 px chip whose "0:32" broke onto two lines over its play glyph: "this preview,
// the time is on the wrong place ... we should never be able to see this"). The gallery's
// agent-pane.video-length-badge draws the composer's strip chip, the chip in the text, a sent tile
// and a queued tile, each portrait, square and wide, with "0:32", "12:34" and "1:02:03"
// (composer/videoLengthFit.ts holds the rule).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("video-length-badge.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("video-length-badge: skipping (run `bunx playwright install chromium`)");
    describe.skip("video length badge", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.video-length-badge";
  const SIZES = ["strip", "inline", "sent", "queued"] as const;
  const LENGTHS = ["0:32", "12:34", "1:02:03"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "corner-or-hidden" } });
  }, 110_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Cell = {
    size: string;
    shape: string;
    length: string;
    tile: { width: number; height: number };
    /// The badge is drawn with its length.
    shown: boolean;
    /// The text's line boxes (one per line it takes).
    lines: number;
    whiteSpace: string;
    inside: boolean;
    coversCentre: boolean;
    /// The tile still names its length to a reader (its label or tooltip).
    labelled: boolean;
  };

  async function cells(variant: string, deviceScaleFactor = 1): Promise<Cell[]> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1180, height: 760 }, deviceScaleFactor });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 60_000,
      });
      // Every poster drawn (a queued tile's width is its poster's shape), and the fonts in.
      await page.waitForFunction(
        () =>
          document.querySelectorAll("[data-size]").length === 36 &&
          [...document.querySelectorAll<HTMLImageElement>("[data-size] img")].every(
            (image) => image.complete && image.naturalWidth > 0,
          ),
        undefined,
        { timeout: 30_000 },
      );
      await page.evaluate(() => document.fonts.ready);
      // Two frames: a tile resized by its poster is measured again in its observer.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      if (process.env.FAST_CHECKS_OUT)
        await page.screenshot({
          path: path.join(process.env.FAST_CHECKS_OUT, `video-length-badge-${variant}@${deviceScaleFactor}x.png`),
          fullPage: true,
        });
      return await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>("[data-size]")].map((cell) => {
          const badge = cell.querySelector<HTMLElement>("[data-video-length]")!;
          const tile = badge.parentElement!;
          // A queued tile's badge is its glyph and its length together; its length is the time.
          const text = badge.querySelector<HTMLElement>(".acpmux-queued-video-time") ?? badge;
          const tileBox = tile.getBoundingClientRect();
          const box = badge.getBoundingClientRect();
          const shown =
            getComputedStyle(badge).display !== "none" &&
            getComputedStyle(badge).visibility !== "hidden" &&
            getComputedStyle(text).display !== "none" &&
            box.width > 0;
          const range = document.createRange();
          range.selectNodeContents(text);
          const tops = new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top)));
          const glyph = tile.querySelector<HTMLElement>("[data-video-glyph]")?.getBoundingClientRect();
          // The glyph's centre; a queued tile has its glyph in the badge, so the tile's own centre.
          const cx = glyph ? glyph.left + glyph.width / 2 : tileBox.left + tileBox.width / 2;
          const cy = glyph ? glyph.top + glyph.height / 2 : tileBox.top + tileBox.height / 2;
          const length = cell.dataset.length!;
          const named = [
            tile.getAttribute("aria-label"),
            tile.getAttribute("title"),
            tile.closest("[title]")?.getAttribute("title"),
          ];
          return {
            size: cell.dataset.size!,
            shape: cell.dataset.shape!,
            length,
            tile: { width: Math.round(tileBox.width), height: Math.round(tileBox.height) },
            shown,
            lines: tops.size,
            whiteSpace: getComputedStyle(text).whiteSpace,
            inside:
              box.left >= tileBox.left + 1.5 &&
              box.top >= tileBox.top + 1.5 &&
              box.right <= tileBox.right - 1.5 &&
              box.bottom <= tileBox.bottom - 1.5,
            coversCentre: box.left <= cx && cx <= box.right && box.top <= cy && cy <= box.bottom,
            labelled: named.some((name) => name?.includes(length)),
          };
        }),
      );
    } finally {
      await page.close();
    }
  }

  for (const scale of [1, 2])
    test(`at ${scale}x every drawn length is one line inside its tile's corner, clear of the glyph's centre`, async () => {
      const all = await cells("corner-or-hidden", scale);
      expect(all).toHaveLength(SIZES.length * 9);
      for (const size of SIZES) expect(all.filter((cell) => cell.size === size)).toHaveLength(9);
      for (const size of SIZES)
        for (const length of LENGTHS)
          expect(all.filter((cell) => cell.size === size && cell.length === length)).toHaveLength(3);
      const bad = all.filter(
        (cell) =>
          cell.whiteSpace !== "nowrap" || (cell.shown && (cell.lines !== 1 || !cell.inside || cell.coversCentre)),
      );
      expect(bad).toEqual([]);
      // Hidden or not, a tile still names its length.
      expect(all.filter((cell) => cell.size !== "queued" && !cell.labelled)).toEqual([]);
      const shown = (size: string) =>
        all.filter((cell) => cell.size === size && cell.shown).map((c) => `${c.shape} ${c.length}`);
      // A sent tile has room for every length at every shape.
      expect(shown("sent")).toHaveLength(9);
      // The strip's chip keeps its length where it has room: every short one, and every length on a wide one.
      expect(shown("strip")).toEqual(
        expect.arrayContaining(["portrait 0:32", "square 0:32", "wide 0:32", "wide 12:34", "wide 1:02:03"]),
      );
      // A wide queued tile keeps a short length beside its glyph.
      expect(shown("queued")).toEqual(expect.arrayContaining(["wide 0:32"]));
      // Leo's chip: the portrait chip in the text (36 × 48) has no room, so it draws no length.
      const leos = all.find((cell) => cell.size === "inline" && cell.shape === "portrait" && cell.length === "0:32")!;
      expect(leos.tile).toEqual({ width: 36, height: 48 });
      expect(leos.shown).toBe(false);
    });

  // The old rule, kept as the gallery's `before` look, fails the same checks: the proof the test
  // reads the defect Leo saw.
  test("the old rule breaks the length over the glyph on Leo's chip", async () => {
    const all = await cells("before");
    const leos = all.find((cell) => cell.size === "inline" && cell.shape === "portrait" && cell.length === "0:32")!;
    expect(leos.shown).toBe(true);
    expect(leos.lines).toBeGreaterThan(1);
    for (const variant of ["always", "small-glyph"]) await cells(variant);
  });
});
