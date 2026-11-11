// cmux-web-test-timeout: 300
// The composer hat's own leave, after Leo, 2026-11-08: "i also feel like the hat auto removing/auto
// hiding stuff that's super done is maybe a bit jarring? we can maybe increase the ttl just a tad/not
// remove it for a bit if the user recently looked at it". When the hat's last line expires, the hat
// goes from the floating bottom stack (.acpmux-dock) over the composer. It used to unmount at once
// while a copy faded over the stack, so the stack lost the hat's whole height in one frame: the top
// of the stack, and the transcript laid out over it, jumped. Now the copy stands in the hat's place
// and folds its height away as it fades (trayMotionModel.ts `playTrayExit`, subagents.css
// `acpmux-tray-leave`), so the stack's top moves over many frames.
//
// On the gallery stage (agent-pane.composer-hat-linger, `last-leaves`: one running command, a 1 s
// grace), the command finishes and the pointer stays off the hat; a per-frame sampler
// reads the stack's height and top and the composer's top after every painted frame until the hat and its copy
// are gone. The stack loses exactly the hat's height, it takes at least 70% of the leave's
// own length (read from the leaving copy: the settle token, 180 ms) of wall time from its full height
// to its final one with at least two painted heights in between (frame-rate independent: headless
// WebKit paints sparse frames), and the composer never moves. With Reduce Motion the hat goes in one
// step (folds snap). The samples are printed, for the PR.
//
// Real Chromium and WebKit. CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-hat-leave-fold.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-leave-fold.test.ts", async () => {
  /// The index of the last item that passes `test`, or -1 (the type check's lib has no findLastIndex).
  function lastIndex<T>(items: readonly T[], test: (item: T) => boolean): number {
    for (let index = items.length - 1; index >= 0; index -= 1) if (test(items[index]!)) return index;
    return -1;
  }

  // How much of the leave's own length the stack must take from its full height to its final one.
  // The copy folds on the house settle, cubic-bezier(0.16, 1, 0.3, 1), which is front-loaded: of the
  // 28 px hat 0.121 px is left 70% into the animation (126 ms of the 180 ms) and 0.0625 px at 75.3%
  // (135.5 ms). Layout heights are in 1/64 px steps, so a height reads "final" (within this file's
  // 0.05 px) when less than 0.0625 px is left: a fold that plays whole reads 135.5 ms or more, and
  // the frame grid only adds to that (the last full frame is at or before the start, the first final
  // frame at or after that point). One cut short (the copy removed early, the jump this replaces)
  // reads less. 70% leaves 9.5 ms for a frame time that the engine rounds. The bound was a literal
  // 150 ms, which is what 60.0 Hz reads with no margin: 9 frames of 16.67 ms, as a sum of doubles
  // 149.99999999999977 on Chromium, and 9 frames of 16.1 ms = 145 ms on the lane's WebKit, each a
  // whole fold. A hat under 14.5 px would settle sooner than this share.
  const FOLD_SHARE = 0.7;
  // Frame times are doubles: a span that equals the bound may read a few ulps under it.
  const CLOCK_SLACK_MS = 0.001;

  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.composer-hat-linger";
  const VARIANT = "last-leaves";
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-hat-leave-fold: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer hat leave fold", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  // The frame answers prefers-reduced-motion from its own `reducedMotion` setting (gallery/frame/media.ts
  // overrides window.matchMedia and the stylesheets' @media rules), not from the browser's emulation.
  const stageURL = (reduce: boolean) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: VARIANT, reducedMotion: reduce ? 1 : undefined })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, ENTRY, {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: VARIANT },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Sample = {
    at: number;
    dock: number;
    dockTop: number;
    composerTop: number;
    tray: number | null;
    ghost: boolean;
    /// The leaving copy's own animation length (ms) as the page resolves it, once the copy is drawn.
    leaveMs: number | null;
    /// The leaving copy's `animation-name` (`none` = the copy plays no animation).
    leaveName: string | null;
  };

  /// Finishes the command, takes the pointer off the hat, and samples every frame until the hat and
  /// its copy have been gone for a few frames.
  async function leave(engine: string, reduce: boolean) {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 480 } });
    if (reduce) await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(stageURL(reduce));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-running-tray:not(.acpmux-running-tray--ghost)").waitFor();
    await page.click('[data-stage="finish"]');
    // Under the pointer the hat is held and nothing expires: a stage button, outside the pane.
    await page.hover('[data-stage="fail"]');
    await installPaintedFrames(page);
    const samples = await page.evaluate(
      () =>
        new Promise<Sample[]>((resolve, reject) => {
          const out: Sample[] = [];
          let goneFor = 0;
          let leaveMs: number | null = null;
          let leaveName: string | null = null;
          const until = performance.now() + 8_000;
          // Each painted frame's state, read after it paints (support/paintedFrames.ts).
          window.cmuxAfterPaint((at) => {
            const dock = document.querySelector<HTMLElement>("main.acpmux-main[data-dock=float] > .acpmux-dock")!;
            const composer = document.querySelector<HTMLElement>(".acpmux-composer")!;
            const tray = dock.querySelector<HTMLElement>(".acpmux-running-tray:not(.acpmux-running-tray--ghost)");
            const copy = dock.querySelector(".acpmux-running-tray--ghost");
            const ghost = copy !== null;
            // The leave's name and length, read once from the copy (subagents.css `--acpmux-tray-leave`).
            if (copy && leaveMs === null) {
              const style = getComputedStyle(copy);
              const length = style.animationDuration.split(",")[0]!.trim();
              leaveMs = Number.parseFloat(length) * (length.endsWith("ms") ? 1 : 1000);
              leaveName = style.animationName.split(",")[0]!.trim();
            }
            const box = dock.getBoundingClientRect();
            out.push({
              at,
              dock: box.height,
              dockTop: box.top,
              composerTop: composer.getBoundingClientRect().top,
              tray: tray ? tray.getBoundingClientRect().top : null,
              ghost,
              leaveMs,
              leaveName,
            });
            goneFor = tray || ghost ? 0 : goneFor + 1;
            if (goneFor >= 6) {
              resolve(out);
              return false;
            }
            if (performance.now() > until) {
              reject(new Error("the hat did not leave within 8 s"));
              return false;
            }
            return true;
          });
        }),
    );
    await page.close();
    // From the last frame the real hat was laid out: what it took in the stack, then the drop.
    const last = lastIndex(samples, (sample) => sample.tray !== null);
    expect(last, "the hat was on screen before it left").toBeGreaterThanOrEqual(0);
    const before = samples[last]!;
    const hat = before.composerTop - before.tray!;
    const tail = samples.slice(last);
    const steps = tail.slice(1).map((sample, index) => tail[index]!.dock - sample.dock);
    const total = before.dock - samples.at(-1)!.dock;
    const moving = steps.filter((step) => Math.abs(step) > 0.5).length;
    const largest = Math.max(0, ...steps.map(Math.abs));
    // Frame-rate independent: how long the stack took from its full height to its final one (the
    // last full frame to the first final frame), and how many painted frames stood in between.
    const full = before.dock;
    const final = samples.at(-1)!.dock;
    const lastFull = lastIndex(tail, (sample) => sample.dock >= full - 0.05);
    const firstFinal = tail.findIndex((sample) => sample.dock <= final + 0.05);
    const spanMs = tail[firstFinal]!.at - tail[lastFull]!.at;
    const between = tail.filter((sample) => sample.dock < full - 0.05 && sample.dock > final + 0.05).length;
    const composerMoves = Math.max(...samples.map((sample) => Math.abs(sample.composerTop - samples[0]!.composerTop)));
    const read = samples.find((sample) => sample.leaveMs !== null);
    const leaveMs = read?.leaveMs ?? null;
    const leaveName = read?.leaveName ?? null;
    console.log(
      `composer-hat-leave-fold ${engine}${reduce ? " (Reduce Motion)" : ""}: hat ${hat.toFixed(1)} px, total drop ${total.toFixed(1)} px, largest step ${largest.toFixed(1)} px, ${moving} frames moving, ${between} heights between, ${spanMs.toFixed(0)} ms full to final${leaveMs === null ? "" : ` of a ${leaveMs.toFixed(0)} ms leave`}, composer moved ${composerMoves.toFixed(1)} px`,
    );
    console.log(
      `  per frame (ms, dock height, dock top, ghost): ${tail.map((sample) => `+${(sample.at - before.at).toFixed(0)}:${sample.dock.toFixed(1)}/${sample.dockTop.toFixed(1)}${sample.ghost ? "g" : ""}`).join(" ")}`,
    );
    return {
      samples,
      hat,
      total,
      largest,
      moving,
      between,
      spanMs,
      leaveMs,
      leaveName,
      composerMoves,
      ghosted: samples.some((sample) => sample.ghost),
    };
  }

  for (const [engine] of engines) {
    test(`${engine}: the hat's last line goes and the hat folds away over many frames`, async () => {
      const run = await leave(engine, false);
      expect(run.hat, "the hat took room in the stack").toBeGreaterThan(0);
      expect(Math.abs(run.total - run.hat), "the stack loses exactly the hat's height").toBeLessThanOrEqual(1);
      // Headless WebKit paints sparse frames and the settle is front-loaded, so this counts wall time
      // and heights in between, not frames: the jump this replaces went from full to 0 in one frame.
      // A copy with no animation reads `none` and 0 ms; without these two the bound below is 0.
      expect(run.leaveName ?? "none", "the leaving copy has an animation").not.toBe("none");
      expect(run.leaveMs ?? 0, "the leaving copy's animation has a length above zero").toBeGreaterThan(0);
      const least = FOLD_SHARE * run.leaveMs!;
      expect(
        run.spanMs,
        `the stack takes at least ${least} ms (${FOLD_SHARE} of its ${run.leaveMs} ms leave) from full to final`,
      ).toBeGreaterThanOrEqual(least - CLOCK_SLACK_MS);
      expect(run.between, "at least two painted heights between full and final").toBeGreaterThanOrEqual(2);
      expect(run.composerMoves, "the composer never moves").toBeLessThanOrEqual(0.5);
    });

    test(`${engine}: with Reduce Motion the hat goes in one step`, async () => {
      const run = await leave(engine, true);
      expect(run.hat, "the hat took room in the stack").toBeGreaterThan(0);
      expect(Math.abs(run.total - run.hat), "the stack loses exactly the hat's height").toBeLessThanOrEqual(1);
      expect(run.ghosted, "no copy plays under Reduce Motion").toBe(false);
      expect(run.moving, "one step").toBe(1);
      expect(run.composerMoves, "the composer never moves").toBeLessThanOrEqual(0.5);
    });
  }
});
