// l10n-allow-file: bench output labels, not shipped UI.
// Whether the transcript readjusts while the reader wheels down it (Leo, 2026-11-09: "when i scroll down now
// there's a little readjustment sometimes that shold never happen"). The transcript harness
// (test/browser/transcript-fling.html) seeds ROWS synthetic rows; the view is put START_PX above the latest row,
// where the rows below it have not been measured yet, and rests. The reader then wheels down, 40 px a step and a
// step a painted frame (page.mouse.wheel), until well past the bottom, then lets go for SETTLE_FRAMES frames.
// Every painted frame the bench reads the scroller's offset and the viewport top of every row in view.
// What it reports, per engine, p50 the median round and p95 the worst:
//   ui.transcript.scroll.readjust_frames  frames on the way down in which the rows in view did not move as one (two
//                                         rows seen in both frames moved by amounts more than 1 px apart: a row above
//                                         another resized or was placed again), or moved back against the wheel (the
//                                         rows went down by more than 1 px while the reader wheeled down). Target 0.
//   ui.transcript.scroll.settle_moves     frames after the view first reached the bottom in which it moved at all
//                                         (offset or a row in view by more than 1 px). Nothing arrives in this
//                                         harness, and wheeling down at the bottom scrolls nowhere, so every one is
//                                         the view moving on its own. Target 0.
// Printed beside them, no row: anchor shifts, frames in which a row in view moved by a different amount than the
// scroller's offset change implies (it moved in the content by more than 1 px). A height corrected above the view
// with the offset moved by the same amount in one frame counts here and is invisible; one the offset catches up
// with a frame later is a readjust above.
// Chromium rows carry `.chromium` after `scroll`.
//   bun bench/transcript-scroll-readjust.bench.ts [rows=3000] [rounds=3] [--engines webkit,chromium] [--json FILE]
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { createServer } from "vite";
import { warmViteServer } from "../test/support/warmDevServer";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const VALUED = new Set(["--engines", "--json"]);
const numbers = argv.filter((arg, index) => /^\d+$/.test(arg) && !VALUED.has(argv[index - 1] ?? ""));
const ROWS = Number(numbers[0] ?? 3000);
const ROUNDS = Number(numbers[1] ?? 3);
const ENGINES = (flag("--engines") ?? "webkit").split(",");
const JSON_OUT = flag("--json");
if (
  !Number.isInteger(ROWS) ||
  ROWS < 3 ||
  !Number.isInteger(ROUNDS) ||
  ROUNDS < 1 ||
  ENGINES.some((name) => name !== "chromium" && name !== "webkit")
)
  throw new Error("usage: transcript-scroll-readjust.bench.ts [rows>=3] [rounds>=1] [--engines webkit,chromium]");
/// How far above the latest row the reader starts.
const START_PX = 6000;
const STEP_PX = 40;
/// Wheel steps: to the bottom and 60 more at it.
const STEPS = Math.ceil(START_PX / STEP_PX) + 60;
/// Frames read after the last wheel step.
const SETTLE_FRAMES = 90;
/// A move under this (px) is rounding.
export const MOVE_PX = 1;
const webviews = path.resolve(import.meta.dir, "..");

export type Seen = { id: string; y: number };
export type ScrollFrame = { at: number; top: number; max: number; rows: Seen[] };
export type Readjust = { frame: number; ms: number; why: "uneven" | "back" | "self"; px: number; id: string };
export type Round = {
  readjusts: Readjust[];
  settles: Readjust[];
  anchorShifts: number;
  frames: number;
  /** Whether the view reached the bottom at all: a round that did not measured no settle. */
  bottomed: boolean;
};

/// The round's numbers (pure): see the header.
export function score(frames: ScrollFrame[]): Round {
  const readjusts: Readjust[] = [];
  const settles: Readjust[] = [];
  let anchorShifts = 0;
  let bottomed = false;
  for (let index = 1; index < frames.length; index++) {
    const before = frames[index - 1]!;
    const frame = frames[index]!;
    if (before.top >= before.max - MOVE_PX) bottomed = true;
    const ms = Math.round(frame.at - frames[0]!.at);
    const scrolled = frame.top - before.top;
    const was = new Map(before.rows.map((row) => [row.id, row.y]));
    const moves = frame.rows
      .filter((row) => was.has(row.id))
      .map((row) => ({ id: row.id, dy: row.y - was.get(row.id)! }))
      .sort((a, b) => a.dy - b.dy);
    if (moves.some((move) => Math.abs(move.dy + scrolled) > MOVE_PX)) anchorShifts += 1;
    if (bottomed) {
      const moved = moves.find((move) => Math.abs(move.dy) > MOVE_PX);
      if (moved || Math.abs(scrolled) > MOVE_PX)
        settles.push({
          frame: index,
          ms,
          why: "self",
          px: Math.round(moved ? moved.dy : -scrolled),
          id: moved?.id ?? "",
        });
      continue;
    }
    if (!moves.length) continue;
    const median = moves[Math.floor((moves.length - 1) / 2)]!.dy;
    const spread = moves.at(-1)!.dy - moves[0]!.dy;
    if (spread > MOVE_PX) {
      // The row that moved farthest from the rest.
      const odd = Math.abs(moves[0]!.dy - median) > Math.abs(moves.at(-1)!.dy - median) ? moves[0]! : moves.at(-1)!;
      readjusts.push({ frame: index, ms, why: "uneven", px: Math.round(odd.dy - median), id: odd.id });
    } else if (median > MOVE_PX) readjusts.push({ frame: index, ms, why: "back", px: Math.round(median), id: "" });
  }
  return { readjusts, settles, anchorShifts, frames: frames.length, bottomed };
}

