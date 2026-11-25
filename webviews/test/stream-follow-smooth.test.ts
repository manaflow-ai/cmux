// cmux-web-test-timeout: 900
// The followed transcript while a long Claude reply streams and its tool calls land and fold, per
// follow-motion arm, at 60 Hz (Leo, 2026-11-22: "i also feel like the animation or whatever for when
// im at the bottom and the text is streaming to be a bit jarring ... it's just not great design to
// have the jolts. esp in tandem with how aggressively we're folding claude code chats. it's not
// smooth."). The page (browser/send-stream-motion.harness.tsx) plays the fold-stream turn
// (scriptedTurn.ts) at Claude's cadence, 16 characters every 50 ms, on the frames' own clock at 60 Hz,
// with the Claude harness family's folds; each frame is sampled after its layout. The report
// (support/streamFollowReport.ts) counts the frames whose scroll offset, or whose newest reply text
// where it paints, moved past half a line, per second, and the largest such move.
//
// A measurement, not a gate: it runs only with CMUX_STREAM_FOLLOW=1 (the numbers in the PR), e.g.
//   cmux-ci test -- bash -c 'cd webviews && CMUX_STREAM_FOLLOW=1 bun test test/stream-follow-smooth.test.ts'
// CMUX_STREAM_FOLLOW_ARMS picks the arms (comma list, default below); CMUX_STREAM_FOLLOW_CLIPS=DIR
// writes each arm's frames there and, with ffmpeg on PATH, an MP4 per arm.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Sample } from "./browser/send-stream-motion.harness";
import { streamFollowReport, type StreamFollowReport } from "./support/streamFollowReport";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { warmViteServer } from "./support/warmDevServer";

const ON = process.env.CMUX_STREAM_FOLLOW === "1";
const ARMS = (process.env.CMUX_STREAM_FOLLOW_ARMS ?? "send,blocks,linear,steady").split(",").filter(Boolean);
const CLIPS = process.env.CMUX_STREAM_FOLLOW_CLIPS;
const FPS = 60;

describe.skipIf(!ON)("stream follow while tool calls fold (CMUX_STREAM_FOLLOW=1)", () => {
  setDefaultTimeout(240_000);
  const PAGE = "/test/browser/send-stream-motion.html";
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  beforeAll(async () => {
    try {
      await (await open120Hz("about:blank")).close();
    } catch (error) {
      if (error instanceof FramesUnsupported)
        throw new Error("needs chrome-headless-shell (CMUX_CHROME_HEADLESS_SHELL)");
      throw error;
    }
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-stream-follow-smooth"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  async function measure(arm: string, extra = ""): Promise<StreamFollowReport> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const clipDir = CLIPS ? path.join(CLIPS, `${arm}${extra ? `-${extra.replace(/[^a-z0-9]+/gi, "-")}` : ""}`) : "";
    const frames: (string | undefined)[] = [];
    const query = `clock=frames&fps=${FPS}&family=claude&arm=${arm}${extra ? `&${extra}` : ""}`;
    const driver = await open120Hz(`http://127.0.0.1:${port}${PAGE}?${query}`, {
      clock: "frames",
      frameMs: 1000 / FPS,
      viewport: { width: 720, height: 640 },
      ...(clipDir && { screenshot: (jpeg: string | undefined) => frames.push(jpeg) }),
    });
    try {
      await driver.page.waitForFunction(() => "__sendStream" in window);
      await driver.page.getByText("History answer 6.").waitFor();
      driver.start();
      const samples = (await driver.page.evaluate(() =>
        (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
          scenario: "fold-stream",
          chars: 16,
          everyMs: 50,
          settleMs: 900,
        }),
      )) as Sample[];
      await driver.stop();
      if (clipDir) writeClip(clipDir, frames);
      return streamFollowReport(samples);
    } finally {
      await driver.close();
    }
  }

  const reports: Record<string, StreamFollowReport> = {};
  for (const arm of ARMS)
    for (const extra of ["", "liveTurnWork=runs"])
      test(`${arm}${extra ? ` ${extra}` : ""}`, async () => {
        const report = await measure(arm, extra);
        reports[`${arm}${extra ? ` ${extra}` : ""}`] = report;
        console.log(`stream-follow-smooth ${arm} ${extra || "default"}: ${JSON.stringify(report)}`);
        expect(report.frames).toBeGreaterThan(FPS * 3);
      });

  test("table", () => {
    const lines = ["| arm | reader jolts/s | reader max px | reader jerk p95 | scroll jolts/s | scroll max px |"];
    lines.push("|---|---|---|---|---|---|");
    for (const [name, report] of Object.entries(reports))
      lines.push(
        `| ${name} | ${report.reader.joltsPerS} | ${report.reader.maxPx} | ${report.reader.jerkP95Px} | ${report.scroll.joltsPerS} | ${report.scroll.maxPx} |`,
      );
    console.log(lines.join("\n"));
    if (CLIPS) writeFileSync(path.join(CLIPS, "report.json"), JSON.stringify(reports, null, 2));
  });
});

/// Every frame as a JPEG (a frame that drew nothing new repeats the last), and an MP4 when ffmpeg is here.
function writeClip(dir: string, frames: (string | undefined)[]) {
  mkdirSync(dir, { recursive: true });
  let last: string | undefined;
  let index = 0;
  for (const frame of frames) {
    last = frame ?? last;
    if (!last) continue;
    writeFileSync(path.join(dir, `frame-${String(index).padStart(5, "0")}.jpg`), Buffer.from(last, "base64"));
    index += 1;
  }
  const ffmpeg = Bun.which("ffmpeg");
  if (!ffmpeg || index === 0) return;
  Bun.spawnSync([
    ffmpeg,
    "-y",
    "-loglevel",
    "error",
    "-framerate",
    String(FPS),
    "-i",
    path.join(dir, "frame-%05d.jpg"),
    "-pix_fmt",
    "yuv420p",
    "-vf",
    "scale=trunc(iw/2)*2:trunc(ih/2)*2",
    `${dir}.mp4`,
  ]);
}
