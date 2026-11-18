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
// The last test is the case behind Leo's 2026-11-17 21:49Z report (a big gap under an expanded group, the
// rows shifting as he scrolled): in the bench's ordinary chat (tool runs, edits, long replies) a finished
// turn's "Worked for" and a tool run in it are opened by hand, then scrolled past both ways, at reading
// speed and at a fling's, a few times, and once more after the pane narrows while the run is out of view
// (its drawn height gone, so it is placed at its estimate: 22 px, its closed line, before). No row on screen moves but by the scroll (drift under 1 px) and no
// frame shows a gap no spacing token explains, a missing row or an edge gap.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { godLog } from "../bench/godFixture";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
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
        // Every stand-in the scroll puts up (conversation/standIns.ts): an empty box with no class.
        await page.evaluate(() => {
          const seen = { count: 0, dressed: 0 };
          (window as unknown as { __standIns: typeof seen }).__standIns = seen;
          new MutationObserver((records) => {
            for (const record of records)
              for (const node of record.addedNodes)
                if (node instanceof HTMLElement && node.parentElement?.classList.contains("acpmux-stand-ins")) {
                  seen.count += 1;
                  if (node.className || node.childNodes.length > 0) seen.dressed += 1;
                }
          }).observe(document.querySelector(".acpmux-scroll")!, { childList: true, subtree: true });
        });
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
        const standIns = await page.evaluate(
          () => (window as unknown as { __standIns: { count: number; dressed: number } }).__standIns,
        );
        console.log(
          `transcript-scroll-no-blank ${scroll.name}: ${frames} frames, ${blanks.length} blank, ${standIns.count} stand-ins`,
        );
        expect(standIns.dressed).toBe(0);
        for (const line of blanks) console.log(`transcript-scroll-no-blank ${scroll.name} blank ${line}`);
        expect(frames).toBe(ROUNDS * FRAMES);
        expect(blanks).toEqual([]);
      } finally {
        await page.close();
      }
    });

  test("chromium: an opened tool run scrolled past both ways keeps every row in place", async () => {
    const log = godLog("small", { turns: 600, imageEvery: 25, chainEvery: 150 });
    const lead: PapercutStep[] = log.events.map((event) => [
      event.dir,
      event.kind,
      event.msg as Record<string, unknown>,
      event.at,
    ]);
    const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;
    const ordinary = await papercutPane(() => browser, {
      turns: 1,
      running: false,
      lead,
      attachPage: 160,
      session: { turnCount: prompts },
      daemonIndexes: true,
      askedPageSize: true,
      production: {},
    });
    try {
      const page = await ordinary.open({ width: 1100, height: 800 });
      // The last finished turn's "Worked for", then the first of its tool runs with steps, opened by hand.
      const worked = page.locator('.acpmux-row .cv-worked[aria-expanded="false"]').last();
      await worked.click();
      const toggles = ".acpmux-row .cv-tools > .cv-tool.is-toggle";
      const run = page.locator(`${toggles}[aria-expanded="false"]`, { hasText: /^(Read|Ran) / }).first();
      await run.waitFor();
      const runText = (await run.textContent()) ?? "";
      const openBefore = await page.locator(`${toggles}[aria-expanded="true"]`).count();
      await run.click();
      await page.waitForFunction(
        ({ selector, before }) => document.querySelectorAll(`${selector}[aria-expanded="true"]`).length > before,
        { selector: toggles, before: openBefore },
      );
      for (let frame = 0; frame < 20; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
      const misses: string[] = [];
      const rounds = [
        Array.from({ length: 30 }, () => -60),
        Array.from({ length: 60 }, () => 60),
        Array.from({ length: 30 }, () => -60),
        Array.from({ length: 5 }, () => -1500),
        Array.from({ length: 10 }, () => 1500),
        Array.from({ length: 5 }, () => -1500),
        Array.from({ length: 30 }, () => -60),
        Array.from({ length: 30 }, () => 60),
      ];
      for (const [round, steps] of rounds.entries()) {
        // Away from the opened run (a fling up), the pane narrows: its drawn height is gone, and on the way
        // back down it is placed at its estimate until it mounts (model.ts `foldedRunSteps`).
        if (round === 4) {
          await page.setViewportSize({ width: 1000, height: 800 });
          for (let frame = 0; frame < 20; frame++) await page.evaluate(() => window.cmuxPaintFrame());
        }
        const trace = await page.evaluate(traceUpwardAnchors, { steps, restFrames: 0 });
        for (const sample of trace.samples) {
          const blank =
            sample.topRowId === null ||
            sample.missingRow ||
            sample.unexpectedRowBoxGap > 1 / 64 ||
            Math.max(sample.topEdgeGap, sample.bottomEdgeGap) > 8;
          const drift = sample.drift === null ? 0 : Math.abs(sample.drift);
          if (blank || drift >= 1)
            misses.push(
              `round ${round} frame ${sample.frame}: drift ${drift.toFixed(1)} (${sample.anchorId}) gap ${sample.unexpectedRowBoxGap.toFixed(1)} ${sample.unexpectedPair ?? ""} edge ${Math.round(sample.topEdgeGap)}/${Math.round(sample.bottomEdgeGap)} row ${sample.topRowId}`,
            );
        }
      }
      console.log(`transcript-scroll-no-blank opened run "${runText}": ${misses.length} frames off`);
      for (const line of misses) console.log(`transcript-scroll-no-blank opened run ${line}`);
      expect(misses).toEqual([]);
      await page.close();
    } finally {
      await ordinary.close();
    }
  });
});
