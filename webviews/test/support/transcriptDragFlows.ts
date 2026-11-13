// Who lays out a chat's rows in each frame of a live resize (the divider beside the chat dragged: one
// new width each frame), counted by the frame.
//
// A row is a box that the browser wraps at its width, so a row's width and wrap follow the pane in
// each frame whoever places the rows. What differs is the work of a frame. A transcript that places
// each frame's rows itself renders every mounted row again at each width step and writes each moved
// row's place on its style. A transcript whose rows flow for the length of the drag renders no row
// and writes no row's place: the browser rewraps the rows and moves them in its own layout pass, as
// it does a web page.
//
// So each case reads two things in every frame of a drag:
// - what a person sees: each row's width, its height (its wrap) and the room under it are the ones
//   the same row has at rest in a pane that wide (read first, one width at a time, each at rest);
// - what the frame cost: the renders of a row (the pane's own render counts, perf.ts `row:<id>`) and
//   the writes of a row's style attribute (a MutationObserver on the thread).
// The first is true of both kinds of transcript, and it keeps the second honest: rows that neither
// render nor move would count 0 too, and would not rewrap. The counts are 0 only where the rows flow.
//
// The first frames of a drag are not judged: one or two width changes close together can be a
// scrollbar or a column settling, and the transcript reads a drag from its third step.
//
// Every assert is a count or a length in px read in a frame. No assert is on a time. The steps' own
// longest gap decides only whether the run drove a drag at all (the transcript reads width steps as
// one live resize while they come close together): a run that did not is driven again.
//
// Each case prints what it read, so a run gives the counts, not only pass or fail.
//
// Real Chromium and WebKit from Playwright: WebKit is the engine the app shows its chat in (a
// WKWebView), Chromium the one the resize bench measures. CI fails the file when its engine cannot
// launch (each part waits on requireBrowserLane and passes the engine, so the runner puts it in its
// browser pool). One file for each engine: each has its own Vite server.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Browser, BrowserType, Page } from "playwright";
import { probeEngineOrSkip } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

export type DragFlowsPart = {
  /** The part's test file name, for the engine probe and the lines it prints. */
  file: string;
  /** Playwright's engine of that name, from the part's own file. */
  engine: BrowserType;
  engineName: "chromium" | "webkit";
  /** vite.config.ts, named in the part's own file so the runner sees a dev server file. */
  configFile: string;
};

const WIDE = 800;
const NARROW = 380;
/** Width steps in a drag, one each frame. */
const STEPS = 24;
/** The drag's first frames, not judged (see the file's head). */
const SETTLING = 3;
/** A row's width in a frame may be this far from its width at rest: sub-pixel rounding. */
const WIDTH_PX = 1;
/** A row's height and the room under it may be this far from theirs at rest: sub-pixel rounding. */
const STILL_PX = 2;
/** Steps this far apart (ms) or more did not drive a drag: the run is driven again, not judged. */
const DRAG_GAP_MS = 100;
/** How many times a case drives its drag before it says that no drag was driven. */
const TRIES = 3;
/** The pane's own module, at the path the page loaded it from (the dev server's root is webviews/). */
const PERF_URL = "/src/agent-session/acpmux/perf.ts";

/** One mounted row as a frame shows it, px: `gap` is the room down to the next row (null: the last). */
type RowRead = { id: string; width: number; height: number; gap: number | null };
type FrameRead = {
  /** The pane's width in this frame. */
  width: number;
  rows: RowRead[];
  /** Renders of a row since the frame before. */
  renders: number;
  /** Writes of a row's style attribute since the frame before. */
  writes: number;
  /** Rows added to or taken from the thread since the frame before. */
  mounts: number;
  /** The rows sat in normal flow when the frame was read. Printed, never checked. */
  flowed: boolean;
};
type DragRun = {
  frames: FrameRead[];
  /** The longest time between two width steps, ms. */
  gap: number;
  /** Frames that began before the frame before them was read. */
  late: number;
};
type DragArgs = { from: number; to: number; steps: number; perfUrl: string };

/// Runs in the page. Reads each mounted row at rest at each of `widths`, one width at a time.
async function restInPage(widths: number[]): Promise<Record<number, RowRead[]>> {
  const root = document.getElementById("root")!;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const round = (value: number) => Math.round(value * 10) / 10;
  const mounted = () =>
    [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")].sort(
      (a, b) => Number(a.getAttribute("aria-posinset")) - Number(b.getAttribute("aria-posinset")),
    );
  const read = (): RowRead[] => {
    const rows = mounted();
    const boxes = rows.map((row) => row.getBoundingClientRect());
    return rows.map((row, at) => ({
      id: row.dataset.rowId ?? "",
      width: round(boxes[at]!.width),
      height: round(boxes[at]!.height),
      gap: at + 1 < rows.length ? round(boxes[at + 1]!.top - boxes[at]!.bottom) : null,
    }));
  };
  // At rest: nothing a person sees moved for 20 frames, longer than the transcript waits after a
  // width before it places the rows for good, and longer than two widths may be apart in a drag.
  const rest = async () => {
    let same = 0;
    let last = "";
    for (let count = 0; count < 900 && same < 20; count += 1) {
      await frame();
      const now = mounted().length > 0 ? JSON.stringify([read(), scroller.scrollTop, scroller.scrollHeight]) : "";
      same = now !== "" && now === last ? same + 1 : 0;
      last = now;
    }
    if (same < 20) throw new Error("the transcript did not come to rest in 900 frames");
  };
  const reads: Record<number, RowRead[]> = {};
  for (const width of widths) {
    root.style.width = `${width}px`;
    await rest();
    reads[width] = read();
  }
  return reads;
}

