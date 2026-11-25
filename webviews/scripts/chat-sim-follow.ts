#!/usr/bin/env bun
// The followed transcript's jolts on a recorded chat, per follow-motion arm (Leo, 2026-11-22: "i also
// feel like the animation or whatever for when im at the bottom and the text is streaming to be a bit
// jarring ... it's just not great design to have the jolts. esp in tandem with how aggressively we're
// folding claude code chats. it's not smooth."). It plays a fixture in headless Chrome on scaled real
// time with the pane's motion on, as scripts/chat-sim-watch.ts does, once per arm, and samples every
// drawn frame: the scroll offset, where the newest reply row paints and where the newest row above
// the live line paints. It prints, per arm, the frames
// per second whose newest reply text moved past half a line and the largest frame-to-frame move
// (test/support/streamFollowReport.ts), and writes a video per arm with --videos DIR.
//
//   bun scripts/chat-sim-follow.ts --replay /tmp/chat-sim/coord-tool-burst.ndjson --arms send,steady \
//     --speed 1 --max-seconds 120 --videos /tmp/follow --out /tmp/follow/report.json
//
// Options as chat-sim-watch.ts: --from/--to/--limit, --speed X, --max-gap MS, --width, --height,
// --max-seconds S. CHAT_SIM_FOLLOW_DEBUG=PREFIX writes each arm's frames to PREFIX-ARM.json. A fixture
// that starts mid-turn draws that turn with no live line under the reply, and its reply steps at once
// on every arm (followGlide.ts followRoom). Needs Chrome (Linux, a lane VM or CI; never a Mac;
// CMUX_PLAYWRIGHT_BUNDLED_CHROMIUM=1 where only Playwright's Chromium is installed).
import { copyFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { WatchOptions, WatchResult } from "../test/browser/chat-sim.harness";
import { CHAT_SIM_PAGE, startChatSimServer } from "../test/support/chatSimServer";
import { NO_PLAYWRIGHT_ON_MACS, playwrightRefusedHere, useSystemChrome } from "../test/support/systemChrome";
import { JOLT_PX, moves, type Moves } from "../test/support/streamFollowReport";
import { cutRecords, readRecords } from "./chat-sim-records";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const number = (name: string, fallback?: number) => (value(name) === undefined ? fallback : Number(value(name)));

if (playwrightRefusedHere()) {
  console.error(NO_PLAYWRIGHT_ON_MACS);
  process.exit(3);
}
const replay = value("--replay");
if (!replay) {
  console.error("chat-sim-follow: --replay FILE is required");
  process.exit(2);
}
const records = cutRecords(readRecords(replay), {
  from: number("--from"),
  to: number("--to"),
  limit: number("--limit"),
});
const arms = (value("--arms") ?? "send,steady").split(",").filter(Boolean);
const width = number("--width", 720)!;
const height = number("--height", 900)!;
const videos = value("--videos");
const out = value("--out");
const options: WatchOptions = {
  name: `replay:${path.basename(replay)}`,
  records,
  speed: number("--speed", 1),
  maxGapMs: number("--max-gap", 1500),
  maxSeconds: number("--max-seconds", 120),
};

/** One drawn frame: the scroll offset, how far the view is from the bottom, and the newest reply row. */
type FollowSample = {
  t: number;
  scrollTop: number;
  gap: number;
  reader?: { id: string; top: number };
  tail?: { id: string; top: number };
  /** The running turn's live line is drawn (under the reply while it streams: "Writing"). */
  live?: boolean;
};

type FollowReport = {
  arm: string;
  frames: number;
  /** Followed frames that drew a reply row, the ones the reader's moves come from. */
  readerFrames: number;
  seconds: number;
  scroll: Moves;
  reader: Moves;
  /** The newest drawn row above the live line (a tool call, a fold or a reply), between frames that drew the same row. */
  tail: Moves;
  /** The reader's moves while a live turn's reply streams: the reply is the newest row over the live
   *  line in both frames. Apart from a prompt or a notice that lands under it (the send's own move, at
   *  once on every arm) and a turn the fixture opened mid-way (no prompt row, so no live line). */
  streaming: Moves;
  watch: Pick<WatchResult, "played" | "steps" | "turns" | "stoppedEarly">;
};

/** Frame-to-frame moves between followed frames (within two lines of the bottom); the reader's only
 *  between frames that drew the same row. */
function followReport(arm: string, samples: FollowSample[], watch: WatchResult): FollowReport {
  const followed = samples.filter((sample) => sample.gap < 46);
  const seconds = followed.length > 1 ? (followed.at(-1)!.t - followed[0]!.t) / 1000 : 0;
  const scroll: number[] = [];
  const reader: number[] = [];
  const tail: number[] = [];
  const streaming: number[] = [];
  for (let index = 1; index < followed.length; index += 1) {
    const before = followed[index - 1]!;
    const after = followed[index]!;
    scroll.push(after.scrollTop - before.scrollTop);
    reader.push(before.reader && after.reader?.id === before.reader.id ? after.reader.top - before.reader.top : 0);
    tail.push(before.tail && after.tail?.id === before.tail.id ? after.tail.top - before.tail.top : 0);
    const reply = before.reader?.id;
    streaming.push(
      reply?.startsWith("assistant") &&
        before.live &&
        after.live &&
        before.tail?.id === reply &&
        after.tail?.id === reply &&
        after.reader?.id === reply
        ? after.reader.top - before.reader!.top
        : 0,
    );
  }
  return {
    arm,
    frames: followed.length,
    readerFrames: followed.filter((sample) => sample.reader).length,
    seconds: Math.round(seconds * 100) / 100,
    scroll: moves(scroll, seconds, JOLT_PX),
    reader: moves(reader, seconds, JOLT_PX),
    tail: moves(tail, seconds, JOLT_PX),
    streaming: moves(streaming, seconds, JOLT_PX),
    watch: { played: watch.played, steps: watch.steps, turns: watch.turns, stoppedEarly: watch.stoppedEarly },
  };
}

{
  const { writeStrings } = await import("./pages/gen-strings.mjs");
  writeStrings({ ifStale: true, bestEffort: true, log: () => {} });
  writeStrings({ only: ["agentPane"] as never[], bestEffort: true, log: () => {} });
}

const { chromium } = await import("playwright");
useSystemChrome(chromium);
const { vite, base } = await startChatSimServer();
const browser = await chromium.launch({ headless: true });
const reports: FollowReport[] = [];
try {
  if (videos) mkdirSync(videos, { recursive: true });
  for (const arm of arms) {
    const videoDir = videos ? path.join(videos, `.video-${arm}-${process.pid}`) : undefined;
    const context = await browser.newContext({
      viewport: { width, height },
      ...(videoDir ? { recordVideo: { dir: videoDir, size: { width, height } } } : {}),
    });
    await context.addInitScript((pick: string) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "follow-motion": pick }));
      // The run measures the motion itself: a loaded machine's frames never turn the chat's minimal
      // motion on under it (frameBudget.ts FULL_MOTION), as browser/send-stream-motion.harness.tsx.
      document.documentElement?.setAttribute("data-chat-motion", "full");
      // Every drawn frame, after layout: the scroll offset and the newest reply row's top.
      const samples: unknown[] = [];
      Object.assign(window, { __followSamples: samples });
      const sample = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (scroller) {
          // The newest drawn row above the live line, whatever it is (a tool call, a fold, a reply).
          const rows = scroller.querySelectorAll<HTMLElement>(".acpmux-row");
          let tail: HTMLElement | undefined;
          for (let index = rows.length - 1; index >= 0 && !tail; index -= 1) {
            const candidate = rows[index]!;
            if (candidate.dataset.rowId !== "thinking-live" && candidate.getBoundingClientRect().height > 0)
              tail = candidate;
          }
          const texts = scroller.querySelectorAll<HTMLElement>(".cv-md");
          const newest = texts[texts.length - 1];
          const row = newest?.closest<HTMLElement>(".acpmux-row");
          samples.push({
            t: performance.now(),
            scrollTop: scroller.scrollTop,
            gap: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
            ...(newest && row
              ? { reader: { id: row.dataset.rowId ?? "", top: newest.getBoundingClientRect().top } }
              : {}),
            live: Boolean(scroller.querySelector(".acpmux-row[data-row-id='thinking-live']")),
            ...(tail ? { tail: { id: tail.dataset.rowId ?? "", top: tail.getBoundingClientRect().top } } : {}),
          });
        }
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    }, arm);
    const page = await context.newPage();
    page.on("pageerror", (error) => console.error(`chat-sim page: ${error.message}`));
    await page.goto(`${base}${CHAT_SIM_PAGE}?width=${width}&motion=on`);
    await page.waitForFunction(() => "__chatSim" in window);
    const watch = (await page.evaluate(
      (watchOptions) =>
        (window as unknown as { __chatSim: { watch(o: unknown): Promise<unknown> } }).__chatSim.watch(watchOptions),
      options,
    )) as WatchResult;
    const samples = (await page.evaluate(
      () => (window as unknown as { __followSamples: unknown[] }).__followSamples,
    )) as FollowSample[];
    const video = page.video();
    await context.close();
    if (video && videos) {
      const file = path.join(videos, `${path.basename(replay, ".ndjson")}-${arm}-x${options.speed}.webm`);
      copyFileSync(await video.path(), file);
      rmSync(videoDir!, { recursive: true, force: true });
    }
    if (process.env.CHAT_SIM_FOLLOW_DEBUG)
      writeFileSync(`${process.env.CHAT_SIM_FOLLOW_DEBUG}-${arm}.json`, JSON.stringify(samples));
    const report = followReport(arm, samples, watch);
    reports.push(report);
    console.log(`chat-sim-follow ${path.basename(replay)} x${options.speed} ${arm}: ${JSON.stringify(report)}`);
  }
} finally {
  await browser.close();
  await vite.close();
}
console.log(
  `| arm | streaming jolts/s | streaming max px | streaming jerk p95 | reader jolts/s | reader max px | reader jerk p95 | newest row jolts/s | newest row max px | scroll jolts/s | scroll max px | frames |`,
);
console.log(`|---|---|---|---|---|---|---|---|---|---|---|---|`);
for (const r of reports)
  console.log(
    `| ${r.arm} | ${r.streaming.joltsPerS} | ${r.streaming.maxPx} | ${r.streaming.jerkP95Px} | ${r.reader.joltsPerS} | ${r.reader.maxPx} | ${r.reader.jerkP95Px} | ${r.tail.joltsPerS} | ${r.tail.maxPx} | ${r.scroll.joltsPerS} | ${r.scroll.maxPx} | ${r.frames} |`,
  );
if (out) writeFileSync(out, JSON.stringify(reports, null, 1));
process.exit(0);
