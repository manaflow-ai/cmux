#!/usr/bin/env bun
// Watch the chat simulator (src/agent-session/acpmux/sim/README.md "Watch it"): plays a scenario, a long
// run or any recorded chat in headless Chrome, drawn by the real VirtualTranscript with the pane's CSS and
// its motion on, on scaled real time, so streaming text, tool calls, subagents and folds move as the pane
// moves them. It writes a video of the run and screenshots at turn starts and ends (and every N steps).
//
//   bun scripts/chat-sim-watch.ts incoming-notice-turn --video /tmp/sim.webm --shots /tmp/sim-shots
//   bun scripts/chat-sim-watch.ts --long 3 --video /tmp/long.webm
//   bun scripts/chat-sim-watch.ts --replay test/fixtures/chat-sim/replay-lane-session.ndjson --limit 600
//   bun scripts/chat-sim-watch.ts --replay ~/.acpmux/sessions/<id> --from 2000 --to 3000 --speed 4
//
// Options: --speed X (virtual time X times real time, default 1), --max-gap MS (the longest real wait
// between two steps, default 1500), --width PX (default 720), --height PX (default 900), --shot-every N
// (a screenshot every N steps too), --motion on|off (default on), --max-seconds S (stop the run there,
// default 600). Needs Chrome: Linux, a lane VM or CI (never a Mac, as for the browser lane).
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { WatchOptions, WatchResult, WatchShot } from "../test/browser/chat-sim.harness";
import { CHAT_SIM_PAGE, startChatSimServer } from "../test/support/chatSimServer";
import { NO_PLAYWRIGHT_ON_MACS, playwrightRefusedHere, useSystemChrome } from "../test/support/systemChrome";
import { SCENARIOS, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { cutRecords, readRecords } from "./chat-sim-records";

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(name);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const number = (name: string, fallback?: number) => (value(name) === undefined ? fallback : Number(value(name)));

function usage(code: number): never {
  console.log(
    readFileSync(import.meta.path, "utf8")
      .split("\n")
      .slice(1, 15)
      .map((line) => line.replace(/^\/\/ ?/, ""))
      .join("\n"),
  );
  process.exit(code);
}

if (flag("--help") || flag("-h")) usage(0);
if (playwrightRefusedHere()) {
  console.error(NO_PLAYWRIGHT_ON_MACS);
  process.exit(3);
}

const options: WatchOptions = {
  speed: number("--speed", 1),
  maxGapMs: number("--max-gap", 1500),
  shotEvery: number("--shot-every", 0),
  maxSeconds: number("--max-seconds", 600),
};
const replay = value("--replay");
if (replay) {
  options.records = cutRecords(readRecords(replay), {
    from: number("--from"),
    to: number("--to"),
    limit: number("--limit"),
  });
  options.name = `replay:${path.basename(replay)}`;
} else if (value("--long")) {
  options.name = `long:${Number(value("--long"))}`;
} else {
  const name = args.find((arg, at) => !arg.startsWith("--") && !args[at - 1]?.startsWith("--"));
  if (!name || (!SCENARIOS[name] && name !== "replay")) {
    console.error(`no scenario ${name ?? ""}; one of: ${[...scenarioNames(), "replay"].join(", ")}`);
    usage(2);
  }
  options.name = name;
}

const width = number("--width", 720)!;
const height = number("--height", 900)!;
const motion = value("--motion") === "off" ? "off" : "on";
const videoOut = value("--video");
const shotsDir = value("--shots");
if (shotsDir) mkdirSync(shotsDir, { recursive: true });
const videoDir = videoOut
  ? path.join(path.dirname(path.resolve(videoOut)), `.chat-sim-video-${process.pid}`)
  : undefined;

// The whole run is bounded: the page stops playing at --max-seconds, and this ends the process three
// minutes past that (the server's warm-up and the video's write) whatever the page does.
const hardStopS = options.maxSeconds! + 180;
const hardStop = setTimeout(() => {
  console.error(`chat-sim-watch: still running ${hardStopS} s in; stopping`);
  process.exit(124);
}, hardStopS * 1000);
hardStop.unref();

// The pane's strings tables are build output; write any that are stale, as the test preload does, so
// rows show their words and not their keys.
{
  const { writeStrings } = await import("./pages/gen-strings.mjs");
  writeStrings({ ifStale: true, bestEffort: true, log: () => {} });
  writeStrings({ only: ["agentPane"] as never[], bestEffort: true, log: () => {} });
}

const { chromium } = await import("playwright");
useSystemChrome(chromium);
const { vite, base } = await startChatSimServer();
const browser = await chromium.launch({ headless: true });
let result: WatchResult | undefined;
try {
  const context = await browser.newContext({
    viewport: { width, height },
    ...(videoDir ? { recordVideo: { dir: videoDir, size: { width, height } } } : {}),
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => console.error(`chat-sim page: ${error.message}`));
  let shot = 0;
  await page.exposeFunction("__chatSimShot", async (at: WatchShot) => {
    shot += 1;
    if (!shotsDir) return;
    const file = path.join(
      shotsDir,
      `${String(shot).padStart(3, "0")}-step${String(at.step).padStart(5, "0")}-turn${at.turn}-${at.why}.png`,
    );
    await page.screenshot({ path: file });
  });
  await page.goto(`${base}${CHAT_SIM_PAGE}?width=${width}&motion=${motion}`);
  await page.waitForFunction(() => "__chatSim" in window);
  console.log(
    `chat-sim-watch: ${options.name} (${options.records ? `${options.records.length} records, ` : ""}speed ${options.speed}, motion ${motion}, max ${options.maxSeconds} s)`,
  );
  result = (await page.evaluate(
    (watchOptions) =>
      (window as unknown as { __chatSim: { watch(o: unknown): Promise<unknown> } }).__chatSim.watch(watchOptions),
    options,
  )) as WatchResult;
  const video = page.video();
  await context.close();
  if (video && videoOut) {
    copyFileSync(await video.path(), videoOut);
    console.log(`video: ${videoOut}`);
  }
} finally {
  await browser.close();
  await vite.close();
}
if (shotsDir) {
  writeFileSync(path.join(shotsDir, "result.json"), JSON.stringify(result, null, 1));
  console.log(`shots: ${shotsDir} (${result?.shots ?? 0})`);
}
if (videoDir) rmSync(videoDir, { recursive: true, force: true });
console.log(
  `${result!.scenario}: played ${result!.played}/${result!.steps} steps, ${result!.turns} turns, ${Math.round(result!.virtualMs / 1000)} s simulated in ${Math.round(result!.wallMs / 1000)} s${result!.stoppedEarly ? " (stopped at --max-seconds)" : ""}; model-rule violations ${result!.violations}`,
);
clearTimeout(hardStop);
process.exit(0);
