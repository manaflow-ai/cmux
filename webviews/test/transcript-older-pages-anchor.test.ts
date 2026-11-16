// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Scrolling up a long chat whose older pages come slowly, as from a busy acpmux holding millions of
// records (Leo, 2026-11-15: "this is super wack the way we're scrolling up infinitely :(", on his
// NIGHTLY's coordinator chat). The reader wheels up faster than pages come, so they keep reaching the
// top of the loaded rows while a page is out. Every painted frame is read, and the run fails when:
//
// - a row on screen moves by anything but what the wheel asked, past 1 px. Held at the loaded rows'
//   top while the page comes, the reader's wheel moves nothing and the row stays where it is; once a
//   page lands above, the row stays put again (support/upwardAnchorTrace.ts `drift`).
// - the scrollbar's thumb moves down while the reader goes up, or leaps up by more than the wheel
//   could move it. Before, the room held above the loaded rows for the history still to load
//   (conversation/olderReserve.ts) went each time the reader caught up with the loaded top, and came
//   back whole, the chat's estimated height, when the page landed: the thumb leapt from the top to the
//   bottom and back once a page, and the row on screen jumped by up to a viewport.
//
// The page is the pane's dev entry talking to a stand-in acpmux (support/papercutChat.ts) holding the
// generated ordinary chat (bench/godFixture.ts), each older page answered PAGE_LATENCY_MS late.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { godLog } from "../bench/godFixture";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";

