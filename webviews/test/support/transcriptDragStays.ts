// What a person sees of a chat while the divider beside it is dragged (a live resize: one new width
// each frame), and once the width holds. Three shapes that a film of a long chat that follows its
// latest row does not show (review of #41446, 2026-11-12), and that chat itself:
//
// "fits": a chat with a few rows, all in view. Its first row stays where it is, in each frame of
// the drag and after it, narrower and wider: the rows rewrap under it. It must not hang from its
// last row (the first row then leaves the view at its top with nothing to scroll to, or the chat
// moves down and leaves an empty band above it) and come back when the width holds.
//
// "crossing": a chat that fits at one end of the drag and not at the other. While it fits its first
// row is at the top; once it overflows the view is at its end. No frame shows the top cut off with
// room free under the latest row, or an empty band above the first row, and nothing jumps when the
// width holds.
//
// "reader": a reader scrolled up in a long chat. The row at the top of their view stays there while
// the pane narrows, and when the width holds.
//
// "follows": a chat many views long that follows its latest row, so its first rows are not mounted.
// The latest row stays at the view's lower edge in each frame, narrower and wider, with rows up to
// the view's top, and when the width holds.
//
// Each case prints what it read (px), so a run gives the size of a move, not only pass or fail.
//
// Real Chromium and WebKit from Playwright: WebKit is the engine the app shows its chat in (a
// WKWebView), Chromium the one the resize bench measures. CI fails the file when its engine cannot
// launch (each part waits on requireBrowserLane and passes the engine, so the runner puts it in its
// browser pool). One file for each engine and shape (transcript-drag-stays-{fits,crossing,reader,
// follows}-browser.test.ts in Chromium, transcript-drag-stays-webkit-* in WebKit): each has its own
// Vite server, and CI's runner ends a file at 120 s.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Browser, BrowserType, Page } from "playwright";
import { probeEngineOrSkip } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

export type DragStaysPart = {
  /** The part's test file name, for the engine probe and the lines it prints. */
  file: string;
  shape: "fits" | "crossing" | "reader" | "follows";
  /** Playwright's engine of that name, from the part's own file. */
  engine: BrowserType;
  engineName: "chromium" | "webkit";
  /** vite.config.ts, named in the part's own file so the runner sees a dev server file. */
  configFile: string;
};

/** A row that only rewraps may move this far: sub-pixel rounding. */
const STILL_PX = 2;
/** The most a frame may be off where the chat follows its end or holds a reader's row, and the most
 *  anything may move when the width holds: one line of text. */
const JUMP_PX = 24;
const WIDE = 800;
const NARROW = 380;
/** Width steps in a drag, one each frame. */
const STEPS = 24;

type DragArgs = { from: number; to: number; steps: number; toEnd: boolean; track: boolean };
/** One read of the transcript, in px: `top` from the view's top edge down to the highest row's top,
 *  `foot` from the lowest row's bottom down to the view's bottom edge, `at` the tracked row's top. */
type Shot = { top: number; foot: number; at: number | null };
type DragRun = {
  view: number;
  before: Shot;
  frames: Shot[];
  after: Shot;
  fitsBefore: boolean;
  fitsAfter: boolean;
  fromEndBefore: number;
  extentBefore: number;
  extentAfter: number;
  tracked: string | null;
  /** The place in the chat (1 = its first row) of the highest row mounted before the drag. */
  firstRow: number;
  /** The longest time between two width steps, ms. The transcript reads steps as one live resize
   *  while they come inside 120 ms of each other; a slower run did not drive a drag. */
  gap: number;
  /** The frames read while the rows sat in flow (0 on a transcript that places each frame's rows).
   *  Printed, never checked: what a person sees is the same claim on both. */
  flowed: number;
};