async function round(browser: Browser, url: string): Promise<Round> {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  try {
    await installPaintedFrames(page);
    await page.goto(url);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate(`window.__debug.seedRows(${ROWS})`);
    // START_PX above the latest row, and rest there: the offset and height held for 12 painted frames.
    await page.evaluate(async (startPx) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let frame = 0; frame < 30; frame += 1) await window.cmuxPaintFrame();
      scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight - startPx);
      let last = "";
      for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
        held = now === last ? held + 1 : 0;
        last = now;
      }
    }, START_PX);
    await page.locator(".acpmux-scroll").hover();
    await page.evaluate(() => {
      const w = window as unknown as { __readjustFrames: ScrollFrame[]; __readjustStop: () => void };
      w.__readjustFrames = [];
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const thread = scroller.querySelector<HTMLElement>(".acpmux-thread") ?? scroller;
      const read = () => {
        const view = scroller.getBoundingClientRect();
        const rows: Seen[] = [];
        for (const row of thread.querySelectorAll<HTMLElement>(".acpmux-row")) {
          const box = row.getBoundingClientRect();
          if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
          rows.push({ id: row.dataset.rowId ?? "", y: box.top - view.top });
        }
        w.__readjustFrames.push({
          at: performance.now(),
          top: scroller.scrollTop,
          max: scroller.scrollHeight - scroller.clientHeight,
          rows,
        });
      };
      read();
      w.__readjustStop = window.cmuxAfterPaint(() => {
        read();
      });
    });
    for (let step = 0; step < STEPS; step += 1) {
      await page.mouse.wheel(0, STEP_PX);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.evaluate(async (settle) => {
      for (let frame = 0; frame < settle; frame += 1) await window.cmuxPaintFrame();
    }, SETTLE_FRAMES);
    const frames = await page.evaluate(() => {
      const w = window as unknown as { __readjustFrames: ScrollFrame[]; __readjustStop: () => void };
      w.__readjustStop();
      return w.__readjustFrames;
    });
    return score(frames);
  } finally {
    await page.close();
  }
}

if (import.meta.main) {
  const vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  const pagePath = "/test/browser/transcript-fling.html";
  let failed = 0;
  const report: Record<string, Round[]> = {};
  try {
    await warmViteServer(vite, pagePath);
    const { port } = vite.httpServer!.address() as { port: number };
    const url = `http://127.0.0.1:${port}${pagePath}`;
    for (const engine of ENGINES) {
      const isChromium = engine === "chromium";
      let browser: Browser;
      try {
        browser = isChromium
          ? await chromium.launch({
              ...(process.env.CMUX_CHROME_HEADLESS_SHELL
                ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
                : { channel: "chrome" }),
              headless: true,
            })
          : await webkit.launch({ headless: true });
      } catch (error) {
        failed += 1;
        console.log(
          `transcript-scroll-readjust: ${engine} FAILED to launch: ${error instanceof Error ? error.message : String(error)}`,
        );
        continue;
      }
      const rounds: Round[] = [];
      try {
        for (let index = 0; index < ROUNDS; index++) rounds.push(await round(browser, url));
      } catch (error) {
        failed += 1;
        console.log(
          `transcript-scroll-readjust: ${engine} FAILED: ${error instanceof Error ? error.message : String(error)}`,
        );
      } finally {
        await browser.close();
      }
      if (!rounds.length) continue;
      report[engine] = rounds;
      const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) / 2)]!;
      const stat = (values: number[]) => ({ p50: median(values), p95: Math.max(...values) });
      console.log(
        `transcript-scroll-readjust: ${engine}, ${rounds.length} rounds, ${ROWS} rows, ${STEPS} steps of ${STEP_PX} px from ${START_PX} px up`,
      );
      console.log("round | readjust frames | settle moves | anchor shifts | frames | reached bottom");
      for (const [index, r] of rounds.entries())
        console.log(
          `${index + 1} | ${r.readjusts.length} | ${r.settles.length} | ${r.anchorShifts} | ${r.frames} | ${r.bottomed}`,
        );
      for (const each of [...rounds.at(-1)!.readjusts, ...rounds.at(-1)!.settles].slice(0, 40))
        console.log(`  ${each.why} frame ${each.frame} +${each.ms} ms ${each.px} px ${each.id}`);
      const name = `ui.transcript.scroll${isChromium ? ".chromium" : ""}`;
      perfRow({
        name: `${name}.readjust_frames`,
        ...stat(rounds.map((r) => r.readjusts.length)),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
      perfRow({
        name: `${name}.settle_moves`,
        ...stat(rounds.map((r) => (r.bottomed ? r.settles.length : 9999))),
        unit: "count",
        target: 0,
        floor: 0.5,
      });
    }
    if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify({ rows: ROWS, startPx: START_PX, report }, null, 2));
    if (failed) process.exitCode = 1;
  } finally {
    await vite.close();
  }
}
