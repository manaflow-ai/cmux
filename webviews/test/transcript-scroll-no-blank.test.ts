// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolling a long chat never paints a blank frame, at any speed (Leo, 2026-11-17, on his NIGHTLY:
// "scrolling.. bit of blank screening when the content loads"). The 100k-row chat of
// bench/transcript-scroll-up.bench.ts (FIXTURE=flat) opens on its tail and pages older history in as the
// reader goes up; each scroll below starts on a fresh page, at rest, and runs a few rounds of frames
// with the pause a script's round trip leaves between them (so the first jump from rest and the first
// frame of every round are read). Every painted frame is read (support/upwardAnchorTrace.ts) and one is
// blank when the view shows no row, a row is missing between two shown, a gap between rows that no
// spacing token explains, or an edge gap past 8 px: the bench's own `blank`. The scrolls are the bench's
// three (a trackpad's wheel, a fling of 1,500 to 3,000 px a frame, a scrollbar drag of 2,400 to 4,800)
// and three whose speed changes under the transcript's lead (#45552 F1): a fling that slows from 3,000
// to 200 px a frame, one that turns back down mid-fling, and one whose frames alternate 800 and 3,000.
// Before, a frame whose offset moved in a frame callback painted the rows of the commit before it: a
// jump into the room above the loaded rows painted that room empty (`round 0 frame 3` of every fling),
// and a commit that was not the scroll pacer's left a jump past the rows it mounted (VirtualTranscript
// `armFrameGuard`). Chromium (the engine of the bench); run it yourself or on the browser lane:
// CMUX_BROWSER_TESTS=1 bun test test/transcript-scroll-no-blank.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";

await requireBrowserLane("transcript-scroll-no-blank.test.ts", async () => {
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript scroll no blank", () => test("no chromium", () => {}));
    return;
  }

  const ROWS = 100_000;
  const TURNS = ROWS / 2;
  const ROUNDS = 3;
  const FRAMES = 40;
  /// Each frame's move in px: negative is up (the bench's steps), positive down.
  const scrolls: { name: string; drag?: boolean; step: (frame: number) => number }[] = [
    { name: "wheel", step: (frame) => -[40.25, 95.5, 61.75, 128.125, 72.5, 101.25][frame % 6]! },
    { name: "fling", step: (frame) => -[1500, 2400, 1900, 3000, 2100][frame % 5]! },
    { name: "drag", drag: true, step: (frame) => -[2400, 4800, 3600, 3000][frame % 4]! },
    // #45552 F1: a fling that slows, from 3,000 to 200 px a frame over 20 frames, again and again.
    { name: "decelerating fling", step: (frame) => -Math.round(3000 - (2800 * (frame % 20)) / 19) },
    // #45552 F1: a fling that turns back: 10 frames up at 2,400, 5 down at 1,500.
    { name: "reversing fling", step: (frame) => (frame % 15 < 10 ? -2400 : 1500) },
    // #45552 F1: frames that alternate 800 and 3,000 px.
    { name: "uneven fling", step: (frame) => -(frame % 2 === 0 ? 800 : 3000) },
  ];

  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: TURNS,
      running: false,
      lead: [],
      attachPage: 160,
      session: { turnCount: TURNS },
      daemonIndexes: true,
      askedPageSize: true,
      production: {},
    });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  for (const scroll of scrolls)
    test(`chromium: a ${scroll.name} paints no blank frame`, async () => {
      const page = await pane.open({ width: 1100, height: 800 });
      try {
        const view = (await page.locator(".acpmux-scroll").boundingBox())!;
        await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
        const blanks: string[] = [];
        let frames = 0;
        for (let round = 0; round < ROUNDS; round++) {
          const trace = await page.evaluate(traceUpwardAnchors, {
            steps: Array.from({ length: FRAMES }, (_, frame) => scroll.step(round * FRAMES + frame)),
            restFrames: 0,
            drag: scroll.drag ?? false,
          });
          for (const sample of trace.samples) {
            frames += 1;
            const blank =
              sample.topRowId === null ||
              sample.missingRow ||
              sample.unexpectedRowBoxGap > 1 / 64 ||
              Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8;
            if (blank)
              blanks.push(
                `round ${round} frame ${sample.frame}: top ${Math.round(sample.scrollTop)} row ${sample.topRowId} edge ${Math.round(sample.topEdgeGap)}/${Math.round(sample.bottomEdgeGap)} gap ${sample.unexpectedRowBoxGap.toFixed(2)} missing ${sample.missingRow}`,
              );
          }
        }
        console.log(`transcript-scroll-no-blank ${scroll.name}: ${frames} frames, ${blanks.length} blank`);
        for (const line of blanks) console.log(`transcript-scroll-no-blank ${scroll.name} blank ${line}`);
        expect(frames).toBe(ROUNDS * FRAMES);
        expect(blanks).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
