#!/usr/bin/env bun
// Records the big Claude turn fold in each of its looks (turnEndFold.ts `TURN_END_LOOKS`) at real speed in
// headless Chrome, and measures each: the most any content in the view moves between two frames (px), the
// fold's length (ms), and the widest blank band the view opens while it plays (px, the "gash").
// Leo, 2026-11-22: "the big fold we do for claude is not good looking enough. it looks like a gash collapsing."
//
//   bun scripts/fold-variants-record.ts [--looks fade,tuck,...] [--out DIR] [--ffmpeg PATH] [--scenario replay]
//
// The page is test/browser/fold-variants.html (the chat-sim big-claude-turn scenario, drawn by the real
// VirtualTranscript with motion on). Frames come from Chrome's screencast with their own timestamps, so the
// clip plays at real speed at 60 fps (ffmpeg). The numbers come from the page itself, every frame.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { Page } from "playwright";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const webviews = path.resolve(import.meta.dir, "..");
const out = path.resolve(value("--out") ?? "/tmp/fold-variants");
const ffmpeg = value("--ffmpeg") ?? "ffmpeg";
const scenario = value("--scenario") ?? "big-claude-turn";
const { TURN_END_LOOKS } = await import("../src/agent-session/acpmux/conversation/turnEndFold");
const looks = value("--looks")?.split(",") ?? [...TURN_END_LOOKS];
const WIDTH = 720;
const HEIGHT = 640;

type Row = [key: string, top: number, height: number, ink: number];
type Sample = { t: number; folding: boolean; rows: Row[] };
type Run = { look: string; samples: Sample[]; startedAt: number };

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
  const rest = band(samples.at(-1)!);
  let gash = 0;
  for (let index = first; index <= lastChange; index += 1) gash = Math.max(gash, band(samples[index]!) - rest);
  return {
    maxJumpPx: Math.round(maxJump * 10) / 10,
    maxJumpAnyInkPx: Math.round(maxJumpRaw * 10) / 10,
    worstFrameMs: Math.round(worstAt),
    durationMs: Math.round(samples[lastChange]!.t - samples[first]!.t),
    gashPx: Math.round(gash),
    frames: lastChange - first + 1,
    foldStart: samples[first]!.t,
    foldEnd: samples[lastChange]!.t,
  };
}

if (import.meta.main) {
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
  const PAGE = "/test/browser/fold-variants.html";
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
  mkdirSync(out, { recursive: true });
  const results: Record<string, unknown> = {};
  for (const look of looks) {
    const page: Page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });
    page.on("pageerror", (error) => console.error(`${look}: ${error.message}`));
    page.on("console", (m) => m.type() === "warning" && console.error(m.text()));
    await page.goto(`http://127.0.0.1:${port}${PAGE}?width=${WIDTH}&height=${HEIGHT}`, { timeout: 180_000 });
    await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 120_000 });
    const frames = path.join(out, `frames-${look}`);
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
      ([look, scenario]) =>
        (window as unknown as { __fold: { run(look: string, name: string): Promise<unknown> } }).__fold.run(
          look!,
          scenario!,
        ),
      [look, scenario],
    )) as Run;
    await cdp.send("Page.stopScreencast");
    const numbers = measure(run);
    results[look] = numbers ?? { error: "no fold played" };
    console.log(`${look.padEnd(10)} ${JSON.stringify(numbers)}`);
    writeFileSync(path.join(out, `${look}.samples.json`), JSON.stringify(run));
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
      const clip = path.join(out, `fold-${look}.mp4`);
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
          "fps=60,format=yuv420p",
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
      if (made.status !== 0) console.error(`${look}: ffmpeg failed`);
    }
    await page.close();
  }
  writeFileSync(path.join(out, "results.json"), JSON.stringify(results, null, 1));
  await browser.close();
  await vite.close();
}
