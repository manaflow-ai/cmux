// A chat that opens on its tail, its older history still being read, never pushes a scroll up back
// down, and the page that lands draws in above with the reader's rows held where they are (Leo,
// 2026-11-06: "when it only loads in, like, the last three prompts or so ... when I try to scroll
// up, it, like, thinks that I can, and then it doesn't actually let me scroll up. So it's just, like,
// this jittering. Like, I scroll and then it ... pushes me back to the bottom").
//
// The room held above the loaded rows for the unloaded history (conversation/olderReserve.ts) made
// the scroller taller than what it held: a wheel up went into that room, and the transcript put the
// offset back at the loaded rows' top, which for a short tail is the bottom, once per wheel step for
// as long as the page took. The harness opens a short tail with the chat's prompt count (so the room
// is held) and pages that take PAGE_MS, and scrolls up with real wheel input one step a frame.
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-tail-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  /// How long each older page takes to land: longer than the whole scroll up below.
  const PAGE_MS = 8000;
  const STEP = 40;
  const STEPS = 40;
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-tail-scroll: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript tail scroll", () => test("webkit", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-older-scroll.html");
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Probe = { offsets: number[] };
  /// The latest row's top on screen, as the frame painted it.
  const latestTop = () => {
    const rows = document.querySelectorAll<HTMLElement>(".acpmux-row");
    return rows[rows.length - 1]!.getBoundingClientRect().top;
  };
  /// Whether a page of older history has landed yet (runs in the page).
  const landed = () =>
    (window as unknown as { __older: { asks: { landed?: number }[] } }).__older.asks.some(
      (ask) => ask.landed !== undefined,
    );

  const open = async (tail: number): Promise<Page> => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    // Every offset the scroller reports, read before any of the page's own handlers can correct it.
    await page.addInitScript(() => {
      const probe: Probe = { offsets: [] };
      (window as unknown as { __probe: Probe }).__probe = probe;
      addEventListener(
        "scroll",
        (event) => {
          const target = event.target;
          if (target instanceof HTMLElement && target.classList.contains("acpmux-scroll"))
            probe.offsets.push(target.scrollTop);
        },
        true,
      );
    });
    await page.goto(
      `http://127.0.0.1:${port}/test/browser/transcript-older-scroll.html?tail=${tail}&prompts&latency=${PAGE_MS}`,
    );
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length >= 3);
    // A precise trackpad's step-a-frame scroll; notches would glide over several frames (wheelGlide.ts).
    await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
    for (let frame = 0; frame < 10; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => ((window as unknown as { __probe: Probe }).__probe.offsets = []));
    return page;
  };

  /// Scrolls up STEPS wheel steps, one a frame; the latest row's painted top after each.
  const wheelUp = async (page: Page, steps: number) => {
    await page.mouse.move(450, 350);
    const tops = [(await page.evaluate(latestTop)) as number];
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, -STEP);
      await page.evaluate(() => window.cmuxPaintFrame());
      tops.push((await page.evaluate(latestTop)) as number);
    }
    for (let frame = 0; frame < 5; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    tops.push((await page.evaluate(latestTop)) as number);
    return tops;
  };

  /// Each time the view went back down (the rows back up) while the reader only scrolled up.
  const pushedBack = (values: number[], down: 1 | -1) =>
    values.slice(1).filter((value, index) => down * (value - values[index]!) > 1).length;

  // Two prompts (shorter than the view) and four (a little over a view), as Leo's "last three".
  for (const tail of [6, 12]) {
    test(`a ${tail}-row tail: a scroll up is never pushed back down, and the late page lands above in place`, async () => {
      const page = await open(tail);
      const tops = await wheelUp(page, STEPS);
      const offsets = (await page.evaluate(
        () => (window as unknown as { __probe: Probe }).__probe.offsets,
      )) as number[];
      const waiting = !((await page.evaluate(landed)) as boolean);
      const backs = { rows: pushedBack(tops, -1), offsets: pushedBack(offsets, 1) };
      console.log(`transcript-tail-scroll ${tail} rows: ${JSON.stringify({ backs, tops, offsets })}`);
      // The whole scroll happened while the first page was still being read.
      expect(waiting).toBe(true);
      expect(backs).toEqual({ rows: 0, offsets: 0 });
      // The page lands: the rows in view stay where they are drawn.
      const before = tops.at(-1)!;
      await page.waitForFunction(landed, undefined, {
        timeout: PAGE_MS + 5000,
      });
      for (let frame = 0; frame < 10; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
      expect(Math.abs(((await page.evaluate(latestTop)) as number) - before)).toBeLessThanOrEqual(1);
      // And the reader goes on up into it.
      const after = await wheelUp(page, 10);
      expect(after.at(-1)! - after[0]!).toBeGreaterThan(5 * STEP);
      expect(pushedBack(after, -1)).toBe(0);
      await page.close();
    });
  }
});
