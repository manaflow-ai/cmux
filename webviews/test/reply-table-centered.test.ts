// cmux-web-test-timeout: 120
// A reply's table narrower than the column sits centered in it; one wider than the column fills the
// column and scrolls sideways inside its own box, never past the column's edge (Leo 2026-11-22: "i
// dont know why we dont simply center tables in our agent chats").
//
// It renders `agent-pane.table-block` (TableBlock.gallery.ts) on the gallery stage in Chromium and
// measures the table's box against its column, the reply's own block.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/reply-table-centered.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reply-table-centered.test.ts", async () => {
  const ENTRY = "agent-pane.table-block";
  setDefaultTimeout(90_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("reply table centered", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 640 } });
    for (;;) {
      await page.goto(stageURL(variant, width));
      try {
        await page.waitForSelector(".cv-table-block .cv-table", { timeout: 30_000 });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };

  /** The table block's box, its column's content box, and its scroller's widths. */
  const geometry = (page: Page) =>
    page.evaluate(() => {
      const block = document.querySelector<HTMLElement>(".cv-table-block")!;
      const column = block.parentElement!;
      const style = getComputedStyle(column);
      const c = column.getBoundingClientRect();
      const left = c.left + Number.parseFloat(style.paddingLeft) + Number.parseFloat(style.borderLeftWidth);
      const right = c.right - Number.parseFloat(style.paddingRight) - Number.parseFloat(style.borderRightWidth);
      const b = block.getBoundingClientRect();
      const wrap = block.querySelector<HTMLElement>(".cv-table-wrap")!;
      return {
        leftGap: b.left - left,
        rightGap: right - b.right,
        columnWidth: right - left,
        blockWidth: b.width,
        scrollWidth: wrap.scrollWidth,
        clientWidth: wrap.clientWidth,
      };
    });

  for (const [variant, width] of [
    ["centered", 760],
    ["centered", 1200],
    ["rest", 760],
    ["rest", 1200],
  ] as const)
    test(`${variant} at ${width}px: a table narrower than the column is centered in it`, async () => {
      const page = await open(variant, width);
      const at = await geometry(page);
      console.log(`reply-table-centered ${variant} ${width}: ${JSON.stringify(at)}`);
      expect(at.blockWidth, "the table is narrower than its column").toBeLessThan(at.columnWidth - 8);
      expect(at.leftGap, "room on the left").toBeGreaterThan(4);
      expect(Math.abs(at.leftGap - at.rightGap), "the same room on each side").toBeLessThanOrEqual(1);
      await page.close();
    });

  for (const width of [420, 760])
    test(`too-wide at ${width}px: the table fills the column and scrolls in its own box`, async () => {
      const page = await open("too-wide", width);
      const at = await geometry(page);
      console.log(`reply-table-centered too-wide ${width}: ${JSON.stringify(at)}`);
      expect(Math.abs(at.leftGap), "starts at the column's start").toBeLessThanOrEqual(1);
      expect(at.rightGap, "never past the column's end").toBeGreaterThanOrEqual(-1);
      expect(at.scrollWidth, "scrolls sideways inside its box").toBeGreaterThan(at.clientWidth);
      await page.close();
    });
});
