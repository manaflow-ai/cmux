// l10n-allow-file: a developer tool's captions and output, not shipped UI.
// Turns the films `VIDEO=DIR bun bench/first-load-after-restart.bench.ts` writes (DIR/<mode>.webm with
// DIR/<mode>.json) into mp4s with the perceived times drawn under the chat: a clock from navigation, the stage
// on screen now, and a timeline marking when the chat became visible (first content), when its composer took
// typing, and when it settled. Leo, 2026-11-23: "lawrence wanted to see a video of it. i think he's probably
// wanting to make sure it looks good and it's not just some placeholder lookng weird nub that goes up. so, right
// in line with what i was saying, like just perceived time to visible/settled and percieved interactive time".
//
//   bun scripts/restart-video.ts DIR [--speed 1,0.25] [--fps 30] [--tail-ms 800] [--ffmpeg PATH]
//
// Each output frame seeks the film to its time and screenshots a page holding the film and the caption bar, so the
// clock is the film's own time, not the encoder's. Writes DIR/<mode>.mp4 (speed 1) and DIR/<mode>-x0.25.mp4 per
// slower speed, plus DIR/<mode>-<stage>.png at each mark. Needs an ffmpeg with libx264 (FFMPEG or --ffmpeg).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { chromium } from "../bench/browsers";

type Marks = {
  mode: string;
  video: string;
  navigationInVideoMs: number;
  viewport: { width: number; height: number };
  turns: number;
  downMs: number;
  cpu: number;
  pages: number;
  firstContentMs: number | null;
  copyShownMs: number | null;
  interactiveMs: number | null;
  swapMs: number | null;
  liveMs: number | null;
  settledMs: number | null;
  shifts: number;
  recordMs: number;
};

const args = process.argv.slice(2);
const dir = args.find((arg) => !arg.startsWith("--") && !args[args.indexOf(arg) - 1]?.startsWith("--"));
if (!dir) throw new Error("usage: bun scripts/restart-video.ts DIR [--speed 1,0.25] [--fps 30] [--tail-ms 800]");
const flag = (name: string, fallback: string) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 && args[at + 1] ? args[at + 1]! : fallback;
};
const SPEEDS = flag("speed", "1,0.25").split(",").map(Number);
const FPS = Number(flag("fps", "30"));
const TAIL_MS = Number(flag("tail-ms", "800"));
const FFMPEG = flag("ffmpeg", process.env.FFMPEG ?? "ffmpeg");
const BAR = 118;

/// What the mode simulates, in words for the caption.
const SCENES: Record<string, string> = {
  down: "restart after an update: acpmux down",
  "slow-init": "restart: acpmux slow to answer",
  "native-ready": "restart: app's native ready waits",
  "native-ready-tail": "restart: no saved copy, kept tail only",
  refused: "restart: host refuses until acpmux is back",
  "refused-no-copy": "restart: refused, no saved copy",
};

const marksOf = (file: string): Marks => JSON.parse(fs.readFileSync(file, "utf8")) as Marks;
const films = fs
  .readdirSync(dir)
  .filter((name) => name.endsWith(".json"))
  .map((name) => marksOf(path.join(dir, name)))
  .filter((marks) => fs.existsSync(path.join(dir, marks.video)));
if (!films.length) throw new Error(`no <mode>.json beside a <mode>.webm in ${dir}`);

const page_html = (marks: Marks) => `<!doctype html><meta charset="utf-8"><style>
  html, body { margin: 0; background: #111; color: #eee; font: 15px/1.3 -apple-system, "Inter", "Segoe UI", sans-serif; }
  video { display: block; width: ${marks.viewport.width}px; height: ${marks.viewport.height}px; background: #000; }
  .bar { height: ${BAR}px; box-sizing: border-box; padding: 12px 20px; border-top: 1px solid #333; }
  .top { display: flex; align-items: baseline; gap: 18px; }
  .clock { font: 600 30px/1 ui-monospace, "JetBrains Mono", Menlo, monospace; min-width: 190px; }
  .stage { font-weight: 600; padding: 3px 10px; border-radius: 6px; background: #333; }
  .scene { margin-left: auto; color: #aaa; font-size: 13px; }
  .line { position: relative; height: 34px; margin-top: 14px; }
  .track { position: absolute; left: 0; right: 0; top: 6px; height: 4px; background: #333; border-radius: 2px; }
  .fill { position: absolute; left: 0; top: 6px; height: 4px; background: #6aa9ff; border-radius: 2px; }
  .mark { position: absolute; top: 0; width: 2px; height: 16px; }
  .mark span { position: absolute; top: 18px; left: -4px; white-space: nowrap; font-size: 12px; }
</style>
<video src="${marks.video}" muted preload="auto"></video>
<div class="bar"><div class="top"><div class="clock" id="clock"></div><div class="stage" id="stage"></div>
<div class="scene">${SCENES[marks.mode] ?? marks.mode} ${marks.downMs} ms · ${marks.turns} turns · offline, no agent${marks.cpu > 1 ? ` · CPU ×${marks.cpu}` : ""}${marks.pages > 1 ? ` · ${marks.pages} pages` : ""}</div></div>
<div class="line" id="line"><div class="track"></div><div class="fill" id="fill"></div></div></div>`;

