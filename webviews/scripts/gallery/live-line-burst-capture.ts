// Before/after evidence for the live line under a burst (Leo, 2026-11-24: "the sending messages in
// rapid succession is really bad looking. it's just your tool call/thinking glimmer text rapidly
// flickering up with very bad/nonexistent fade-in fade-out").
//
// Drives the agent-pane.live-line-burst gallery entry (conversation/LiveLineBurst.gallery.ts) in real
// headless Chromium on the gallery dev server: each look records one loop of its scripted timeline
// (a burst of 30 Thinking and call changes in 2 s, messages sent one after another, a long command)
// as a video, and samples the live line every frame: how many times its words changed, how many rolls
// started, and how many were cut off by the next before they ended.
//
// Usage: bun scripts/gallery/live-line-burst-capture.ts OUT_DIR [--looks a,b] [--busy MS]
// `--busy MS` blocks the main thread MS of every 16 ms frame, as a loaded pane does. `--rate R` plays
// the page's CSS animations at R (0.25 is a quarter speed) to show a roll's shape on video; the dwell's
// timers keep real time, so its counts are read at rate 1 only.
// Writes OUT_DIR/<look>/*.webm and OUT_DIR/report.json, and prints one JSON line per look.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../../test/support/galleryFrame";

const ENTRY = "agent-pane.live-line-burst";
const args = process.argv.slice(2);
const flag = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const outRoot = path.resolve(
  args.find((arg, i) => !arg.startsWith("--") && !args[i - 1]?.startsWith("--")) ?? "live-line-burst-capture",
);
const LOOKS = (flag("--looks") ?? "before,dwell-roll,feather,cross,reduced").split(",");
const busy = Number(flag("--busy") ?? 0);
const rate = Number(flag("--rate") ?? 1);
fs.mkdirSync(outRoot, { recursive: true });

/// One loop of the stage (LiveLineBurstStage BURST_LOOP_MS), and the burst inside it.
const LOOP_MS = 12_000;
const BURST = { from: 3_500, to: 5_600 };

const webviews = path.resolve(import.meta.dir, "../..");
const gallery = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await gallery.listen();
const port = (gallery.httpServer!.address() as { port: number }).port;
const base = `http://127.0.0.1:${port}`;
const browser = await chromium.launch({ headless: true, channel: "chrome" });
await warmGalleryFrame(gallery, ENTRY, { browser, params: { variant: LOOKS[0] } });

const report: Record<string, unknown> = { entry: ENTRY, busyMs: busy, rate, looks: {} };
try {
  for (const look of LOOKS) {
    const dir = path.join(outRoot, look);
    fs.mkdirSync(dir, { recursive: true });
    const context = await browser.newContext({
      viewport: { width: 640, height: 200 },
      deviceScaleFactor: 2,
      colorScheme: "dark",
      recordVideo: { dir, size: { width: 640, height: 200 } },
    });
    const page = await context.newPage();
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
      if (rate !== 1) {
        const cdp = await context.newCDPSession(page);
        await cdp.send("Animation.enable");
        await cdp.send("Animation.setPlaybackRate", { playbackRate: rate });
      }
      await page.goto(`${base}${galleryFrame(ENTRY, { variant: look })}`);
      await page.waitForFunction(
        () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
        undefined,
        { timeout: 120_000 },
      );
      const sampled = await page.evaluate(
        async ({ loopMs, burst, busyMs }) => {
          const clockMs = () =>
            Number.parseFloat(document.querySelector('[data-stage="clock"]')?.textContent ?? "0") * 1000;
          // Start at the top of a loop.
          await new Promise<void>((resolve) => {
            let last = clockMs();
            const tick = () => {
              const now = clockMs();
              if (now < last) resolve();
              else {
                last = now;
                requestAnimationFrame(tick);
              }
            };
            requestAnimationFrame(tick);
          });
          const line = () => document.querySelector("output.cv-thinking");
          let words = line()?.textContent ?? "";
          let roll = line()?.getAttribute("data-roll") ?? "";
          let rollStarted = performance.now();
          const changes: { ms: number; words: string }[] = [];
          let rolls = 0;
          let cut = 0;
          let burstChanges = 0;
          const started = performance.now();
          const rollMs = 80;
          await new Promise<void>((resolve) => {
            const tick = () => {
              const ms = performance.now() - started;
              if (busyMs > 0) {
                const until = performance.now() + busyMs;
                while (performance.now() < until) {
                  // A loaded main thread.
                }
              }
              const nowWords = line()?.textContent ?? "";
              const nowRoll = line()?.getAttribute("data-roll") ?? "";
              if (nowWords.replace(/\d.*$/, "") !== words.replace(/\d.*$/, "")) {
                changes.push({ ms: Math.round(ms), words: nowWords });
                if (ms >= burst.from && ms <= burst.to) burstChanges++;
              }
              if (nowRoll !== roll) {
                rolls++;
                if (performance.now() - rollStarted < rollMs) cut++;
                rollStarted = performance.now();
              }
              words = nowWords;
              roll = nowRoll;
              if (ms >= loopMs) resolve();
              else requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          });
          return { changes: changes.length, burstChanges, rolls, cutRolls: cut, timeline: changes };
        },
        { loopMs: LOOP_MS, burst: BURST, busyMs: busy },
      );
      const line = { look, ...sampled, errors };
      (report.looks as Record<string, unknown>)[look] = line;
      console.log(
        JSON.stringify({
          look,
          changes: sampled.changes,
          burstChanges: sampled.burstChanges,
          rolls: sampled.rolls,
          cutRolls: sampled.cutRolls,
          errors: errors.length,
        }),
      );
    } finally {
      await context.close();
    }
    for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".webm")))
      fs.renameSync(
        path.join(dir, file),
        path.join(
          outRoot,
          `live-line-burst-${look}${busy ? `-busy${busy}` : ""}${rate !== 1 ? `-rate${rate}` : ""}.webm`,
        ),
      );
  }
} finally {
  fs.writeFileSync(path.join(outRoot, "report.json"), JSON.stringify(report, null, 2));
  await browser.close();
  await gallery.close();
}