/// Runs in the page. Sets the pane `from` wide and waits for rest, then gives it one new width each
/// frame to `to`, reading the rows once each frame rendered, and reads them again at rest.
async function dragInPage({ from, to, steps, toEnd, track }: DragArgs): Promise<DragRun> {
  const root = document.getElementById("root")!;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const round = (value: number) => Math.round(value * 10) / 10;
  const mounted = () => [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")];
  let tracked: string | null = null;
  const shot = (): Shot => {
    const view = scroller.getBoundingClientRect();
    const rows = mounted();
    if (rows.length === 0) throw new Error("the transcript shows no row");
    const boxes = rows.map((row) => row.getBoundingClientRect());
    const row = tracked === null ? undefined : rows.find((candidate) => candidate.dataset.rowId === tracked);
    return {
      top: round(Math.min(...boxes.map((box) => box.top)) - view.top),
      foot: round(view.bottom - Math.max(...boxes.map((box) => box.bottom))),
      at: row ? round(row.getBoundingClientRect().top - view.top) : null,
    };
  };
  const extent = () => round(document.querySelector<HTMLElement>(".acpmux-spacer")!.getBoundingClientRect().height);
  // At rest: nothing a person sees moved for 20 frames, longer than the transcript waits after a
  // drag's last width before it places the rows for good.
  const rest = async () => {
    let same = 0;
    let last = "";
    for (let count = 0; count < 900 && same < 20; count += 1) {
      await frame();
      // No row yet (the seed has not rendered) is not rest.
      const now =
        mounted().length > 0
          ? JSON.stringify([shot(), scroller.scrollTop, scroller.scrollHeight, scroller.clientWidth])
          : "";
      same = now !== "" && now === last ? same + 1 : 0;
      last = now;
    }
    if (same < 20) throw new Error("the transcript did not come to rest in 900 frames");
  };
  root.style.width = `${from}px`;
  await rest();
  if (toEnd) {
    scroller.scrollTop = scroller.scrollHeight;
    await rest();
  }
  if (track) {
    const view = scroller.getBoundingClientRect();
    const first = mounted()
      .filter((row) => row.getBoundingClientRect().top >= view.top + 1)
      .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
    if (!first?.dataset.rowId) throw new Error("no row starts inside the view");
    tracked = first.dataset.rowId;
  }
  const before = shot();
  const firstRow = Math.min(...mounted().map((row) => Number(row.getAttribute("aria-posinset"))));
  const fitsBefore = scroller.scrollHeight <= scroller.clientHeight;
  const fromEndBefore = round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
  const extentBefore = extent();
  const widths = Array.from({ length: steps }, (_, index) => Math.round(from + ((to - from) * (index + 1)) / steps));
  const frames: Shot[] = [];
  let failed: unknown;
  let gap = 0;
  let stepped = 0;
  let flowed = 0;
  await new Promise<void>((done) => {
    let index = 0;
    const tick = () => {
      if (index >= widths.length) {
        done();
        return;
      }
      root.style.width = `${widths[index]}px`;
      const now = performance.now();
      if (index > 0) gap = Math.max(gap, now - stepped);
      stepped = now;
      index += 1;
      // A task posted from the frame's callback runs once that frame's rendering step finished.
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        try {
          frames.push(shot());
          if (document.querySelector(".acpmux-thread--flow")) flowed += 1;
        } catch (error) {
          failed = error;
        }
      };
      channel.port2.postMessage(0);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await rest();
  if (failed !== undefined) throw failed;
  if (frames.length !== steps) throw new Error(`${frames.length} of ${steps} frames were read`);
  return {
    view: scroller.clientHeight,
    before,
    frames,
    after: shot(),
    fitsBefore,
    fitsAfter: scroller.scrollHeight <= scroller.clientHeight,
    fromEndBefore,
    extentBefore,
    extentAfter: extent(),
    tracked,
    firstRow,
    gap: round(gap),
    flowed,
  };
}

const most = (values: number[]) => Math.round(Math.max(0, ...values) * 10) / 10;
const last = (run: DragRun) => run.frames[run.frames.length - 1]!;
/// How far the highest row was from `rest` (its place where the chat fits), up and down.
const up = (run: DragRun, rest: number) => most(run.frames.map((shot) => rest - shot.top));
const down = (run: DragRun, rest: number) => most(run.frames.map((shot) => shot.top - rest));
/// The most of the chat's top that a frame hid above the view while as much room stood free under
/// the latest row (`foot`: the room under it where the view is at the chat's end).
const cut = (run: DragRun, rest: number, foot: number) =>
  most(run.frames.map((shot) => Math.min(rest - shot.top, shot.foot - foot)));
/// The height of the mounted rows in one read, first row's top to last row's bottom. (The scroll
/// content's own height says nothing for a chat that fits: it is never less than the view's.)
const tall = (run: DragRun, shot: Shot) => Math.round((run.view - shot.top - shot.foot) * 10) / 10;
const settle = (run: DragRun) => ({
  top: Math.round((run.after.top - last(run).top) * 10) / 10,
  foot: Math.round((run.after.foot - last(run).foot) * 10) / 10,
});

/// Call inside the part's `requireBrowserLane` callback: registers the shape's hooks and tests.
export async function dragStays({ file, shape, engine, engineName, configFile }: DragStaysPart): Promise<void> {
  setDefaultTimeout(120_000);
  if (!(await probeEngineOrSkip(file, engineName, engine))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const pagePath = "/test/browser/transcript-fling.html";
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

  /// The transcript harness in a pane `width` wide and a window `height` high, with `rows` seeded.
  const open = async (height: number, rows: number, width: number): Promise<Page> => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1000, height } });
    await page.goto(`http://127.0.0.1:${port}${pagePath}`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate((px) => {
      document.getElementById("root")!.style.width = `${px}px`;
    }, width);
    await page.evaluate(`window.__debug.seedRows(${rows})`);
    return page;
  };
  const drag = (page: Page, from: number, to: number, options: { toEnd?: boolean; track?: boolean } = {}) =>
    page.evaluate(dragInPage, {
      from,
      to,
      steps: STEPS,
      toEnd: options.toEnd ?? false,
      track: options.track ?? false,
    });
  const report = (name: string, run: DragRun, more: Record<string, unknown>) =>
    console.log(
      `${file}: ${name} ${JSON.stringify({
        view: run.view,
        gapMs: run.gap,
        flowFrames: run.flowed,
        extent: [run.extentBefore, run.extentAfter],
        rows: [tall(run, run.before), tall(run, run.after)],
        before: run.before,
        lastFrame: last(run),
        after: run.after,
        settle: settle(run),
        ...more,
      })}`,
    );

  if (shape === "fits") {
    // Five turns in a window far taller than them at either width.
    for (const [name, from, to] of [
      ["narrower", WIDE, NARROW],
      ["wider", NARROW, WIDE],
    ] as const) {
      test(`a chat that fits keeps its first row in place while its pane gets ${name}`, async () => {
        const page = await open(2400, 15, from);
        const run = await drag(page, from, to);
        await page.close();
        const moved = { up: up(run, run.before.top), down: down(run, run.before.top) };
        report(name, run, { moved });
        expect({ before: run.fitsBefore, after: run.fitsAfter }, "the chat fits before and after the drag").toEqual({
          before: true,
          after: true,
        });
        expect(
          Math.abs(tall(run, run.after) - tall(run, run.before)),
          "the drag rewraps the rows: the chat's height changes",
        ).toBeGreaterThan(20);
        expect(run.before.top, "the first row starts inside the view").toBeGreaterThanOrEqual(0);
        expect(moved.up, "px the first row went up in a frame of the drag").toBeLessThanOrEqual(STILL_PX);
        expect(moved.down, "px the first row went down in a frame of the drag").toBeLessThanOrEqual(STILL_PX);
        expect(
          Math.abs(run.after.top - run.before.top),
          "px the first row is from its place once the width holds",
        ).toBeLessThanOrEqual(STILL_PX);
      });
    }
  }

  if (shape === "crossing") {
    // Ten turns, and a view as high as halfway between their height wide and their height narrow.
    const ROWS = 30;
    let height = 0;
    /// Where the first row rests in a view that holds the whole chat (read by `sized`).
    let fitTop = 0;
    const sized = async () => {
      if (height > 0) return height;
      const page = await open(6000, ROWS, WIDE);
      const read = (width: number) =>
        drag(page, width, width).then((run) => ({
          rows: tall(run, run.after),
          top: run.after.top,
          fits: run.fitsAfter,
          view: run.view,
        }));
      const wide = await read(WIDE);
      const narrow = await read(NARROW);
      await page.close();
      expect({ wide: wide.fits, narrow: narrow.fits }, "the 6000 px window holds the chat whole").toEqual({
        wide: true,
        narrow: true,
      });
      expect(narrow.rows - wide.rows, "the chat is taller narrow than wide").toBeGreaterThan(150);
      // The space above the first row, the rows at halfway between the two widths, and what the page
      // shows around the transcript (the window's height less the view's).
      height = Math.round(wide.top + (wide.rows + narrow.rows) / 2) + (6000 - wide.view);
      fitTop = wide.top;
      console.log(`${file}: sized ${JSON.stringify({ wide, narrow, window: height })}`);
      return height;
    };

    test("a chat that stops fitting as its pane narrows goes to its end, with no cut and no jump", async () => {
      const page = await open(await sized(), ROWS, WIDE);
      const run = await drag(page, WIDE, NARROW);
      await page.close();
      const rest = run.before.top;
      const seen = { cut: cut(run, rest, run.after.foot), blank: down(run, rest) };
      report("fits, then overflows", run, seen);
      expect({ before: run.fitsBefore, after: run.fitsAfter }, "fits before the drag, not after it").toEqual({
        before: true,
        after: false,
      });
      expect(seen.cut, "px of the chat's top hidden in a frame with that much room under it").toBeLessThanOrEqual(
        JUMP_PX,
      );
      expect(seen.blank, "px of empty band above the first row in a frame").toBeLessThanOrEqual(JUMP_PX);
      expect(Math.abs(settle(run).foot), "px the latest row jumps when the width holds").toBeLessThanOrEqual(JUMP_PX);
      // A view left at the chat's top for good has no jump either: the latest row must be in it.
      expect(
        run.after.foot,
        "px from the latest row's bottom to the view's once the width holds",
      ).toBeGreaterThanOrEqual(0);
    });

    test("a chat that starts fitting as its pane widens goes to its top, with no band and no jump", async () => {
      const page = await open(await sized(), ROWS, NARROW);
      const run = await drag(page, NARROW, WIDE, { toEnd: true });
      await page.close();
      const rest = run.after.top;
      const seen = { cut: cut(run, rest, run.before.foot), blank: down(run, rest) };
      report("overflows, then fits", run, seen);
      expect({ before: run.fitsBefore, after: run.fitsAfter }, "does not fit before the drag, fits after it").toEqual({
        before: false,
        after: true,
      });
      expect(run.fromEndBefore, "the view is at the chat's end before the drag").toBeLessThanOrEqual(STILL_PX);
      expect(seen.cut, "px of the chat's top hidden in a frame with that much room under it").toBeLessThanOrEqual(
        JUMP_PX,
      );
      expect(seen.blank, "px of empty band above the first row in a frame").toBeLessThanOrEqual(JUMP_PX);
      expect(Math.abs(settle(run).top), "px the first row jumps when the width holds").toBeLessThanOrEqual(JUMP_PX);
      // A band that stays for good has no jump either: the first row must rest where a chat that fits has it.
      expect(
        Math.abs(run.after.top - fitTop),
        "px the first row is from its place in a chat that fits once the width holds",
      ).toBeLessThanOrEqual(STILL_PX);
    });
  }

  if (shape === "follows") {
    // 200 turns in a window 700 px high: many views of chat are above the view, so the chat's first
    // rows are not mounted.
    for (const [name, from, to] of [
      ["narrower", WIDE, NARROW],
      ["wider", NARROW, WIDE],
    ] as const) {
      test(`a long chat that follows its latest row keeps it at the view's end while its pane gets ${name}`, async () => {
        const page = await open(700, 600, from);
        const run = await drag(page, from, to, { toEnd: true });
        await page.close();
        const rest = run.before.foot;
        const seen = {
          firstRow: run.firstRow,
          under: most(run.frames.map((shot) => -shot.foot)),
          lifted: most(run.frames.map((shot) => shot.foot - rest)),
          band: most(run.frames.map((shot) => shot.top)),
        };
        report(name, run, seen);
        expect(run.fromEndBefore, "the view is at the chat's end before the drag").toBeLessThanOrEqual(STILL_PX);
        expect(
          run.firstRow,
          "the place of the highest mounted row: the chat's first row is not mounted",
        ).toBeGreaterThan(1);
        expect(seen.under, "px of the latest row under the view's lower edge in a frame").toBeLessThanOrEqual(0);
        expect(seen.lifted, "px the latest row went up from the view's end in a frame").toBeLessThanOrEqual(JUMP_PX);
        expect(seen.band, "px of empty band above the highest mounted row in a frame").toBeLessThanOrEqual(0);
        expect(Math.abs(settle(run).foot), "px the latest row jumps when the width holds").toBeLessThanOrEqual(JUMP_PX);
        expect(
          run.after.foot,
          "px from the latest row's bottom to the view's once the width holds",
        ).toBeGreaterThanOrEqual(0);
      });
    }
  }

  if (shape === "reader") {
    test("a reader scrolled up keeps the row at the top of their view while the pane narrows", async () => {
      // 50 turns, more than the view holds.
      const page = await open(700, 150, WIDE);
      // At rest at the latest row first, then a real wheel up: the reader's own scroll.
      await drag(page, WIDE, WIDE, { toEnd: true });
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, -2400);
      // The wheel's input hold (userScroll.ts USER_SCROLL_INTENT_MS) lapses before the drag, so the
      // drag's own scroll writes are not read as the reader's.
      // fixed-wait: the one-second input hold is a timer in the product, with no state to wait on.
      await page.waitForTimeout(1_150);
      const to = Math.round(WIDE * 0.8);
      const run = await drag(page, WIDE, to, { track: true });
      await page.close();
      const rest = run.before.at!;
      const tops = run.frames.map((shot) => shot.at);
      const moved = most(tops.map((at) => (at === null ? Infinity : Math.abs(at - rest))));
      const jump = run.after.at === null ? Infinity : Math.abs(run.after.at - (last(run).at ?? Infinity));
      report("scrolled up", run, {
        row: run.tracked,
        fromEnd: run.fromEndBefore,
        moved,
        jump: Math.round(jump * 10) / 10,
        tops,
      });
      expect(run.fromEndBefore, "px the reader is up from the chat's end").toBeGreaterThan(1000);
      expect(moved, "px the reader's top row moved in a frame of the drag").toBeLessThanOrEqual(JUMP_PX);
      expect(jump, "px the reader's top row jumps when the width holds").toBeLessThanOrEqual(JUMP_PX);
      expect(
        Math.abs((run.after.at ?? Infinity) - rest),
        "px the reader's top row is from its place once the width holds",
      ).toBeLessThanOrEqual(JUMP_PX);
    });
  }
}
