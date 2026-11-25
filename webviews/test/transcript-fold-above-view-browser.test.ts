// cmux-web-test-timeout: 600
// Leo's fold case, played through and scrolled, as a gate. Leo, 2026-11-22: "your chat folds or whatever,
// i scroll down, some bullshit ABOVE folds...? and plays an animation!? ... edge cases at teh top area of
// teh screeen and a long turn/tool call/sterring situation that has a wide-ass aggressive fold... yeah we
// gotta think deep and hill climb that."
//
// transcript-motion-fuzz-browser.test.ts gates the fuzzer's drawn seeds, but it plays them with the
// reader still: no seed there is scrolled after its fold, which is the moment he named. This file plays
// his shape pinned (fold-fuzz.scenario.ts `leoFoldScenario`): 120 calls with chatter and a subagent,
// four steers (between calls, mid-call, mid-answer, and a next prompt as the fold plays), four turns
// above it, a 1280 x 800 pane, the turn's end reached with the reader 420 px up so the fold lands at the
// top of the view, then the reader's wheel: down to the bottom, up through the chat to its top, and down
// again. Each frame is read by the transcript motion detector (support/transcriptMotion.ts), and the
// rule is cmuxterm-hq docs/design/transcript-animation-rules.md: "An animation plays only for a change the
// reader caused or is looking at, and only where the reader can see it".
//
// Per seed (the seed varies the timings, the chatter and the sweep's steps; the shape is his):
// - no `offscreen-start`: nothing starts on a row out of the view, the fold above it included;
// - no `scroll-start`: nothing starts on a row because the reader scrolled to it;
// - no row `move` once the sweep starts: with the reader's own scroll taken out, a row he is reading is
//   drawn where it was the frame before (a fold or a remeasure above the view shifts nothing in it).
// A play is real time on a shared runner, so a seed that fails plays again alone and fails only when
// the same kind repeats.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import type { MotionFlag, MotionRecord } from "./support/transcriptMotion";

await requireBrowserLane("transcript-fold-above-view-browser.test.ts", async () => {
  setDefaultTimeout(580_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-above-view-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("fold above the view", () => test("chromium", () => {}));
    return;
  }
  const { openRecorder } = await import("../scripts/fold-variants-record");
  const { transcriptMoves } = await import("./support/transcriptMotion");
  const { SPLITS } = await import("./browser/fold-fuzz.scenario");
  /// The shipped fold look (turnEndFold.ts: `fade`).
  const LOOK = "fade";
  const SEEDS = (process.env.CMUX_LEO_FOLD_SEEDS ?? "1,2,3,4").split(",").map(Number);
  let recorder: Awaited<ReturnType<typeof openRecorder>>;
  beforeAll(async () => {
    recorder = await openRecorder();
  });
  afterAll(async () => {
    await recorder?.close();
  });

  type FoldWindow = {
    __fold: {
      run(look: string, name: string): Promise<unknown>;
      size(w: number, h: number): void;
    };
  };
  const play = async (page: Page, seed: number) => {
    const { width, height } = SPLITS.wide;
    await page.setViewportSize({ width, height });
    const run = (await page.evaluate(
      ([look, name, w, h]) => {
        const fold = (window as unknown as FoldWindow).__fold;
        fold.size(w, h);
        return fold.run(look, name);
      },
      [LOOK, `leo:${seed}`, width, height] as const,
    )) as { motion?: MotionRecord };
    if (!run.motion) throw new Error(`leo:${seed}: the page recorded no motion`);
    return run.motion;
  };
  /// The first frame of the reader's sweep: the first reader input after the chat's last record.
  const sweepStart = (record: MotionRecord) => {
    let lastRecord = -1;
    record.frames.forEach((frame, index) => {
      if (frame.marks.some((mark) => !mark.startsWith("input:"))) lastRecord = index;
    });
    const first = record.frames.findIndex(
      (frame, index) => index > lastRecord && frame.marks.some((mark) => mark.startsWith("input:reader")),
    );
    return first < 0 ? record.frames.length : first;
  };
  /// What breaks the rule in one play, as `kind key detail` lines.
  const faults = (record: MotionRecord) => {
    const from = sweepStart(record);
    const flags = transcriptMoves(record);
    const bad = (flag: MotionFlag) =>
      flag.kind === "offscreen-start" ||
      flag.kind === "scroll-start" ||
      (flag.kind === "move" && flag.of === "row" && flag.frame >= from);
    return {
      sweepFrames: record.frames.length - from,
      faults: flags
        .filter(bad)
        .map(
          (flag) =>
            `${flag.kind} ${flag.key} ${Math.round(flag.px)}px after [${flag.after.join(", ")}]${
              flag.cause.length ? ` cause ${flag.cause.join(", ")}` : ""
            }${flag.detail ? ` ${flag.detail}` : ""}`,
        ),
    };
  };
  const kinds = (lines: string[]) => new Set(lines.map((line) => line.split(" ")[0]));

  test(`a wide fold above the view starts nothing and shifts nothing as the reader scrolls (seeds ${SEEDS.join(", ")})`, async () => {
    const page = await recorder.browser.newPage({
      viewport: SPLITS.wide,
      deviceScaleFactor: 1,
    });
    page.on("pageerror", (error) => console.error(`page: ${error.message}`));
    await page.goto(`http://127.0.0.1:${recorder.port}/test/browser/fold-variants.html`, { timeout: 60_000 });
    await page.waitForFunction(() => "__fold" in window, undefined, {
      timeout: 60_000,
    });
    const confirmed: string[] = [];
    for (const seed of SEEDS) {
      const first = faults(await play(page, seed));
      console.log(`leo:${seed}: ${first.sweepFrames} sweep frames, ${first.faults.length} faults`);
      expect(first.sweepFrames).toBeGreaterThan(30);
      if (!first.faults.length) continue;
      for (const line of first.faults.slice(0, 12)) console.log(`  leo:${seed} ${line}`);
      // Played again: a kind counts only when it repeats.
      const again = faults(await play(page, seed));
      const repeated = kinds(again.faults);
      for (const kind of kinds(first.faults))
        if (repeated.has(kind))
          confirmed.push(`leo:${seed} ${kind}: ${again.faults.find((line) => line.startsWith(kind))}`);
    }
    await page.close();
    expect(confirmed).toEqual([]);
  });
});
