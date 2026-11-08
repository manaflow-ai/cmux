// l10n-allow-file: fixture prompts and replies, not shipped UI.
// A fast wheel over the session rail shows a tick on every row in its view on every painted frame
// (Leo, 2026-10-31: "if i scroll too fast in the left scroll rail it can flicker and disapper at the
// edges"). The rail draws only the rows near its view (tickWindow.ts) and moves that window from its
// list's scroll event. The window followed a frame late and only 12 rows past each edge, and the rows
// past it were an empty spacer, so a fast wheel showed a blank strip at the edge the list scrolled
// toward for a frame, then the ticks popped in: the flicker at the edges.
//
// Each frame's drawn rows are read in its frame callbacks (they are what that frame paints) and the
// list's offset after the frame has painted (support/paintedFrames.ts); a row in the list's view with
// no tick in the frame is a blank the reader saw. Locally:
// CI=1 CMUX_BROWSER_TESTS=1 bun test test/thread-rail-fast-scroll-edges.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { PNG } from "pngjs";

await requireBrowserLane("thread-rail-fast-scroll-edges.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`thread-rail-fast-scroll-edges: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("rail fast scroll", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    current = browsers.values().next().value;
    // 3,000 prompts, as the rail latency cases (test/latency/actions.ts).
    pane = await papercutPane(() => current!, { turns: 3000, running: false });
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// A painted frame: the list's offset and view, the rows in that view with nothing on them (no tick
  /// drawn and no gap that paints resting ticks), the rows in it not drawn as ticks (the gap's), and
  /// the drawn ones in it that showed faded out (an entrance replayed at opacity 0).
  type Frame = {
    top: number;
    height: number;
    blank: number[];
    undrawn: number;
    faded: number[];
    /// How far the open preview card's middle sits from the pointer, in px (the card centers on the
    /// row under the pointer); undefined with no card open.
    cardOff?: number;
  };
  /// Starts recording every painted frame of the rail's list; `__railFrames()` stops and returns them.
  const record = (page: Page, pointerY: number) =>
    page.evaluate((pointerY) => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
      const count = Number(list.querySelector("li[aria-setsize]")?.getAttribute("aria-setsize") ?? 0);
      const frames: Frame[] = [];
      let drawn = new Map<number, HTMLElement>();
      let gaps: Array<[number, number, boolean]> = [];
      const stop = window.cmuxAfterPaint(
        () => {
          const top = list.scrollTop;
          const height = list.clientHeight;
          const blank: number[] = [];
          const faded: number[] = [];
          let undrawn = 0;
          // Every row the view shows at least half of.
          const first = Math.max(0, Math.ceil(top / 10 - 0.5));
          const last = Math.min(count, Math.floor((top + height) / 10 + 0.5));
          for (let row = first; row < last; row++) {
            const tick = drawn.get(row);
            if (tick) {
              const bar = tick.querySelector(".acpmux-minimap__bar");
              if (bar && Number(getComputedStyle(bar).opacity) < 0.39) faded.push(row);
              continue;
            }
            undrawn += 1;
            if (!gaps.some(([from, to, paints]) => paints && row >= from && row < to)) blank.push(row);
          }
          const card = document.querySelector<HTMLElement>(".acpmux-minimap__card");
          let cardOff: number | undefined;
          if (card) {
            const box = card.getBoundingClientRect();
            cardOff = Math.abs(box.top + box.height / 2 - pointerY);
          }
          frames.push({ top, height, blank, undrawn, faded, cardOff });
        },
        () => {
          // What this frame paints: its callbacks run after its input and scroll events.
          drawn = new Map(
            [...list.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => [Number(tick.dataset.tick), tick]),
          );
          gaps = [];
          let row = 0;
          for (const item of list.children as HTMLCollectionOf<HTMLElement>) {
            if (!item.classList.contains("acpmux-minimap__gap")) {
              row += 1;
              continue;
            }
            const rows = Math.round(Number.parseFloat(item.style.height) / 10);
            gaps.push([row, row + rows, getComputedStyle(item).backgroundImage.includes("gradient")]);
            row += rows;
          }
        },
      );
      (window as unknown as { __railFrames: () => Frame[] }).__railFrames = () => {
        stop();
        return frames;
      };
    }, pointerY);
  const frames = (page: Page) =>
    page.evaluate(() => (window as unknown as { __railFrames: () => Frame[] }).__railFrames());

  for (const name of ["chromium", "webkit"]) {
    test(`${name}: a fast fling shows a tick on every row in the rail's view on every frame`, async () => {
      const browser = browsers.get(name);
      if (!browser) return;
      current = browser;
      const page = await pane!.open({ width: 1280, height: 900 });
      try {
        await installPaintedFrames(page);
        const list = page.locator(".acpmux-minimap__list[data-rail-scrolls]");
        await list.waitFor({ timeout: 20_000 });
        // The ticks' own entrance is over before the fling (it is not what this measures).
        await page.evaluate(() =>
          Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
        );
        const box = (await list.boundingBox())!;
        const pointerY = box.y + box.height / 2;
        await page.mouse.move(box.x + box.width / 2, pointerY);
        // The pointer rests on the rail, so its card opens and stays on the row under it.
        await page.locator(".acpmux-minimap__card").waitFor({ timeout: 10_000 });
        await record(page, pointerY);
        // A flick of a mouse wheel with acceleration: long steps, then a momentum tail that decays,
        // down to the end and back up to the start.
        for (const sign of [-1, 1, -1]) {
          for (let step = 0; step < 24; step++) await page.mouse.wheel(0, sign * 900);
          for (let delta = 900; delta > 4; delta *= 0.82) await page.mouse.wheel(0, sign * delta);
        }
        for (let step = 0; step < 40; step++) await page.mouse.wheel(0, 1200);
        for (let step = 0; step < 40; step++) await page.mouse.wheel(0, -1200);
        await page.evaluate(() => window.cmuxPaintFrame());
        await page.evaluate(() => window.cmuxPaintFrame());
        const seen = await frames(page);
        const moved = seen.filter((frame, index) => index > 0 && frame.top !== seen[index - 1]!.top);
        // The fling moved the list far, both ways (WebKit's headless wheel travels less than
        // Chromium's, so neither engine has to reach the list's ends).
        expect(moved.length).toBeGreaterThan(10);
        expect(
          Math.max(...seen.map((frame) => frame.top)) - Math.min(...seen.map((frame) => frame.top)),
        ).toBeGreaterThan(10_000);
        const undrawn = seen.filter((frame) => frame.undrawn > 0);
        console.log(
          `${name}: ${seen.length} frames, ${moved.length} moved; ${undrawn.length} showed rows past the drawn ticks (most ${Math.max(0, ...seen.map((frame) => frame.undrawn))})`,
        );
        // No frame shows a blank strip: a row past the drawn ticks shows its resting tick.
        const blank = seen.filter((frame) => frame.blank.length > 0);
        expect(
          blank.slice(0, 3).map((frame) => ({
            top: frame.top,
            height: frame.height,
            blank: frame.blank.length,
            first: frame.blank[0],
          })),
        ).toEqual([]);
        // The open card stays on the row under the still pointer on every frame: it never shows its
        // old row at the list's new offset (its middle within a row and a half of the pointer).
        const carded = seen.filter((frame) => frame.cardOff !== undefined);
        expect(carded.length).toBeGreaterThan(seen.length / 2);
        const strayed = carded.filter((frame) => frame.cardOff! > 15);
        expect(strayed.slice(0, 3).map((frame) => ({ top: frame.top, cardOff: frame.cardOff }))).toEqual([]);
        // No row the fling brings into view replays the entrance (#26635): it would start at opacity 0.
        const faded = seen.filter((frame) => frame.faded.length > 0);
        expect(faded.slice(0, 3).map((frame) => ({ top: frame.top, faded: frame.faded.slice(0, 5) }))).toEqual([]);
      } finally {
        await page.close();
      }
    });

    // The frame a compositor scroll shows before the list's scroll event reaches the page: the list at
    // its new offset, its drawn rows still the old offset's. A window capture listener holds the
    // scroll event back from the page (React listens at its root), so that frame stays on screen to
    // read and photograph. The rows past the drawn ones must look like the resting ticks they stand
    // for: a band of resting rows in mid-rail, photographed at rest and in that frame, matches pixel
    // for pixel (within antialiasing). CMUX_RAIL_STILLS=1 prints the frame's 2x crop, light and dark,
    // as base64 PNGs.
    test(`${name}: the list moved past its drawn rows still shows its resting ticks`, async () => {
      const browser = browsers.get(name);
      if (!browser) return;
      current = browser;
      const results: Array<{ scheme: string; undrawn: number; rows: number; differing: number; pixels: number }> = [];
      for (const scheme of ["dark", "light"] as const) {
        const opened = await pane!.open({ width: 1280, height: 900, scale: 2, colorScheme: scheme });
        try {
          await opened.emulateMedia({ colorScheme: scheme });
          // The pane takes its look from the app (pageHost.ts applyTheme), as the app sends it.
          await opened.evaluate(
            (dark) =>
              (
                window as unknown as { cmuxAcpmuxBridge: { applyTheme(theme: unknown): void } }
              ).cmuxAcpmuxBridge.applyTheme({ isDark: dark }),
            scheme === "dark",
          );
          const list = opened.locator(".acpmux-minimap__list[data-rail-scrolls]");
          await list.waitFor({ timeout: 20_000 });
          await opened.evaluate(() =>
            Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
          );
          const box = (await list.boundingBox())!;
          // Twenty resting rows from a third of the way down (the lit band is at the list's foot).
          const band = { x: box.x, y: box.y + Math.round(box.height / 3), width: box.width, height: 200 };
          const atRest = await opened.screenshot({ clip: band, scale: "device" });
          const shown = await list.evaluate(async (node) => {
            const hold = (event: Event) => event.stopImmediatePropagation();
            window.addEventListener("scroll", hold, { capture: true });
            // A view and a half, in whole rows (so the rows land where rows were), past the drawn
            // rows, as one fast wheel step moves it.
            node.scrollTop -= Math.round((node.clientHeight * 1.5) / 10) * 10;
            await window.cmuxPaintFrame();
            await window.cmuxPaintFrame();
            const top = node.scrollTop;
            const first = Math.ceil(top / 10 - 0.5);
            const last = Math.floor((top + node.clientHeight) / 10 + 0.5);
            const drawn = new Set(
              [...node.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => Number(tick.dataset.tick)),
            );
            let undrawn = 0;
            for (let row = first; row < last; row++) if (!drawn.has(row)) undrawn += 1;
            return { undrawn, rows: last - first };
          });
          const moved = await opened.screenshot({ clip: band, scale: "device" });
          const was = PNG.sync.read(atRest);
          const now = PNG.sync.read(moved);
          let differing = 0;
          for (let index = 0; index < was.data.length; index += 4) {
            const step = Math.max(
              Math.abs(was.data[index]! - now.data[index]!),
              Math.abs(was.data[index + 1]! - now.data[index + 1]!),
              Math.abs(was.data[index + 2]! - now.data[index + 2]!),
            );
            // Any visible step: the light theme's resting ticks are a few levels off the page, and
            // the same rows drawn the same way match exactly.
            if (step > 2) differing += 1;
          }
          results.push({ scheme, ...shown, differing, pixels: was.data.length / 4 });
          if (process.env.CMUX_RAIL_STILLS) {
            const still = await opened.screenshot({
              clip: { x: Math.max(0, box.x - 8), y: box.y, width: box.width + 120, height: box.height },
              scale: "device",
            });
            console.log(`RAIL_STILL ${name} ${scheme} ${still.toString("base64")}`);
          }
        } finally {
          await opened.close();
        }
        if (!process.env.CMUX_RAIL_STILLS) break;
      }
      console.log(`${name} stale frame: ${JSON.stringify(results)}`);
      for (const result of results) {
        // The frame does show rows past the drawn ones (the case this covers)...
        expect(result.undrawn).toBeGreaterThan(result.rows / 2);
        // ...and they look like the resting ticks they stand for, not a blank strip or longer lines.
        expect(result.differing / result.pixels).toBeLessThan(0.005);
      }
    });
  }
});
