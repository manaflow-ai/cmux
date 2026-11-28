// A short preview from the durable journal or its NDJSON export. From webviews/:
// bun scripts/journal-video.ts --session ID preview.webm
// bun scripts/journal-video.ts --fixture test/fixtures/chat-sim/replay-lane-session.ndjson preview.webm
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { playwrightRefusedHere, NO_PLAYWRIGHT_ON_MACS, useSystemChrome } from "../test/support/systemChrome";

const [source, name, output, ...extra] = process.argv.slice(2);
if (!(source === "--fixture" || source === "--session") || !name || !output?.endsWith(".webm") || extra.length)
  throw new Error("expected --session ID or --fixture FILE followed by OUTPUT.webm");
if (playwrightRefusedHere()) throw new Error(NO_PLAYWRIGHT_ON_MACS);
const started = performance.now();
const rust = path.resolve(import.meta.dir, "../../cmux-tui");
const input = source === "--fixture" ? path.resolve(name) : name;
const plan = spawnSync(
  "cargo",
  ["run", "--locked", "-q", "-p", "acpmux", "--example", "journal_video", "--", source, input],
  {
    cwd: rust,
    stdio: ["ignore", "pipe", "inherit"],
    encoding: "utf8",
    maxBuffer: 8 << 20,
  },
);
if (plan.status !== 0) throw plan.error ?? new Error("could not prepare the journal preview");
type Screen = { status: string; prompt: string; reply: string; tool: string };
type Shot = { frame: number; transition: { seq: number; state: Screen } };
const { work, durationMs, visualTransitions, fps, frames, shots } = JSON.parse(plan.stdout) as {
  work: { reduced: number; largest_page: number };
  durationMs: number;
  visualTransitions: number;
  fps: number;
  frames: number;
  shots: Shot[];
};
useSystemChrome(chromium);
const browser = await chromium.launch({ headless: true });
const dir = mkdtempSync(path.join(tmpdir(), "journal-video-"));
try {
  const page = await browser.newPage({ viewport: { width: 960, height: 720 } });
  await page.setContent(`<meta charset="utf-8"><style>
    body{margin:48px;background:#14171b;color:#edf0f3;font:22px/1.42 system-ui}
    header{color:#a9b4bd;font-size:18px} section{margin-top:24px}
    h2{font-size:15px;color:#9faebc;margin:0 0 5px} p{margin:0;white-space:pre-wrap;overflow-wrap:anywhere;
    display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:5;overflow:hidden}
    #tool{font:18px/1.4 monospace}
    </style><header>Session replay · <span id="status"></span></header>
    <section><h2>Prompt</h2><p id="prompt"></p></section>
    <section><h2>Reply</h2><p id="reply"></p></section>
    <section><h2>Tool</h2><p id="tool"></p></section>`);
  const entries: string[] = [];
  for (const [i, shot] of shots.entries()) {
    await page.evaluate((state) => {
      for (const [field, value] of Object.entries(state)) document.getElementById(field)!.textContent = value;
    }, shot.transition.state);
    const file = `frame-${i}.png`;
    await page.screenshot({ path: path.join(dir, file) });
    entries.push(`file '${file}'`, `duration ${((shots[i + 1]?.frame ?? frames) - shot.frame) / fps}`);
  }
  // concat needs a following image to honor the final duration. Limit output to the scheduled frames.
  entries.push(`file 'frame-${shots.length - 1}.png'`);
  writeFileSync(path.join(dir, "frames.txt"), entries.join("\n") + "\n");
  const encoded = spawnSync(
    process.env.CHAT_SIM_FFMPEG || "ffmpeg",
    [
      "-v",
      "error",
      "-y",
      "-f",
      "concat",
      "-safe",
      "1",
      "-i",
      path.join(dir, "frames.txt"),
      "-vf",
      `fps=${fps}`,
      "-frames:v",
      String(frames),
      "-c:v",
      "libvpx",
      "-b:v",
      "2M",
      "-pix_fmt",
      "yuv420p",
      path.resolve(output),
    ],
    { stdio: "inherit" },
  );
  if (encoded.status !== 0) throw encoded.error ?? new Error("WebM encoding failed");
  console.log(
    JSON.stringify({
      source,
      name,
      work,
      durationMs,
      visualTransitions,
      fps,
      frames,
      rendered: shots.length,
      first: shots[0]?.transition.seq,
      last: shots.at(-1)?.transition.seq,
      width: 960,
      height: 720,
      codec: "libvpx",
      bitrate: "2M",
      wallMs: performance.now() - started,
      bytes: statSync(output).size,
    }),
  );
} finally {
  await browser.close();
  rmSync(dir, { recursive: true, force: true });
}
