// Scrolling up a long chat asks for older history well before the top, so the view never stops
// there waiting for a page (Leo 2026-10-29: "scrolling up when it paginates and loads... didnt we
// previously have it pretty fast? why is it sometimes blocking me from scrolling up further?").
// The reader scrolls up with real wheel input, one step a frame, while each older page takes
// 400 ms to land (a read from acpmux).
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-older-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-older-scroll: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript older scroll", () => test("webkit", () => {}));
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

  /// How far into the chat the view is: its offset less the height older pages added above the
  /// first row it started on. A page that lands moves the offset and the content alike, so this moves
  /// only with the reader's scroll (and with a correction that loses or adds to it).
  const place = () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const older = (window as unknown as { __older: { loaded(): number; total: number } }).__older;
    return {
      scrollTop: scroller.scrollTop,
      scrollHeight: scroller.scrollHeight,
      more: older.loaded() < older.total,
    };
  };

  /// Scrolls up `frames` wheel steps of `step` px, one a frame, and measures how far the view went
  /// into the chat against how far the wheel asked. WebKit applies a wheel step on its scrolling
  /// thread and may report it to the page a frame later, so the travel is read once the scroll has
  /// settled, never step by step.
  const scrollUp = async (page: Page, step: number, frames: number) => {
    let topFrames = 0;
    let wheeled = 0;
    await page.mouse.move(450, 350);
    const start = (await page.evaluate(place)) as ReturnType<typeof place>;
    for (let frame = 0; frame < frames; frame += 1) {
      const now = (await page.evaluate(place)) as ReturnType<typeof place>;
      if (now.more && now.scrollTop <= 1) topFrames += 1;
      if (!now.more && now.scrollTop <= 1) break;
      await page.mouse.wheel(0, -step);
      wheeled += step;
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    for (let frame = 0; frame < 20; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    const end = (await page.evaluate(place)) as ReturnType<typeof place>;
    const travel = start.scrollTop - end.scrollTop + (end.scrollHeight - start.scrollHeight);
    return { wheeled, travel: Math.round(travel), lost: Math.round(wheeled - travel), topFrames };
  };

  for (const step of [40, 100]) {
    test(`a ${step} px-a-frame scroll up asks for older pages well before the top`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await installPaintedFrames(page);
      await page.goto(
        `http://127.0.0.1:${port}/test/browser/transcript-older-scroll.html${process.env.OLDER_SCROLL_ALL ? "?all" : ""}`,
      );
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 5);
      // Notches glide over several frames (wheelGlide.ts) unless the host's animation switch is off;
      // this measures a precise trackpad's step-a-frame scroll.
      await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
      for (let frame = 0; frame < 10; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
      const frames = 300;
      const result = await scrollUp(page, step, frames);
      const asks = await page.evaluate(() => {
        const older = (window as unknown as { __older: { asks: { at: number; top: number; landed?: number }[] } })
          .__older;
        return older.asks.map((ask) => ({ top: Math.round(ask.top), ms: Math.round((ask.landed ?? NaN) - ask.at) }));
      });
      console.log(
        `transcript-older-scroll ${step}px: ${JSON.stringify({ ...result, asks: asks.length, first: asks.slice(0, 4) })}`,
      );
      if (!process.env.OLDER_SCROLL_ALL) expect(asks.length).toBeGreaterThan(1);
      // Each page is asked for at least four viewports above the view (two left a flick a fraction
      // of a second before the top), and the view never sat at the top waiting. The travel against
      // the wheel is logged: headless WebKit drops some of a fast wheel's distance with no paging
      // at all (OLDER_SCROLL_ALL), so it is not asserted.
      expect(Math.min(...asks.map((ask) => ask.top))).toBeGreaterThanOrEqual(4 * 700);
      expect(result.topFrames).toBe(0);
      await page.close();
    });
  }

  // Leo (2026-11-12): "THE PAGINATION/WHATEVER INFINITE SCROLL UP DOESN'T [...] WORK IT JUST [...]
  // SENDS ME TO THE BOTTOM", and "IT JUST DOESN'T WORK RIGHT NOW BECAUSE OF THIS [...] 'RECONNECT'".
  // A reconnect or a rebuild drew the chat's newest tail first (or no rows for a frame), without the
  // older pages the reader had scrolled up through: the offset clamped to the shorter tail's end, the
  // bottom, and nothing found the reader's row again. The reader scrolls up through N older pages and
  // stops; replies stream on, and the pane reconnects and rebuilds again and again. The row at the top
  // of the view never moves while it is drawn, comes back to the same place, and no painted frame
  // shows the view at the bottom.
  test("a reconnect or a rebuild while scrolled up keeps the reader's row and never goes to the bottom", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-older-scroll.html?latency=60`);
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 5);
    await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
    for (let frame = 0; frame < 10; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    // Up through four older pages, then stop well inside the paged-in history.
    await page.mouse.move(450, 350);
    const PAGES = 4;
    for (let frame = 0; frame < 400; frame += 1) {
      const asks = await page.evaluate(
        () =>
          (window as unknown as { __older: { asks: { landed?: number }[] } }).__older.asks.filter((a) => a.landed)
            .length,
      );
      if (asks >= PAGES) break;
      await page.mouse.wheel(0, -100);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    for (let frame = 0; frame < 30; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    // The reader's row: the first one whose top is in view.
    const anchor = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const top = scroller.getBoundingClientRect().top;
      for (const row of document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
        const at = row.getBoundingClientRect().top - top;
        if (at >= 0) return { id: row.dataset.rowId!, at };
      }
      return undefined;
    });
    expect(anchor).toBeDefined();
    // Every painted frame from here: how far the view is from its end, and where the reader's row is.
    await page.evaluate((id) => {
      const seen: { below: number; at?: number }[] = [];
      (window as unknown as { __frames: typeof seen }).__frames = seen;
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const row = scroller.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${CSS.escape(id)}"]`);
        seen.push({
          below: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
          at: row ? row.getBoundingClientRect().top - scroller.getBoundingClientRect().top : undefined,
        });
      });
    }, anchor!.id);
    const act = (what: "live" | "tail" | "empty") =>
      page.evaluate((what) => {
        const older = (window as unknown as { __older: { live(): void; reconnect(d: string): void } }).__older;
        if (what === "live") older.live();
        else older.reconnect(what);
      }, what);
    const frames = async (count: number) => {
      for (let frame = 0; frame < count; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    };
    for (let round = 0; round < 3; round += 1) {
      await act("live");
      await frames(3);
      // A reconnect draws the newest tail; the older pages read again bring the reader's row back.
      await act("tail");
      await frames(2);
      await act("live");
      await page.waitForFunction(
        (id) => Boolean(document.querySelector(`.acpmux-row[data-row-id="${CSS.escape(id)}"]`)),
        anchor!.id,
        { timeout: 20_000 },
      );
      await frames(10);
      // A rebuild draws no rows for a commit, then all of them.
      await act("empty");
      await frames(3);
      await act("live");
      await frames(5);
    }
    await frames(20);
    const seen = await page.evaluate(
      () => (window as unknown as { __frames: { below: number; at?: number }[] }).__frames,
    );
    const atBottom = seen.filter((frame) => frame.below <= 4).length;
    const moved = seen.filter((frame) => frame.at !== undefined && Math.abs(frame.at - anchor!.at) > 1);
    console.log(
      `transcript-older-scroll reconnect: ${JSON.stringify({ frames: seen.length, atBottom, moved: moved.length, first: moved.slice(0, 4), anchor })}`,
    );
    expect(seen.length).toBeGreaterThan(30);
    expect(atBottom).toBe(0);
    expect(moved).toEqual([]);
    expect(seen.at(-1)?.at).toBeCloseTo(anchor!.at, 0);
    await page.close();
  });

  test("a fast first scrub does not rebound to the tail while an older page is pending", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      (window as unknown as { __offsets: number[] }).__offsets = [];
      addEventListener(
        "scroll",
        (event) => {
          const target = event.target;
          if (target instanceof HTMLElement && target.classList.contains("acpmux-scroll"))
            (window as unknown as { __offsets: number[] }).__offsets.push(target.scrollTop);
        },
        true,
      );
    });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-older-scroll.html?tail=90&prompts&latency=5000`);
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 20);
    await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
    for (let frame = 0; frame < 12; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => ((window as unknown as { __offsets: number[] }).__offsets = []));
    await page.mouse.move(450, 350);
    const start = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
    // A rail-sized scrub reaches the reserve in one native step. The page remains pending long
    // enough to expose any write that sends the reader back to the loaded tail.
    await page.mouse.wheel(0, -100_000);
    await page.evaluate(() => window.cmuxPaintFrame());
    for (let frame = 0; frame < 6; frame += 1) await page.evaluate(() => window.cmuxPaintFrame());
    const offsets = await page.evaluate(() => (window as unknown as { __offsets: number[] }).__offsets);
    const end = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
    const min = Math.min(...offsets);
    const minAt = offsets.indexOf(min);
    const rebound = offsets.slice(minAt + 1).some((offset) => offset > min + 100);
    console.log(`transcript-older-scroll fast scrub: ${JSON.stringify({ start, min, end, offsets })}`);
    expect(offsets.length).toBeGreaterThan(0);
    expect(rebound).toBe(false);
    expect(end).toBeLessThanOrEqual(min + 1);
    expect(start - end).toBeGreaterThan(500);
    await page.close();
  });
});
