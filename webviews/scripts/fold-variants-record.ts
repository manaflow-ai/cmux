#!/usr/bin/env bun
// Records the big Claude turn fold in each of its looks (turnEndFold.ts `TURN_END_LOOKS`) at real speed in
// headless Chrome, and measures each: the most any content in the view moves between two frames (px), the
// fold's length (ms), and the widest blank band the view opens while it plays (px, the "gash").
// Leo, 2026-11-22: "the big fold we do for claude is not good looking enough. it looks like a gash collapsing."
//
//   bun scripts/fold-variants-record.ts [--looks fade,tuck,...] [--out DIR] [--ffmpeg PATH] [--scenario replay]
//     [--fixture FILE.ndjson --end STEP --tag NAME]
//
// `--fixture` records a recorded chat from outside the repo (copied under node_modules/ for the dev server,
// never committed) up to the turn end at step `--end`; `--tag` names its clips fold-TAG-LOOK.mp4.
//
// The page is test/browser/fold-variants.html (the chat-sim big-claude-turn scenario, drawn by the real
// VirtualTranscript with motion on). Frames come from Chrome's screencast with their own timestamps, so the
// clip plays at real speed at 60 fps (ffmpeg). The numbers come from the page itself, every frame.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { Browser, Page } from "playwright";

const webviews = path.resolve(import.meta.dir, "..");
const PAGE = "/test/browser/fold-variants.html";

const WIDTH = 720;
const HEIGHT = 640;

type Row = [key: string, top: number, height: number, ink: number];
type Sample = { t: number; folding: boolean; rows: Row[] };
type Run = { look: string; samples: Sample[]; startedAt: number; view?: number };

/** The run's numbers: over the frames from the fold's start to when nothing moves any more. */
export function measure(run: Run) {
  const { samples } = run;
  const first = samples.findIndex((sample) => sample.folding);
  if (first < 0) return undefined;
  // Visible: drawn with some ink on both frames.
  const seen = (ink: number) => ink > 0.05;
  let maxJump = 0;
  let maxJumpRaw = 0;
  let lastChange = first;
  let worstAt = 0;
  for (let index = Math.max(1, first); index < samples.length; index += 1) {
    const before = new Map(samples[index - 1]!.rows.map((row) => [row[0], row]));
    let changed = false;
    for (const row of samples[index]!.rows) {
      const prior = before.get(row[0]);
      if (!prior) {
        if (seen(row[3])) changed = true;
        continue;
      }
      const jump = Math.abs(row[1] - prior[1]);
      if (jump > 0.25 || Math.abs(row[3] - prior[3]) > 0.01) changed = true;
      maxJumpRaw = Math.max(maxJumpRaw, jump);
      if (seen(row[3]) && seen(prior[3]) && jump > maxJump) {
        maxJump = jump;
        worstAt = samples[index]!.t - samples[first]!.t;
      }
    }
    if (samples[index - 1]!.rows.some((row) => seen(row[3]) && !samples[index]!.rows.some((r) => r[0] === row[0])))
      changed = true;
    if (changed) lastChange = index;
  }
  // The widest blank band between inked boxes, past the band at rest (the last frame's).
  const band = (sample: Sample) => {
    const boxes = sample.rows
      .filter((row) => row[3] > 0.15)
      .map((row) => [row[1], row[1] + row[2]] as const)
      .sort((a, b) => a[0] - b[0]);
    let widest = 0;
    let reach = boxes[0]?.[1] ?? 0;
    for (const [top, bottom] of boxes.slice(1)) {
      widest = Math.max(widest, top - reach);
      reach = Math.max(reach, bottom);
    }
    return widest;
  };
  // The reader's anchor: the row under the view's center on the frame before the fold, among the rows
  // still drawn at the end (a folded call is not an anchor; the nearest kept row is). Its drift is where it
  // ends against where it was; its step, the most it moves in one frame.
  const before = samples[Math.max(0, first - 1)]!;
  const last = samples.at(-1)!;
  const kept = new Set(last.rows.map((row) => row[0]));
  const center = (run.view ?? 0) / 2;
  const candidates = before.rows.filter((row) => kept.has(row[0]) && !row[0].startsWith("ghost-"));
  const anchor = candidates
    .map((row) => ({
      row,
      off:
        row[1] <= center && center <= row[1] + row[2]
          ? 0
          : Math.min(Math.abs(row[1] - center), Math.abs(row[1] + row[2] - center)),
    }))
    .sort((a, b) => a.off - b.off)[0]?.row;
  let anchorStep = 0;
  let anchorDrift = 0;
  if (anchor) {
    let prior = anchor[1];
    for (let index = first; index <= lastChange; index += 1) {
      const row = samples[index]!.rows.find((r) => r[0] === anchor[0]);
      if (!row) continue;
      anchorStep = Math.max(anchorStep, Math.abs(row[1] - prior));
      prior = row[1];
    }
    const end = last.rows.find((r) => r[0] === anchor[0]);
    if (end) anchorDrift = end[1] - anchor[1];
  }
  // The blink: the most a row that is drawn before and after the fold fades on the way (dissolve's cost).
  let blink = 0;
  const steady = before.rows.filter((row) => row[3] > 0.95 && last.rows.some((r) => r[0] === row[0] && r[3] > 0.95));
  for (const row of steady)
    for (let index = first; index <= lastChange; index += 1) {
      const now = samples[index]!.rows.find((r) => r[0] === row[0]);
      if (now) blink = Math.max(blink, 1 - now[3]);
    }
  const rest = band(samples.at(-1)!);
  let gash = 0;
  for (let index = first; index <= lastChange; index += 1) gash = Math.max(gash, band(samples[index]!) - rest);
  return {
    maxJumpPx: Math.round(maxJump * 10) / 10,
    maxJumpAnyInkPx: Math.round(maxJumpRaw * 10) / 10,
    worstFrameMs: Math.round(worstAt),
    durationMs: Math.round(samples[lastChange]!.t - samples[first]!.t),
    gashPx: Math.round(gash),
    anchorDriftPx: Math.round(anchorDrift * 10) / 10,
    anchorStepPx: Math.round(anchorStep * 10) / 10,
    blink: Math.round(blink * 100) / 100,
    frames: lastChange - first + 1,
    foldStart: samples[first]!.t,
    foldEnd: samples[lastChange]!.t,
  };
}

