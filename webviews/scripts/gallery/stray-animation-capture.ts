// Before/after evidence for Leo's stray transcript animation (ask-d88d4c90f7, 2026-11-22 13:18Z):
// "i scroll down, some bullshit ABOVE folds...? and plays an animation!?"
//
// Drives the agent-pane.stray-animation gallery entry (conversation/strayAnimation.gallery.ts) in
// real headless Chromium on the gallery dev server: each variant loads with `hold=1` (the play
// scrolls the reader down and stops), the script samples the running animations frame by frame
// while the turn ends, records a video of it, and writes a PNG strip of the end's first frames.
//
// Usage: bun scripts/gallery/stray-animation-capture.ts OUT_DIR [--label before|after]
// Writes OUT_DIR/<label>/<variant>/{frame-NNN.png,end.png,*.webm} and OUT_DIR/<label>/report.json,
// and prints one JSON line per variant.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../../test/support/galleryFrame";

const ENTRY = "agent-pane.stray-animation";
const VARIANTS = ["work-above-view", "work-at-top-edge", "work-far-above", "reader-scrolling"];

const args = process.argv.slice(2);
const outRoot = path.resolve(args.find((arg) => !arg.startsWith("--")) ?? "stray-animation-capture");
const labelIndex = args.indexOf("--label");
const label = labelIndex >= 0 ? args[labelIndex + 1]! : "after";
const out = path.join(outRoot, label);
fs.mkdirSync(out, { recursive: true });

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
await warmGalleryFrame(gallery, ENTRY, { browser, params: { variant: VARIANTS[0], hold: 1 } });

/** How long after the turn's end the sampler watches, and how long the video lingers. */
const WATCH_MS = 700;
const report: Record<string, unknown> = { label, entry: ENTRY, variants: {} };

try {
  for (const variant of VARIANTS) {
    const dir = path.join(out, variant);
    fs.mkdirSync(dir, { recursive: true });
    const context = await browser.newContext({
      viewport: { width: 900, height: 640 },
      deviceScaleFactor: 2,
      recordVideo: { dir, size: { width: 900, height: 640 } },
    });
    const page = await context.newPage();
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
      await page.addInitScript(() => localStorage.clear());
      await page.goto(`${base}${galleryFrame(ENTRY, { variant, hold: 1 })}`);
      await page.waitForFunction(
        () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
        undefined,
        { timeout: 120_000 },
      );
      const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
      if (ready !== "1")
        throw new Error(`${variant}: the stage did not mount: ${await page.evaluate(() => document.body.textContent)}`);
      await page.waitForFunction(() => typeof window.cmuxStrayAnimation?.end === "function", undefined, {
        timeout: 30_000,
      });
      // The still the reader sees before the turn ends.
      await page.waitForTimeout(600);
      await page.screenshot({ path: path.join(dir, "frame-000-before-end.png") });

      // End the turn and watch every frame for WATCH_MS: the running animations, where they sit
      // against the scroller's view, and the view's own offset.
      const watched = await page.evaluate(
        async ({ watchMs, wheel }) => {
          const report = window.cmuxStrayAnimation!;
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const frames: {
            ms: number;
            scrollTop: number;
            folding: boolean;
            animations: ReturnType<NonNullable<typeof report.sample>>;
          }[] = [];
          const started = performance.now();
          report.end!();
          await new Promise<void>((resolve) => {
            const tick = () => {
              const ms = performance.now() - started;
              frames.push({
                ms: Math.round(ms),
                scrollTop: node.scrollTop,
                folding: document.querySelector(".acpmux-thread[data-turn-end-folding]") !== null,
                animations: report.sample!(),
              });
              // The reader keeps wheeling while the fold is in flight (endOnReaderScroll).
              if (wheel && ms >= 16 && ms <= 200) {
                node.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, bubbles: true }));
                node.scrollTop += 40;
                node.dispatchEvent(new Event("scroll"));
              }
              if (ms >= watchMs) resolve();
              else requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          });
          return {
            runTopBeforeEnd: report.runTopBeforeEnd,
            runBottomBeforeEnd: report.runBottomBeforeEnd,
            scrollBefore: report.scrollBefore,
            scrollAfterWatch: node.scrollTop,
            frames,
          };
        },
        { watchMs: WATCH_MS, wheel: variant === "reader-scrolling" },
      );
      await page.screenshot({ path: path.join(dir, "frame-999-end.png") });

      const offscreen = watched.frames.flatMap((frame) =>
        frame.animations.filter((each) => !each.inView).map((each) => ({ ms: frame.ms, ...each })),
      );
      const inView = watched.frames.flatMap((frame) => frame.animations.filter((each) => each.inView));
      const scrolls = watched.frames.map((frame) => frame.scrollTop);
      const seen = {
        runTopBeforeEnd: watched.runTopBeforeEnd,
        runBottomBeforeEnd: watched.runBottomBeforeEnd,
        scrollBefore: watched.scrollBefore,
        scrollAfterWatch: watched.scrollAfterWatch,
        frames: watched.frames.length,
        foldingFrames: watched.frames.filter((frame) => frame.folding).length,
        animationFrames: watched.frames.filter((frame) => frame.animations.length > 0).length,
        offscreenAnimationFrames: watched.frames.filter((frame) => frame.animations.some((each) => !each.inView))
          .length,
        offscreenAnimations: offscreen.length,
        offscreenNames: [...new Set(offscreen.map((each) => each.name))].sort(),
        offscreenSample: offscreen.slice(0, 12),
        inViewAnimations: inView.length,
        inViewNames: [...new Set(inView.map((each) => each.name))].sort(),
        // The reader's own offset while the fold ran: a jump here is the fold moving his view.
        scrollMin: Math.min(...scrolls),
        scrollMax: Math.max(...scrolls),
        scrollSteps: [...new Set(scrolls)].length,
        errors,
      };
      (report.variants as Record<string, unknown>)[variant] = seen;
      console.log(JSON.stringify({ label, variant, ...seen, offscreenSample: undefined }));
    } finally {
      await page.close();
      await context.close();
      const videos = fs.readdirSync(dir).filter((name) => name.endsWith(".webm"));
      for (const name of videos) fs.renameSync(path.join(dir, name), path.join(dir, `${label}-${variant}.webm`));
    }
  }
} finally {
  fs.writeFileSync(path.join(out, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  await browser.close();
  await gallery.close();
}
console.log(`wrote ${path.join(out, "report.json")}`);