/// Runs in the page. Sets the pane `from` wide and waits for rest, then gives it one new width each
/// frame to `to`, and reads the rows and the frame's counts once each frame rendered.
async function dragInPage({ from, to, steps, perfUrl }: DragArgs): Promise<DragRun> {
  type PerfModule = typeof import("../../src/agent-session/acpmux/perf");
  const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
  const root = document.getElementById("root")!;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const round = (value: number) => Math.round(value * 10) / 10;
  const mounted = () =>
    [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")].sort(
      (a, b) => Number(a.getAttribute("aria-posinset")) - Number(b.getAttribute("aria-posinset")),
    );
  const read = (): RowRead[] => {
    const rows = mounted();
    const boxes = rows.map((row) => row.getBoundingClientRect());
    return rows.map((row, at) => ({
      id: row.dataset.rowId ?? "",
      width: round(boxes[at]!.width),
      height: round(boxes[at]!.height),
      gap: at + 1 < rows.length ? round(boxes[at + 1]!.top - boxes[at]!.bottom) : null,
    }));
  };
  const rest = async () => {
    let same = 0;
    let last = "";
    for (let count = 0; count < 900 && same < 20; count += 1) {
      await frame();
      const now = mounted().length > 0 ? JSON.stringify([read(), scroller.scrollTop, scroller.scrollHeight]) : "";
      same = now !== "" && now === last ? same + 1 : 0;
      last = now;
    }
    if (same < 20) throw new Error("the transcript did not come to rest in 900 frames");
  };
  root.style.width = `${from}px`;
  await rest();
  const thread = scroller.querySelector<HTMLElement>(".acpmux-thread");
  if (!thread) throw new Error("the transcript has no thread");
  acpmuxPerf.enable();
  const rowRenders = () => {
    let sum = 0;
    for (const [name, count] of acpmuxPerf.renders) if (name.startsWith("row:")) sum += count;
    return sum;
  };
  let writes = 0;
  let mounts = 0;
  const take = (records: MutationRecord[]) => {
    for (const record of records) {
      if (record.type === "attributes") {
        const node = record.target as HTMLElement;
        if (node.parentElement === thread && node.classList.contains("acpmux-row")) writes += 1;
      } else if (record.target === thread) mounts += record.addedNodes.length + record.removedNodes.length;
    }
  };
  const observer = new MutationObserver(take);
  observer.observe(thread, { attributes: true, attributeFilter: ["style"], childList: true, subtree: true });
  const widths = Array.from({ length: steps }, (_, index) => Math.round(from + ((to - from) * (index + 1)) / steps));
  const frames: FrameRead[] = [];
  let failed: unknown;
  let gap = 0;
  let stepped = 0;
  let late = 0;
  let unread = false;
  let rendered = 0;
  await new Promise<void>((done) => {
    let index = 0;
    const tick = () => {
      if (unread) late += 1;
      if (index >= widths.length) {
        done();
        return;
      }
      if (index === 0) {
        // The counts start at the drag's first width.
        observer.takeRecords();
        writes = 0;
        mounts = 0;
        rendered = rowRenders();
      }
      const width = widths[index]!;
      root.style.width = `${width}px`;
      const now = performance.now();
      if (index > 0) gap = Math.max(gap, now - stepped);
      stepped = now;
      index += 1;
      unread = true;
      // A task posted from the frame's callback runs once that frame's rendering step finished.
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        try {
          take(observer.takeRecords());
          const renders = rowRenders();
          frames.push({
            width,
            rows: read(),
            renders: renders - rendered,
            writes,
            mounts,
            flowed: thread.classList.contains("acpmux-thread--flow"),
          });
          rendered = renders;
          writes = 0;
          mounts = 0;
        } catch (error) {
          failed = error;
        }
        unread = false;
      };
      channel.port2.postMessage(0);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await rest();
  observer.disconnect();
  if (failed !== undefined) throw failed;
  if (frames.length !== steps) throw new Error(`${frames.length} of ${steps} frames were read`);
  return { frames, gap: round(gap), late };
}

const most = (values: number[]) => Math.round(Math.max(0, ...values) * 10) / 10;
const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);
/// The most a frame's rows are from the rows at rest in a pane as wide as that frame's, px, by `of`.
/// A frame that does not hold the same rows as the rest read counts as infinitely far.
const off = (frames: FrameRead[], rest: Record<number, RowRead[]>, of: (row: RowRead) => number | null) =>
  most(
    frames.flatMap((frame) => {
      const still = rest[frame.width];
      if (!still || still.length !== frame.rows.length) return [Infinity];
      return frame.rows.map((row, at) => {
        const mine = of(row);
        const theirs = of(still[at]!);
        if (row.id !== still[at]!.id) return Infinity;
        return mine === null || theirs === null ? 0 : Math.abs(mine - theirs);
      });
    }),
  );

/// Call inside the part's `requireBrowserLane` callback: registers the hooks and the tests.
export async function dragFlows({ file, engine, engineName, configFile }: DragFlowsPart): Promise<void> {
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

  // Five turns in a window far taller than them at either width: every row is mounted, in each frame.
  const ROWS = 15;
  const open = async (width: number): Promise<Page> => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1000, height: 2400 } });
    await page.goto(`http://127.0.0.1:${port}${pagePath}`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate((px) => {
      document.getElementById("root")!.style.width = `${px}px`;
    }, width);
    await page.evaluate(`window.__debug.seedRows(${ROWS})`);
    return page;
  };
  /// The widths a drag between WIDE and NARROW steps through, either way, and the two ends.
  const widths = Array.from({ length: STEPS + 1 }, (_, index) => Math.round(WIDE + ((NARROW - WIDE) * index) / STEPS));
  let rest: Record<number, RowRead[]> | undefined;
  /// Each row at rest at each width, read once for the file.
  const atRest = async () => {
    if (rest) return rest;
    const page = await open(WIDE);
    rest = await page.evaluate(restInPage, widths);
    await page.close();
    return rest;
  };

  for (const [name, from, to] of [
    ["narrower", WIDE, NARROW],
    ["wider", NARROW, WIDE],
  ] as const) {
    test(`the browser rewraps a chat's rows in each frame while its pane gets ${name}: no row renders, no row's place is written`, async () => {
      const still = await atRest();
      let run: DragRun | undefined;
      const slow: number[] = [];
      for (let attempt = 0; attempt < TRIES && !run; attempt += 1) {
        const page = await open(from);
        const drove = await page.evaluate(dragInPage, { from, to, steps: STEPS, perfUrl: PERF_URL });
        await page.close();
        if (drove.gap < DRAG_GAP_MS && drove.late === 0) run = drove;
        else slow.push(drove.gap);
      }
      if (!run)
        throw new Error(
          `${file}: no drag was driven in ${TRIES} runs (the longest gaps between two width steps, ms: ${slow.join(", ")}): no verdict`,
        );
      const judged = run.frames.slice(SETTLING);
      const heights = (rows: RowRead[]) => Math.round(sum(rows.map((row) => row.height)));
      const seen = {
        rowRenders: sum(judged.map((frame) => frame.renders)),
        styleWrites: sum(judged.map((frame) => frame.writes)),
        mounts: sum(run.frames.map((frame) => frame.mounts)),
        widthOff: off(run.frames, still, (row) => row.width),
        heightOff: off(run.frames, still, (row) => row.height),
        gapOff: off(run.frames, still, (row) => row.gap),
        // The frames whose rows are not as tall as the frame's before: the frames that rewrapped a row.
        rewraps: run.frames.filter((frame, at) => at > 0 && heights(frame.rows) !== heights(run.frames[at - 1]!.rows))
          .length,
      };
      console.log(
        `${file}: ${name} ${JSON.stringify({
          ...seen,
          rows: run.frames[0]!.rows.length,
          framesJudged: judged.length,
          gapMs: run.gap,
          driven: slow.length + 1,
          flowFrames: run.frames.filter((frame) => frame.flowed).length,
          rendersByFrame: run.frames.map((frame) => frame.renders),
          writesByFrame: run.frames.map((frame) => frame.writes),
          rowWidthByFrame: run.frames.map((frame) => frame.rows[0]?.width ?? null),
          heightByFrame: run.frames.map((frame) => heights(frame.rows)),
          restHeight: [heights(still[from]!), heights(still[to]!)],
        })}`,
      );
      expect(run.frames[0]!.rows.length, "the rows mounted in the drag").toBeGreaterThan(3);
      expect(seen.mounts, "rows added to or taken from the thread in the drag").toBe(0);
      // What a person sees, in each frame: the rows as a pane that wide shows them at rest.
      expect(seen.rewraps, "frames of the drag that rewrapped a row").toBeGreaterThan(3);
      expect(
        seen.widthOff,
        "px a row's width in a frame is from its width at rest in a pane that wide",
      ).toBeLessThanOrEqual(WIDTH_PX);
      expect(
        seen.heightOff,
        "px a row's height in a frame is from its height at rest in a pane that wide",
      ).toBeLessThanOrEqual(STILL_PX);
      expect(
        seen.gapOff,
        "px the room under a row in a frame is from that room at rest in a pane that wide",
      ).toBeLessThanOrEqual(STILL_PX);
      // What the frame cost: the browser rewrapped and moved the rows, with no render of a row and
      // no write of a row's place.
      expect(seen.rowRenders, `renders of a row in the ${judged.length} frames after the drag's third`).toBe(0);
      expect(
        seen.styleWrites,
        `writes of a row's style attribute in the ${judged.length} frames after the drag's third`,
      ).toBe(0);
    });
  }
}