/** A dev server for the recording page, warmed, and a headless Chrome: what every recording runs on. */
export async function openRecorder() {
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
  const vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    mode: "production",
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    cacheDir: path.join(webviews, "node_modules/.vite-fold-variants"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  const { warmViteServer } = await import("../test/support/warmDevServer");
  await warmViteServer(vite, PAGE);
  const { port } = vite.httpServer!.address() as { port: number };
  const browser = await chromium.launch({ headless: true });
  return {
    browser,
    port,
    async close() {
      await browser.close();
      await vite.close();
    },
  };
}

export type RecordOptions = {
  look: string;
  /** The page's scenario name: `big-claude-turn`, `replay`, `url:PATH` or `matrix:JSON`. */
  scenario: string;
  /** Stop the chat at this step (a turn end) and fast-forward to shortly before it. */
  end?: number;
  width?: number;
  height?: number;
  out: string;
  /** Names the run's files: fold-NAME.mp4, NAME.samples.json. */
  name: string;
  ffmpeg: string;
};

/** Plays one look of one scenario in a fresh page, records its clip, and returns its numbers. */
export async function recordLook(browser: Browser, port: number, options: RecordOptions) {
  const { look, scenario, end, out, name, ffmpeg } = options;
  const width = options.width ?? WIDTH;
  const height = options.height ?? HEIGHT;
  const page: Page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  page.on("pageerror", (error) => console.error(`${name}: ${error.message}`));
  await page.goto(`http://127.0.0.1:${port}${PAGE}?width=${width}&height=${height}`, { timeout: 180_000 });
  await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 120_000 });
  const frames = path.join(out, `frames-${name}`);
  rmSync(frames, { recursive: true, force: true });
  mkdirSync(frames, { recursive: true });
  const cdp = await page.context().newCDPSession(page);
  const shots: { file: string; t: number }[] = [];
  cdp.on("Page.screencastFrame", async (frame) => {
    const file = path.join(frames, `${String(shots.length).padStart(5, "0")}.jpg`);
    writeFileSync(file, Buffer.from(frame.data, "base64"));
    shots.push({ file, t: frame.metadata.timestamp! * 1000 });
    await cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
  });
  await cdp.send("Page.startScreencast", { format: "jpeg", quality: 90, everyNthFrame: 1 });
  const run = (await page.evaluate(
    ([look, scenario, end]) =>
      (
        window as unknown as {
          __fold: { run(look: string, name: string, tailMs?: number, end?: number): Promise<unknown> };
        }
      ).__fold.run(look as string, scenario as string, undefined, end as number | undefined),
    [look, scenario, end] as const,
  )) as Run;
  await cdp.send("Page.stopScreencast");
  const numbers = measure(run);
  writeFileSync(path.join(out, `${name}.samples.json`), JSON.stringify(run));
  let clip: string | undefined;
  if (numbers && shots.length) {
    // Page time to wall time: performance.timeOrigin + t.
    const from = run.startedAt + numbers.foldStart - 500;
    const to = run.startedAt + numbers.foldEnd + 600;
    const kept = shots.filter((shot) => shot.t >= from && shot.t <= to);
    const list = kept
      .map((shot, index) => {
        const next = kept[index + 1]?.t ?? shot.t + 1000 / 60;
        return `file '${shot.file}'\nduration ${Math.max(1, next - shot.t) / 1000}`;
      })
      .join("\n");
    const listFile = path.join(frames, "list.txt");
    writeFileSync(listFile, `${list}\nfile '${kept.at(-1)?.file}'\n`);
    clip = path.join(out, `fold-${name}.mp4`);
    const made = spawnSync(
      ffmpeg,
      [
        "-y",
        "-loglevel",
        "error",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        listFile,
        "-vf",
        "fps=60,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
        "-c:v",
        "libx264",
        "-crf",
        "20",
        "-movflags",
        "+faststart",
        clip,
      ],
      { stdio: "inherit" },
    );
    if (made.status !== 0) {
      console.error(`${name}: ffmpeg failed`);
      clip = undefined;
    }
  }
  await page.close();
  return { numbers, clip };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const value = (name: string) => {
    const at = args.indexOf(name);
    return at >= 0 ? args[at + 1] : undefined;
  };
  const out = path.resolve(value("--out") ?? "/tmp/fold-variants");
  const ffmpeg = value("--ffmpeg") ?? "ffmpeg";
  const fixture = value("--fixture");
  const end = value("--end") === undefined ? undefined : Number(value("--end"));
  const tag = value("--tag");
  const scenario = fixture
    ? `url:/node_modules/.fold-fixtures/${path.basename(fixture)}`
    : (value("--scenario") ?? "big-claude-turn");
  const { TURN_END_LOOKS } = await import("../src/agent-session/acpmux/conversation/turnEndFold");
  const looks = value("--looks")?.split(",") ?? [...TURN_END_LOOKS];
  if (fixture) {
    const { copyFileSync } = await import("node:fs");
    mkdirSync(path.join(webviews, "node_modules/.fold-fixtures"), { recursive: true });
    copyFileSync(fixture, path.join(webviews, "node_modules/.fold-fixtures", path.basename(fixture)));
  }
  mkdirSync(out, { recursive: true });
  const recorder = await openRecorder();
  const results: Record<string, unknown> = {};
  for (const look of looks) {
    const name = tag ? `${tag}-${look}` : look;
    const { numbers } = await recordLook(recorder.browser, recorder.port, { look, scenario, end, out, name, ffmpeg });
    results[look] = numbers ?? { error: "no fold played" };
    console.log(`${look.padEnd(10)} ${JSON.stringify(numbers)}`);
  }
  writeFileSync(path.join(out, tag ? `results-${tag}.json` : "results.json"), JSON.stringify(results, null, 1));
  await recorder.close();
}