await requireBrowserLane("transcript-older-pages-anchor.test.ts", async () => {
  setDefaultTimeout(420_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-older-pages-anchor: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("transcript older pages anchor", () => test("no engine", () => {}));
    return;
  }

  const TURNS = 1500;
  /// An older page lands this late: the reader below outruns it.
  const PAGE_LATENCY_MS = 2500;
  /// Rounds of FRAMES wheel steps, each about 170 px up (a quick trackpad scroll).
  const ROUNDS = 10;
  const FRAMES = 120;
  /// The older pages that must land under the reader for the run to count.
  const MIN_PAGES = 5;

  const log = godLog("small", { turns: TURNS, imageEvery: 25, chainEvery: 150 });
  const lead: PapercutStep[] = log.events.map((event) => [
    event.dir,
    event.kind,
    event.msg as Record<string, unknown>,
    event.at,
  ]);
  const prompts = log.events.filter((event) => event.kind === "user_message").length + 1;

  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  type Frame = { scrollTop: number; scrollHeight: number; clientHeight: number; room: number };

  for (const [name] of engines)
    test(`${name}: older pages landing while the reader scrolls up keep the row and the thumb`, async () => {
      const pane = await papercutPane(() => browsers.get(name)!, {
        turns: 1,
        running: false,
        lead,
        attachPage: 160,
        session: { turnCount: prompts },
        eventsLatencyMs: PAGE_LATENCY_MS,
        daemonIndexes: true,
      });
      try {
        const page = await pane.open({ width: 1100, height: 800 });
        const view = (await page.locator(".acpmux-scroll").boundingBox())!;
        await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
        // The room is held once the prompt count is read: the thumb is read from then on.
        await page.waitForFunction(
          () => Number(document.querySelector("[data-older-room]")?.getAttribute("data-older-room")) > 0,
          null,
          {
            timeout: 60_000,
          },
        );
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const frames: Frame[] = [];
          const stop = window.cmuxAfterPaint(() => {
            frames.push({
              scrollTop: scroller.scrollTop,
              scrollHeight: scroller.scrollHeight,
              clientHeight: scroller.clientHeight,
              room: Number(scroller.querySelector("[data-older-room]")?.getAttribute("data-older-room") ?? 0),
            });
          });
          (window as unknown as { __thumbWatch: { frames: Frame[]; stop(): void } }).__thumbWatch = { frames, stop };
        });
        const pagesBefore = pane.methods.filter((method) => method === "_acpmux/events").length;
        // SCREENCAST_DIR (Chromium): every frame the page paints while the wheel runs, as JPEGs, for a PR's
        // before/after video.
        const castDir = name === "chromium" ? process.env.SCREENCAST_DIR : undefined;
        const cast = castDir ? await page.context().newCDPSession(page) : undefined;
        let castFrames = 0;
        if (cast && castDir) {
          fs.mkdirSync(castDir, { recursive: true });
          cast.on("Page.screencastFrame", (frame: { data: string; sessionId: number }) => {
            castFrames += 1;
            fs.writeFileSync(
              path.join(castDir, `f${String(castFrames).padStart(5, "0")}.jpg`),
              Buffer.from(frame.data, "base64"),
            );
            void cast.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
          });
          await cast.send("Page.startScreencast", { format: "jpeg", quality: 70, everyNthFrame: 1 });
        }
        const samples: Awaited<ReturnType<typeof traceUpwardAnchors>>["samples"] = [];
        for (let round = 0; round < ROUNDS; round++) {
          const trace = await page.evaluate(traceUpwardAnchors, {
            steps: Array.from(
              { length: FRAMES },
              (_, frame) => -2 * [40.25, 95.5, 61.75, 128.125, 72.5, 101.25][frame % 6]!,
            ),
            restFrames: 0,
          });
          samples.push(...trace.samples.map((sample) => ({ ...sample, rowBoxIds: [] })));
        }
        if (cast) await cast.send("Page.stopScreencast").catch(() => {});
        const frames = await page.evaluate(() => {
          const watch = (window as unknown as { __thumbWatch: { frames: Frame[]; stop(): void } }).__thumbWatch;
          watch.stop();
          return watch.frames;
        });
        const pages = pane.methods.filter((method) => method === "_acpmux/events").length - pagesBefore;

        // The row on screen moves only with the wheel: down by at most what the wheel scrolled up, or not at
        // all (held at the loaded rows' top while a page comes). `drift` is the row's move less the wheel's
        // (support/upwardAnchorTrace.ts). A page landing that moves it further, or against the wheel, is a
        // jump. One move against the wheel is apart: a wheel step that went past the loaded rows' top into
        // the room shows that frame, and the scroll event after it puts the view back at the loaded top
        // (`handleScroll`), as the browser's threaded scrolling shows it too. That bounce gives back at most
        // the step before it, and is counted (`edgeBounces`), not failed: stopping the step itself takes a
        // wheel listener that can cancel, which made WebKit hold every trackpad scroll for the page (Leo,
        // 2026-10-29, wheelGlide.ts).
        const held = (sample: (typeof samples)[number]) =>
          sample.room > 0 && Math.abs(sample.scrollTop - sample.room) <= 1;
        const pastEdge = (sample: (typeof samples)[number] | undefined) =>
          sample !== undefined && sample.room > 0 && sample.scrollTop < sample.room - 1;
        let edgeBounces = 0;
        let edgeBounceMax = 0;
        const moved = samples.flatMap((sample, index) => {
          if (sample.drift === null) return [];
          const before = samples[index - 1];
          const shift = sample.drift - sample.wheelPixels;
          const further = Math.max(0, shift + sample.wheelPixels);
          if (shift < -1 && pastEdge(before) && -shift <= -before!.wheelPixels + 1) {
            edgeBounces += 1;
            edgeBounceMax = Math.max(edgeBounceMax, -shift);
            return [{ sample, before, shift, off: further }];
          }
          return [{ sample, before, shift, off: shift < 0 ? -shift : further }];
        });
        const jumps = moved.filter((each) => each.off > 1);
        // The thumb: its top, the offset's share of the content in the viewport's height.
        const thumbTop = (frame: Frame) => (frame.scrollTop / frame.scrollHeight) * frame.clientHeight;
        let thumbDown = 0;
        let thumbDownMax = 0;
        let thumbLeaps = 0;
        let thumbLeapMax = 0;
        for (let index = 1; index < frames.length; index++) {
          const step = thumbTop(frames[index]!) - thumbTop(frames[index - 1]!);
          if (step > 1) {
            thumbDown += 1;
            thumbDownMax = Math.max(thumbDownMax, step);
          }
          // A frame's wheel moves the thumb a fraction of a pixel in a chat this long.
          if (step < -20) {
            thumbLeaps += 1;
            thumbLeapMax = Math.max(thumbLeapMax, -step);
          }
        }
        const roomGone = frames.filter(
          (frame, index) => index > 0 && frame.room === 0 && frames[index - 1]!.room > 0,
        ).length;
        const summary = {
          pages,
          frames: samples.length,
          heldFrames: samples.filter(held).length,
          edgeBounces,
          edgeBounceMax: Math.round(edgeBounceMax),
          rowJumps: jumps.length,
          rowJumpMax: Math.round(Math.max(0, ...jumps.map((each) => each.off)) * 100) / 100,
          thumbDown,
          thumbDownMax: Math.round(thumbDownMax * 100) / 100,
          thumbLeaps,
          thumbLeapMax: Math.round(thumbLeapMax * 100) / 100,
          roomGone,
          firstJumps: jumps
            .slice(0, 12)
            .map(
              ({ sample, before, shift }) =>
                `${sample.anchorId} moved ${shift.toFixed(1)} px (wheel ${sample.wheelPixels.toFixed(0)}, top ${Math.round(before?.scrollTop ?? NaN)}->${Math.round(sample.scrollTop)}, room ${Math.round(before?.room ?? NaN)}->${Math.round(sample.room)}, first row ${sample.topRowId})`,
            ),
        };
        console.log(`transcript-older-pages-anchor ${name}: ${JSON.stringify(summary)}`);
        expect(pages).toBeGreaterThanOrEqual(MIN_PAGES);
        expect(summary.rowJumps).toBe(0);
        expect(summary.thumbDown).toBe(0);
        expect(summary.thumbLeaps).toBe(0);
      } finally {
        await pane.close();
      }
    });
});
