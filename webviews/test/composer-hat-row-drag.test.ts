// cmux-web-test-timeout: 420
// The composer hat drags by whole rows (subagents/hatRows.ts, hatDrag.ts). Real pointer drags in
// Chromium and WebKit on the gallery's hat with several lines (`agent-pane.subagent-tray-rim`):
// - down from the top bar, it loses whole rows and stops at one; past it the band gives and, let go
//   past half a row, the hat hides to the pull tab;
// - up from the pull tab, it comes back a row at a time;
// - a click on the top bar goes between one row and the last height it had open; the arrow keys on
//   the focused top bar step a row; Escape mid-drag puts back where the drag began;
// - on every painted frame the list shows whole lines only (its height is the sum of its first lines'
//   heights), and the composer stays put under the hat (the dock grows upward, its foot never moves,
//   and the hat's foot meets the composer at the same gap).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Sample = {
  rows: number | null;
  /** The list's drawn height and its lines' heights in order (empty with no list). */
  list: number;
  lines: number[];
  band: boolean;
  trayTop: number;
  trayBottom: number;
  composerTop: number;
  composerHeight: number;
  dockBottom: number;
  pill: boolean;
};

await requireBrowserLane("composer-hat-row-drag.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.subagent-tray-rim";
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-hat-row-drag: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer hat row drag", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
    await warmGalleryFrame(server, ENTRY, { browser: browsers.get(engines[0]![0])!, params: { variant: "default" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await server?.close();
  });

  async function open(engine: string): Promise<Page> {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 720 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "default" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(".acpmux-running-tray[data-hat-rows] .acpmux-running-tray__list li");
    await installPaintedFrames(page);
    await settle(page);
    return page;
  }

  /** Ends every finite animation and waits two frames. */
  const settle = (page: Page) =>
    page.evaluate(async () => {
      for (const animation of document.getAnimations())
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null))));
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null))));
    });

  /** Starts sampling every painted frame. */
  const startSampling = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __samples: unknown[]; __stop?: () => void };
      w.__samples = [];
      const read = () => {
        const tray = document.querySelector<HTMLElement>(".acpmux-dock > .acpmux-running-tray");
        const composer = document.querySelector<HTMLElement>(".acpmux-composer-box")!.getBoundingClientRect();
        const dock = document.querySelector<HTMLElement>(".acpmux-dock")!.getBoundingClientRect();
        const list = tray?.querySelector<HTMLElement>(".acpmux-running-tray__fold");
        const rows = tray?.getAttribute("data-hat-rows");
        const box = tray?.getBoundingClientRect();
        w.__samples.push({
          rows: rows == null ? null : Number(rows),
          list: list ? list.getBoundingClientRect().height : 0,
          lines: list
            ? [...list.querySelectorAll<HTMLElement>(".acpmux-running-tray__list > li")].map(
                (line) => line.getBoundingClientRect().height,
              )
            : [],
          band: tray?.hasAttribute("data-band") ?? false,
          trayTop: box?.top ?? Number.NaN,
          trayBottom: box?.bottom ?? Number.NaN,
          composerTop: composer.top,
          composerHeight: composer.height,
          dockBottom: dock.bottom,
          pill: document.querySelector(".acpmux-tray-pull") !== null,
        });
      };
      read();
      w.__stop = window.cmuxAfterPaint(() => {
        read();
      });
    });
  const stopSampling = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __samples: Sample[]; __stop?: () => void };
      w.__stop?.();
      return w.__samples;
    });

  const rowsOf = (page: Page) =>
    page.evaluate(() => {
      const value = document.querySelector(".acpmux-running-tray")?.getAttribute("data-hat-rows");
      return value == null ? null : Number(value);
    });
  const center = async (page: Page, selector: string): Promise<[number, number]> => {
    const b = (await page.locator(selector).boundingBox())!;
    return [b.x + b.width / 2, b.y + b.height / 2];
  };
  const rowHeight = async (page: Page) => (await page.locator(".acpmux-running-tray__head").boundingBox())!.height;

  /** Moves the pressed pointer by `dy` px in steps of `step`, one painted frame after each. */
  async function drag(page: Page, x: number, from: number, dy: number, step = 3) {
    const steps = Math.max(1, Math.ceil(Math.abs(dy) / step));
    for (let index = 1; index <= steps; index++) {
      await page.mouse.move(x, from + (dy * index) / steps);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
  }

  /** Every painted frame, outside the band, draws whole lines; the composer and the dock's foot hold
   *  still; the hat's foot keeps its gap to the composer. */
  function wholeAndStill(samples: Sample[]) {
    const first = samples[0]!;
    const gap = first.composerTop - first.trayBottom;
    const cut: string[] = [];
    const moved: string[] = [];
    samples.forEach((sample, index) => {
      if (Math.abs(sample.composerTop - first.composerTop) > 0.5)
        moved.push(`frame ${index}: composer top ${sample.composerTop}`);
      if (Math.abs(sample.composerHeight - first.composerHeight) > 0.5) moved.push(`frame ${index}: composer height`);
      if (Math.abs(sample.dockBottom - first.dockBottom) > 0.5)
        moved.push(`frame ${index}: dock foot ${sample.dockBottom}`);
      if (!sample.pill && !first.pill && Math.abs(sample.composerTop - sample.trayBottom - gap) > 0.5)
        moved.push(`frame ${index}: hat foot ${sample.trayBottom} (gap ${sample.composerTop - sample.trayBottom})`);
      if (sample.band || sample.list <= 0.5 || sample.rows === null) return;
      // The list's height (less its 2px scroll padding allowance and the divider's) is a sum of its
      // first whole lines.
      let sum = 0;
      let whole = false;
      for (const line of sample.lines) {
        sum += line;
        if (Math.abs(sample.list - sum) <= 3) whole = true;
      }
      if (!whole) cut.push(`frame ${index}: list ${sample.list.toFixed(2)} over lines ${sample.lines.join(",")}`);
      // The rows it says it has are the lines it shows.
      const shown = sample.lines.reduce(
        (acc, line) => (acc.sum + line <= sample.list + 0.5 ? { sum: acc.sum + line, n: acc.n + 1 } : acc),
        { sum: 0, n: 0 },
      ).n;
      if (shown !== sample.rows - 1) cut.push(`frame ${index}: rows ${sample.rows} but ${shown} lines shown`);
    });
    expect({ cut, moved }).toEqual({ cut: [], moved: [] });
  }

  /** The hat's lines, and the rows it draws open: its header and every line. */
  const linesOf = (page: Page) => page.locator(".acpmux-running-tray__list > li").count();
  const range = (from: number, to: number) =>
    Array.from({ length: Math.abs(to - from) + 1 }, (_, index) => (from < to ? from + index : from - index));

  for (const [engine] of engines) {
    describe(engine, () => {
      test("a drag down from the top bar loses whole rows, stops at one, and rubber-bands past it", async () => {
        const page = await open(engine);
        try {
          // The gallery opens it at the default height, the header and up to five lines: all of its lines.
          const lines = await linesOf(page);
          expect(lines).toBeGreaterThanOrEqual(2);
          const top = Math.min(6, lines + 1);
          expect(await rowsOf(page)).toBe(top);
          const row = await rowHeight(page);
          const [x, y] = await center(page, ".acpmux-running-tray__head");
          await startSampling(page);
          await page.mouse.move(x, y);
          await page.mouse.down();
          const seen: number[] = [];
          for (let index = 1; index < top; index++) {
            await drag(page, x, y + (index - 1) * row, row);
            seen.push((await rowsOf(page))!);
          }
          expect(seen).toEqual(range(top - 1, 1));
          const down = (top - 1) * row;
          // Past the one row: it stays one row and gives under the pointer, never a whole row.
          await drag(page, x, y + down, row / 3);
          expect(await rowsOf(page)).toBe(1);
          const banded = await page.evaluate(() =>
            document.querySelector(".acpmux-running-tray")!.hasAttribute("data-band"),
          );
          expect(banded).toBe(true);
          // Back up short of half a row past it, let go: one row, not hidden, the band gone.
          await drag(page, x, y + down + row / 3, -row / 3 + 2);
          await page.mouse.up();
          await settle(page);
          const samples = await stopSampling(page);
          expect(await rowsOf(page)).toBe(1);
          expect(await page.locator(".acpmux-tray-pull").count()).toBe(0);
          expect(
            await page.evaluate(() => document.querySelector(".acpmux-running-tray")!.hasAttribute("data-band")),
          ).toBe(false);
          wholeAndStill(samples.filter((sample) => !sample.band));
          // The band never gave a whole row, and the composer stayed put under it.
          const folded = samples.find((sample) => sample.rows === 1 && !sample.band)!;
          const bands = samples.filter((sample) => sample.band);
          expect(bands.length).toBeGreaterThan(0);
          for (const sample of bands) {
            expect(folded.trayBottom - folded.trayTop - (sample.trayBottom - sample.trayTop)).toBeLessThan(row);
            expect(Math.abs(sample.composerTop - folded.composerTop)).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });

      test("let go past half a row beyond the one row, the hat hides; a drag up from the pill brings rows back one at a time", async () => {
        const page = await open(engine);
        try {
          const lines = await linesOf(page);
          const top = Math.min(6, lines + 1);
          const row = await rowHeight(page);
          let [x, y] = await center(page, ".acpmux-running-tray__head");
          await page.mouse.move(x, y);
          await page.mouse.down();
          await drag(page, x, y, (top - 1) * row + row * 0.75);
          await page.mouse.up();
          await settle(page);
          expect(await page.locator(".acpmux-tray-pull").count()).toBe(1);
          expect(await page.locator(".acpmux-running-tray").count()).toBe(0);

          // The tab's top half: the composer lies over its lower half (subagents.css).
          const tab = (await page.locator(".acpmux-tray-pull__tab").boundingBox())!;
          [x, y] = [tab.x + tab.width / 2, tab.y + 4];
          await page.mouse.move(x, y);
          await page.mouse.down();
          await startSampling(page);
          const seen: number[] = [];
          for (let index = 1; index <= lines + 1; index++) {
            await drag(page, x, y - (index - 1) * row, -row);
            seen.push((await rowsOf(page)) ?? 0);
          }
          await page.mouse.up();
          await settle(page);
          const samples = await stopSampling(page);
          expect(seen).toEqual(range(1, lines + 1));
          expect(await rowsOf(page)).toBe(lines + 1);
          expect(await page.locator(".acpmux-tray-pull").count()).toBe(0);
          wholeAndStill(samples.filter((sample) => !sample.pill));

          // The click on the top bar goes to one row and back to the rows it had open.
          await page.locator(".acpmux-running-tray__head").click();
          await settle(page);
          expect(await rowsOf(page)).toBe(1);
          await page.locator(".acpmux-running-tray__head").click();
          await settle(page);
          expect(await rowsOf(page)).toBe(lines + 1);
        } finally {
          await page.close();
        }
      });

      test("Escape mid-drag puts it back; the arrow keys on the focused top bar step a row", async () => {
        const page = await open(engine);
        try {
          const lines = await linesOf(page);
          const top = Math.min(6, lines + 1);
          const row = await rowHeight(page);
          const [x, y] = await center(page, ".acpmux-running-tray__head");
          await page.mouse.move(x, y);
          await page.mouse.down();
          await drag(page, x, y, (top - 2) * row);
          expect(await rowsOf(page)).toBe(2);
          await page.keyboard.press("Escape");
          await page.evaluate(() => window.cmuxPaintFrame());
          expect(await rowsOf(page)).toBe(top);
          // The pointer that lets go after it changes nothing.
          await page.mouse.move(x, y + top * row);
          await page.mouse.up();
          await settle(page);
          expect(await rowsOf(page)).toBe(top);

          await page.locator(".acpmux-running-tray__head").focus();
          await page.keyboard.press("ArrowDown");
          await settle(page);
          expect(await rowsOf(page)).toBe(top - 1);
          for (let press = 0; press < 3; press++) await page.keyboard.press("ArrowUp");
          await settle(page);
          // The header and every line at most.
          expect(await rowsOf(page)).toBe(lines + 1);
        } finally {
          await page.close();
        }
      });
    });
  }
});
