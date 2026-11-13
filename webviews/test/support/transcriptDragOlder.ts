// A pane drag of a chat that can load older history asks for no page of it that the view's place
// does not need (review of #41446, 2026-11-13).
//
// The transcript asks for the next older page when the view is nearer than six viewports to the
// first loaded row, and from farther for a reader who scrolls up fast: it reads their speed from
// scroll events less than 150 ms apart with a falling offset (conversation/olderAhead.ts). A pane
// that widens makes the rows above the view shorter, so the view's offset falls with no scroll of
// the reader's: wherever the transcript places its rows again in the drag, as it does when the
// hand rests and then goes on. If that reads as a fast scroll up, the chat reads a page of history
// that nobody is near.
//
// The page is the older-history harness (test/browser/transcript-older-scroll.harness.tsx): the
// chat opens on the tail of 3000 rows and pages the rest in, 30 rows in 400 ms. Two places: the
// view at the chat's end, following the latest row, and a reader scrolled up. For each, in one
// page: the pane narrow and at rest; then the frames of a drag on the drag's clock with no width
// change (the same place with no drag); then the drag to wide with a rest in its middle.
//
// An ask is early when the view was six viewports or more from the first loaded row as it was
// made: from there only the speed rule asks. An ask from nearer is the place's own (a wider pane
// has shorter rows, so the first loaded row comes nearer), and is not counted.
//
// Each case prints what it read: the asks with their frame and distance, the scroll events of the
// drag, and how far ahead the speed rule would ask from them (the rule's own class, fed the
// page's scroll events).
//
// The drag runs on the test's clock (test/support/transcriptDragStays.ts), so the rest is as long
// on any runner. One file for each engine: CI's runner ends a file at 120 s.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Browser, BrowserType, Page } from "playwright";
import { OlderAhead } from "../../src/agent-session/acpmux/conversation/olderAhead";
import { probeEngineOrSkip } from "./requireBrowserLane";
import {
  CLOCK_STEP_MS,
  HOLD_FRAMES,
  NARROW,
  STEPS,
  WIDE,
  dragInPage,
  type DragArgs,
  type DragRun,
} from "./transcriptDragStays";
import { warmViteServer } from "./warmDevServer";

export type DragOlderPart = {
  /** The part's test file name, for the engine probe and the lines it prints. */
  file: string;
  /** Playwright's engine of that name, from the part's own file. */
  engine: BrowserType;
  engineName: "chromium" | "webkit";
  /** vite.config.ts, named in the part's own file so the runner sees a dev server file. */
  configFile: string;
};

/** The transcript asks for a page inside this many viewports of the first loaded row
 *  (VirtualTranscript.tsx OLDER_AHEAD_VIEWPORTS). */
const FLOOR_VIEWPORTS = 6;
/** The drag rests after this many of its 24 widths... */
const REST_AFTER = 12;
/** ...for 160 ms of its clock: the transcript ends the live resize 120 ms after the last width and
 *  places its rows, and the next width comes inside 150 ms of that. */
const REST_FRAMES = 10;

type Ask = { at: number; top: number; landed: boolean };
type Read = {
  asks: Ask[];
  loaded: number;
  /** The view's offset, its height, and the room held above the rows (0 in this page). */
  top: number;
  view: number;
  room: number;
  fromEnd: number;
};
type OlderWindow = {
  __older: { asks: { at: number; top: number; landed?: number }[]; loaded(): number };
  __scrolls?: [number, number][];
};

/// Runs in the page. Waits until no older page is out and none was asked for in 700 ms (the
/// transcript asks again 500 ms after an ask that brought nothing), then reads the chat.
async function settledInPage(): Promise<Read> {
  const older = (window as unknown as OlderWindow).__older;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const state = () => `${older.asks.length}:${older.asks.filter((ask) => ask.landed !== undefined).length}`;
  let last = state();
  let since = performance.now();
  for (let count = 0; ; count += 1) {
    if (count > 3000) throw new Error("older pages did not stop landing in 3000 frames");
    await frame();
    const now = state();
    const out = older.asks.some((ask) => ask.landed === undefined);
    if (now !== last || out) {
      last = now;
      since = performance.now();
      continue;
    }
    if (performance.now() - since > 700) break;
  }
  return {
    asks: older.asks.map((ask) => ({ at: ask.at, top: ask.top, landed: ask.landed !== undefined })),
    loaded: older.loaded(),
    top: scroller.scrollTop,
    view: scroller.clientHeight,
    room: Number(document.querySelector<HTMLElement>(".acpmux-spacer")?.dataset.olderRoom ?? 0),
    fromEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
  };
}

/// Runs in the page. Keeps each scroll event of the transcript from now: the page's clock (the
/// drag's own while a drag runs) and the offset.
function logScrollsInPage(): void {
  const page = window as unknown as OlderWindow;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  if (!page.__scrolls) {
    scroller.addEventListener("scroll", () => page.__scrolls!.push([performance.now(), scroller.scrollTop]), {
      passive: true,
    });
  }
  page.__scrolls = [];
}