type Stage = { at: number; name: string; label: string; color: string };
const stagesOf = (marks: Marks): Stage[] =>
  (
    [
      { at: marks.firstContentMs, name: "visible", label: "visible", color: "#f2c94c" },
      { at: marks.interactiveMs, name: "interactive", label: "takes typing", color: "#6fcf97" },
      { at: marks.settledMs, name: "settled", label: "settled", color: "#6aa9ff" },
    ] as const
  )
    .filter((stage): stage is Stage => stage.at !== null)
    .map((stage) => ({ ...stage, at: Math.round(stage.at) }))
    .sort((a, b) => a.at - b.at);

const browser = await chromium.launch();
try {
  for (const marks of films) {
    const stages = stagesOf(marks);
    const endMs = Math.max(...stages.map((stage) => stage.at), marks.firstContentMs ?? 0) + TAIL_MS;
    const startMs = -Math.min(150, marks.navigationInVideoMs);
    const html = path.join(dir, `.${marks.mode}.view.html`);
    fs.writeFileSync(html, page_html(marks));
    const page = await browser.newPage({
      viewport: { width: marks.viewport.width, height: marks.viewport.height + BAR },
    });
    await page.goto(`file://${path.resolve(html)}`);
    await page.waitForFunction(() => (document.querySelector("video") as HTMLVideoElement).readyState >= 2);
    const filmMs = await page.evaluate(() => (document.querySelector("video") as HTMLVideoElement).duration * 1000);
    await page.evaluate(
      ({ stages, startMs, endMs }) => {
        const line = document.getElementById("line")!;
        for (const stage of stages) {
          const mark = document.createElement("div");
          mark.className = "mark";
          mark.style.left = `${((stage.at - startMs) / (endMs - startMs)) * 100}%`;
          mark.style.background = stage.color;
          mark.innerHTML = `<span style="color:${stage.color}">${stage.label} ${stage.at} ms</span>`;
          line.append(mark);
        }
      },
      { stages, startMs, endMs },
    );
    const frames = fs.mkdtempSync(path.join(os.tmpdir(), `restart-video-${marks.mode}-`));
    let count = 0;
    const shot = async (t: number, file: string) => {
      await page.evaluate(
        async ({ seconds, t, startMs, endMs, stages }) => {
          const video = document.querySelector("video") as HTMLVideoElement;
          if (Math.abs(video.currentTime - seconds) > 0.0005) {
            const seeked = new Promise((resolve) => video.addEventListener("seeked", resolve, { once: true }));
            video.currentTime = seconds;
            await seeked;
          }
          document.getElementById("clock")!.textContent = `${t < 0 ? "−" : ""}${Math.abs(Math.round(t))} ms`;
          const now = [...stages].reverse().find((stage) => t >= stage.at);
          const stage = document.getElementById("stage")!;
          stage.textContent = now ? now.label : t < 0 ? "launching" : "loading";
          stage.style.background = now ? now.color : "#333";
          stage.style.color = now ? "#111" : "#eee";
          document.getElementById("fill")!.style.width = `${Math.max(0, ((t - startMs) / (endMs - startMs)) * 100)}%`;
        },
        { seconds: Math.min(filmMs - 1, marks.navigationInVideoMs + t) / 1000, t, startMs, endMs, stages },
      );
      await page.screenshot({ path: file });
    };
    // Every film frame once, at the film's own times (Playwright films at 25 fps): a speed's output repeats them.
    const step = 1000 / FPS;
    for (const speed of SPEEDS) {
      const out = path.join(dir, speed === 1 ? `${marks.mode}.mp4` : `${marks.mode}-x${speed}.mp4`);
      const sub = path.join(frames, `s${speed}`);
      fs.mkdirSync(sub);
      let index = 0;
      for (let t = startMs; t <= endMs; t += step * speed)
        await shot(t, path.join(sub, `${String(index++).padStart(5, "0")}.png`));
      count += index;
      const run = spawnSync(
        FFMPEG,
        [
          "-y",
          "-loglevel",
          "error",
          "-framerate",
          String(FPS),
          "-i",
          path.join(sub, "%05d.png"),
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-crf",
          "20",
          out,
        ],
        { stdio: "inherit" },
      );
      if (run.status !== 0) throw new Error(`ffmpeg failed for ${out}`);
      console.log(`restart-video [${marks.mode}]: ${out} (${index} frames, ×${speed})`);
    }
    for (const stage of stages) await shot(stage.at, path.join(dir, `${marks.mode}-${stage.name}.png`));
    console.log(
      `restart-video [${marks.mode}]: ${stages.map((stage) => `${stage.label} ${stage.at} ms`).join(", ")}; navigation at ${marks.navigationInVideoMs} ms into the film; ${count} frames`,
    );
    fs.rmSync(frames, { recursive: true, force: true });
    fs.rmSync(html);
    await page.close();
  }
} finally {
  await browser.close();
}