/// How far ahead of the first loaded row the speed rule asks at most, by the rule's own class fed
/// `scrolls`, with a page's read at its first guess (px), and the drag's frame of that event.
function farthestLead(scrolls: [number, number][], view: number, began: number) {
  const rule = new OlderAhead();
  let lead = 0;
  let frame = -1;
  let falls = 0;
  let before: [number, number] | undefined;
  for (const [now, top] of scrolls) {
    if (before && now - before[0] <= 150 && top < before[1]) falls += 1;
    before = [now, top];
    rule.scrolled(top, now);
    const ahead = rule.ahead(0, view, now);
    if (ahead > lead) {
      lead = ahead;
      frame = Math.round((now - began) / CLOCK_STEP_MS);
    }
  }
  return { lead: Math.round(lead), frame, falls };
}

/// Call inside the part's `requireBrowserLane` callback: registers the hooks and tests.
export async function dragOlder({ file, engine, engineName, configFile }: DragOlderPart): Promise<void> {
  setDefaultTimeout(120_000);
  if (!(await probeEngineOrSkip(file, engineName, engine))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const pagePath = "/test/browser/transcript-older-scroll.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, pagePath);
    browser = await engine.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const settled = (page: Page) => page.evaluate(settledInPage);
  const drag = (page: Page, from: number, to: number, options: Partial<DragArgs> = {}) =>
    page.evaluate(dragInPage, {
      from,
      to,
      steps: STEPS,
      toEnd: false,
      track: false,
      clockStep: CLOCK_STEP_MS,
      holdFrames: HOLD_FRAMES,
      restAfter: REST_AFTER,
      restFrames: REST_FRAMES,
      ...options,
    });
  /// The asks made after `before`, each with the drag's frame it came in and how far the view was
  /// from the first loaded row.
  const since = (before: Read, after: Read, run: DragRun) =>
    after.asks.slice(before.asks.length).map((ask) => ({
      frame: Math.round((ask.at - run.began) / CLOCK_STEP_MS),
      top: Math.round(ask.top),
      early: ask.top >= FLOOR_VIEWPORTS * after.view,
    }));

  for (const place of ["end", "reader"] as const) {
    const name =
      place === "end"
        ? "a chat that follows its latest row asks for no older page early while its pane gets wider"
        : "a reader scrolled up gets no older page asked for early while the pane gets wider";
    test(name, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 1000, height: 700 } });
      await page.goto(`http://127.0.0.1:${port}${pagePath}`);
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-row").length > 5);
      // Wide and at rest at the latest row, with the pages that this place needs.
      await drag(page, WIDE, WIDE, { toEnd: true, restFrames: 0 });
      await settled(page);
      if (place === "reader") {
        const box = (await page.locator(".acpmux-scroll").boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.wheel(0, -2400);
        // The wheel's input hold (userScroll.ts USER_SCROLL_INTENT_MS) lapses before the drag, so
        // the drag's own scroll writes are not read as the reader's.
        // fixed-wait: the one-second input hold is a timer in the product, with no state to wait on.
        await page.waitForTimeout(1_150);
        await settled(page);
      }
      // Narrow and at rest: the rows above the view are taller, the first loaded row farther.
      await drag(page, NARROW, NARROW, { toEnd: place === "end", restFrames: 0 });
      const narrow = await settled(page);
      // The same place with no drag: the drag's frames and clock, the width as it is.
      const still = await drag(page, NARROW, NARROW);
      const afterStill = await settled(page);
      await page.evaluate(logScrollsInPage);
      const run = await drag(page, NARROW, WIDE);
      const scrolls = await page.evaluate(() => (window as unknown as OlderWindow).__scrolls ?? []);
      const wide = await settled(page);
      await page.close();

      const floor = FLOOR_VIEWPORTS * wide.view;
      const stillAsks = since(narrow, afterStill, still);
      const dragAsks = since(afterStill, wide, run);
      const early = dragAsks.filter((ask) => ask.early);
      console.log(
        `${file}: ${place} ${JSON.stringify({
          view: wide.view,
          floor,
          gapMs: run.gap,
          flowFrames: run.flowed,
          narrow: { top: Math.round(narrow.top), fromEnd: narrow.fromEnd, loaded: narrow.loaded, room: narrow.room },
          wide: { top: Math.round(wide.top), fromEnd: wide.fromEnd, loaded: wide.loaded, room: wide.room },
          asksAtOpen: narrow.asks.length,
          stillAsks,
          dragAsks,
          scrollEvents: scrolls.length,
          speedRule: farthestLead(scrolls, wide.view, run.began),
        })}`,
      );
      expect({ narrow: narrow.room, wide: wide.room }, "px of room held above the loaded rows in this page").toEqual({
        narrow: 0,
        wide: 0,
      });
      if (place === "end") {
        expect(narrow.fromEnd, "px the view is from the chat's end before the drag").toBeLessThanOrEqual(2);
      } else {
        expect(narrow.fromEnd, "px the reader is up from the chat's end before the drag").toBeGreaterThan(1000);
      }
      expect(narrow.top, "px from the first loaded row to the view before the drag").toBeGreaterThanOrEqual(floor);
      expect(stillAsks, "older pages asked for in the drag's frames with no width change").toEqual([]);
      expect(early, "older pages asked for in the drag from six viewports or more away").toEqual([]);
    });
  }
}
