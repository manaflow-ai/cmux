// cmux-web-test-timeout: 900
// l10n-allow-file: the harness's report keys and typed fixture text, not shipped UI.
// Leo, 2026-11-22: "you guys also need to be testing flicks of extremely fast input for scrolling and
// resizing/mouse movement and typing/pasting/switching workspaces around. we need to test like power
// users more often." And on layout: "IF IT NEEDS TO SHIFT, IT SHIFTS ... GRACEFULLY ... MATHEMATICALLY,
// ALL OF THESE SHOULD BE FLAGGABLE", "EVERY POSSIBLE CASE, NO MATTER HOW WILD".
//
// The power-user input stress harness. The real agent pane on `?mock`, three seeded chats, a reply
// streaming the whole time, and a seeded run of overlapping bursts (powerUserBursts.ts `planRun`):
// wheel flicks and trackpad momentum (mostly up, through history, while the reply streams), window
// resizes, pointer sweeps, typing at 15-60 keys a second, pastes of 2 KB to 600 KB of text and of
// screenshots up to 3456x2234, chat switches 0-140 ms apart, and sends with a switch right after.
// Every painted frame is read (paintedFrames.ts) for:
//   - frame time (p95, p99, frames over 50 ms) and input event to the next painted frame;
//   - caret lag: key press to the frame its character paints (perf.ts's typing samples);
//   - dropped or reordered keys: the draft against what was typed;
//   - layout shift: the gallery's per-frame box tracker and follow judge (shift.ts, followJudge.ts),
//     the same detector the scenario fuzzer reads; a stray move over 1 px the input did not cause;
//   - blank or flashing panes: a frame with no composer or transcript, or with over half the
//     transcript's view empty;
//   - console errors and uncaught page errors.
// It prints one `POWER-USER {json}` line per engine and seed with the numbers per input class and every
// breach, writes the same JSON to $FAST_CHECKS_OUT, and fails on a breach not listed in KNOWN. Timing breaches
// (TIMING_WHATS) are reported, not failed, unless POWER_USER_GATE_TIMING=1: the nightly perf-cron rows track them.
//
// Replay a breach: POWER_USER_SEED=<seed> POWER_USER_WAVES=<waves> bun test test/power-user-bursts.browser.test.ts
// Env: POWER_USER_SEED (comma list; `random` picks one and prints it), POWER_USER_WAVES (default 24),
// POWER_USER_REPORT_ONLY=1 (print, never fail), POWER_USER_ENGINES (default chromium,webkit), POWER_USER_BUDGET_S
// (default 120: the wall-clock seconds one engine and seed may take; the waves past it are not run).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import {
  classNumbers,
  draftDiff,
  judge,
  LAYOUT_KINDS,
  percentile,
  planRun,
  reversalFromWheel,
  TIMING_WHATS,
  knownBreach,
  type Baseline,
  type Breach,
  type Burst,
  type BurstKind,
  type BurstRecord,
} from "./support/powerUserBursts";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type PageRecord = {
  frameMs: number[];
  inputs: { type: string; ms: number }[];
  blankFrames: number;
  blanks: string[];
};

await requireBrowserLane("power-user-bursts.browser.test.ts", async () => {
  setDefaultTimeout(840_000);
  const OUT = process.env.FAST_CHECKS_OUT;
  const WAVES = Math.max(1, Number(process.env.POWER_USER_WAVES) || 24);
  const REPORT_ONLY = process.env.POWER_USER_REPORT_ONLY === "1";
  const GATE_TIMING = process.env.POWER_USER_GATE_TIMING === "1";
  /// The wall-clock budget for one engine and seed's waves (the CI time budget): waves past it are not run, and the
  /// report says how many ran, so a replay passes the same POWER_USER_WAVES.
  const BUDGET_S = Number(process.env.POWER_USER_BUDGET_S) || 120;
  const seeds = (process.env.POWER_USER_SEED || "20261122")
    .split(",")
    .map((value) => (value.trim() === "random" ? Math.floor(Math.random() * 2 ** 31) : Number(value)))
    .filter(Number.isFinite);
  const wanted = (process.env.POWER_USER_ENGINES || "chromium,webkit").split(",");
  const engines = (
    [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as [string, BrowserType][]
  ).filter(([name]) => wanted.includes(name));
  const WIDTH = 1100;
  const HEIGHT = 800;

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let pane: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await pane.listen();
    for (const [name, engine] of engines) {
      try {
        browsers.set(name, await engine.launch({ headless: true, timeout: 30_000 }));
      } catch (error) {
        if (process.env.GITHUB_ACTIONS === "true") throw error;
        console.warn(`power-user-bursts: ${name} cannot launch here, skipped`);
      }
    }
    await warmViteServer(pane, "/?mock");
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /** Waits `ms` in the page: the gap between two inputs of a burst. */
  const gap = (page: Page, ms: number) =>
    // fixed-wait: the gap between a burst's inputs is the stimulus itself (a hand's pace), not a wait for state.
    ms > 0 ? page.evaluate((ms) => new Promise((resolve) => setTimeout(resolve, ms)), ms) : Promise.resolve();

  /** Two painted frames: what the last input did has drawn. */
  const painted = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });

  /** The page's frame and input recorder (installed once per page; `take` reads and clears it). */
  const installRecorder = (page: Page) =>
    page.evaluate(() => {
      const w = window as any;
      const state = {
        frameMs: [] as number[],
        inputs: [] as { type: string; ms: number }[],
        blankFrames: 0,
        blanks: [] as string[],
        // The signs of the wheel deltas before each painted frame since the shift detector started.
        wheels: [] as number[][],
      };
      const pending: { type: string; at: number }[] = [];
      let wheelSigns: number[] = [];
      let last = 0;
      for (const type of ["wheel", "keydown", "pointermove", "paste"])
        addEventListener(
          type,
          (event) => {
            pending.push({ type, at: event.timeStamp });
            if (event instanceof WheelEvent && event.deltaY !== 0) wheelSigns.push(Math.sign(event.deltaY));
          },
          { capture: true, passive: true },
        );
      const blank = (why: string) => {
        state.blankFrames += 1;
        if (state.blanks.length < 6) state.blanks.push(why);
      };
      w.cmuxAfterPaint((frame: number) => {
        if (last > 0) state.frameMs.push(frame - last);
        last = frame;
        state.wheels.push(wheelSigns);
        wheelSigns = [];
        const now = performance.now();
        for (const input of pending.splice(0)) state.inputs.push({ type: input.type, ms: now - input.at });
        // A pane that draws nothing, or a transcript that leaves over half its view empty.
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const composer = document.querySelector(".acpmux-composer-box");
        if (!scroller || !composer) {
          blank(`${scroller ? "" : "no transcript "}${composer ? "" : "no composer"} at ${innerWidth}x${innerHeight}`);
          return;
        }
        const view = scroller.getBoundingClientRect();
        if (view.height < 40) return;
        const spans = [...scroller.querySelectorAll<HTMLElement>("[data-row-id]")]
          .map((row) => row.getBoundingClientRect())
          .filter((box) => box.height > 0 && box.bottom > view.top && box.top < view.bottom)
          .map((box) => [Math.max(view.top, box.top), Math.min(view.bottom, box.bottom)] as const)
          .sort((a, b) => a[0] - b[0]);
        const end = Math.min(view.bottom, view.top + scroller.scrollHeight - scroller.scrollTop);
        let empty = 0;
        let reach = view.top;
        for (const [top, bottom] of spans) {
          empty = Math.max(empty, top - reach);
          reach = Math.max(reach, bottom);
        }
        empty = Math.max(empty, end - reach);
        if (empty > view.height / 2)
          blank(
            `transcript ${Math.round(empty)} of ${Math.round(view.height)} px empty, ${spans.length} rows in view, scrollTop ${Math.round(scroller.scrollTop)} of ${Math.round(scroller.scrollHeight)}`,
          );
      });
      w.__powerUser = {
        take() {
          const out = {
            frameMs: state.frameMs.splice(0),
            inputs: state.inputs.splice(0),
            blankFrames: state.blankFrames,
            blanks: state.blanks.splice(0),
          };
          state.blankFrames = 0;
          return out;
        },
        /** Starts the wheel log over, as the shift detector starts. */
        markShift() {
          state.wheels = [[]];
          wheelSigns = [];
        },
        wheels() {
          return state.wheels;
        },
      };
    });

  /** Starts the shift detector (shift.ts `startBoxTracker` with the follow judge). */
  const startShift = (page: Page, shiftUrl: string) =>
    page.evaluate(async (url) => {
      const shift = await import(/* @vite-ignore */ url);
      (window as any).__powerUser.markShift();
      (window as any).__powerShift = shift.startBoxTracker(document, { firstMoveFree: true });
    }, shiftUrl);
  /** Stops it; the stray moves over 1 px, less the follow reversals a wheel turn caused (the person scrolled back). */
  const stopShift = async (page: Page) => {
    const { follow, wheels } = (await page.evaluate(() => {
      const tracker = (window as any).__powerShift;
      (window as any).__powerShift = undefined;
      return { follow: tracker?.stop().follow, wheels: (window as any).__powerUser.wheels() };
    })) as {
      follow?: { stray: { label: string; frame: number; dx: number; dy: number; follow: number }[] };
      wheels: number[][];
    };
    const stray = (follow?.stray ?? []).filter((move) =>
      move.label === "follow reversed"
        ? Math.abs(move.dy) > 1 && !reversalFromWheel(wheels, move.frame, move.dy)
        : Math.max(Math.abs(move.dx), Math.abs(move.dy - move.follow)) > 1,
    );
    const frames = new Set(stray.map((move) => move.frame));
    const worst = Math.max(
      0,
      ...stray.map((move) =>
        move.label === "follow reversed"
          ? Math.abs(move.dy)
          : Math.max(Math.abs(move.dx), Math.abs(move.dy - move.follow)),
      ),
    );
    return { strayFrames: frames.size, worst, stray };
  };

  const draft = (page: Page) =>
    page.evaluate(() =>
      String(((window as any).cmuxAcpmuxDebug.typingStats() as { composer_text: string | null }).composer_text ?? "")
        .replaceAll("\u00a0", " ")
        .replaceAll("\u200b", ""),
    );
  const clearDraft = async (page: Page) => {
    await page.focus(".acpmux-md");
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
  };

  /** Keeps a reply streaming into the open chat (typingLoadDebug.ts). */
  const keepStreaming = (page: Page) =>
    page.evaluate(async () => {
      const debug = (window as any).cmuxAcpmuxDebug;
      const receipt = await debug.typingLoad({});
      if (receipt?.running) return;
      await debug.typingLoad({ chunks_per_second: 40, tool_lines_per_second: 20, seconds: 120 });
    });

  /** Drives one burst; returns the keys it typed, if it typed. */
  async function drive(page: Page, burst: Burst, sessions: string[]): Promise<string | undefined> {
    switch (burst.kind) {
      case "flick":
      case "momentum":
        await page.mouse.move(burst.at[0], burst.at[1]);
        for (const step of burst.steps) {
          await page.mouse.wheel(0, step.dy);
          await gap(page, step.gapMs);
        }
        return;
      case "resize":
        for (const size of burst.sizes) {
          await page.setViewportSize({ width: size.width, height: size.height });
          await gap(page, size.gapMs);
        }
        await page.setViewportSize({ width: WIDTH, height: HEIGHT });
        return;
      case "sweep": {
        const viewport = page.viewportSize() ?? { width: WIDTH, height: HEIGHT };
        for (const [x, y] of burst.points)
          await page.mouse.move(Math.min(x, viewport.width - 1), Math.min(y, viewport.height - 1), {
            steps: burst.stepsPer,
          });
        return;
      }
      case "type":
        await clearDraft(page);
        await page.evaluate(() => (window as any).cmuxAcpmuxDebug.resetTyping());
        await page.keyboard.type(burst.text, { delay: burst.gapMs });
        return burst.text;
      case "paste":
        await page.focus(".acpmux-md");
        await page.evaluate((chars) => {
          const line = "power user paste: the quick brown fox jumps over the lazy dog 0123456789\n";
          const data = new DataTransfer();
          data.setData("text/plain", line.repeat(Math.ceil(chars / line.length)).slice(0, chars));
          document
            .querySelector(".acpmux-md")!
            .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
        }, burst.chars);
        return;
      case "image":
        await page.focus(".acpmux-md");
        await page.evaluate(async ({ width, height }) => {
          const canvas = document.createElement("canvas");
          canvas.width = width;
          canvas.height = height;
          const drawing = canvas.getContext("2d")!;
          drawing.fillStyle = "#5783b5";
          drawing.fillRect(0, 0, width, height);
          drawing.fillStyle = "#e0a84f";
          for (let at = 0; at < 40; at += 1)
            drawing.fillRect((at * 97) % width, (at * 53) % height, width / 9, height / 9);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((value) => resolve(value!), "image/png"));
          const file = new File([blob], "Screenshot.png", { type: "image/png" });
          const paste = new Event("paste", { bubbles: true, cancelable: true });
          Object.defineProperty(paste, "clipboardData", {
            value: { files: [file], types: ["Files"], items: [], getData: () => "" },
          });
          document.querySelector(".acpmux-md")!.dispatchEvent(paste);
        }, burst);
        return;
      case "switch":
        for (const index of burst.sessions) {
          await page.evaluate(
            (id) => (window as any).cmuxAcpmuxDebug.selectSession(id),
            sessions[index % sessions.length],
          );
          await gap(page, burst.gapMs);
        }
        return;
      case "send":
        await clearDraft(page);
        await page.keyboard.type(burst.text, { delay: 8 });
        await page.keyboard.press("Enter");
        await gap(page, burst.switchAfterMs);
        await page.evaluate((id) => (window as any).cmuxAcpmuxDebug.selectSession(id), sessions[1 % sessions.length]);
        return;
    }
  }

  for (const [engine] of engines)
    for (const seed of seeds)
      test(`${engine}: seed ${seed}, ${WAVES} waves of power-user bursts`, async () => {
        const browser = browsers.get(engine);
        if (!browser) return;
        const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 2 });
        const consoleErrors: string[] = [];
        page.on("console", (message) => {
          if (message.type() === "error") consoleErrors.push(message.text());
        });
        page.on("pageerror", (error) => consoleErrors.push(`pageerror: ${error.message}`));
        try {
          await installPaintedFrames(page);
          const { port } = pane!.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}/?mock`);
          await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
          const sessions: string[] = [];
          for (const turns of [200, 60, 400]) {
            const seeded = (await page.evaluate((turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns), turns)) as {
              session?: string;
              error?: string;
            };
            expect(seeded.error).toBeUndefined();
            sessions.push(seeded.session!);
          }
          await page.waitForSelector(".acpmux-md");
          await installRecorder(page);
          const shiftUrl = `/@fs${path.join(webviews, "src/gallery/shift.ts")}`;
          await keepStreaming(page);
          // What setup drew is not the run's.
          await painted(page);
          await page.evaluate(() => (window as any).__powerUser.take());
          consoleErrors.length = 0;
          // The runner's own floor: 120 painted frames with the reply streaming and no input.
          await page.evaluate(async () => {
            for (let frame = 0; frame < 120; frame += 1) await window.cmuxPaintFrame();
          });
          const idle = (await page.evaluate(() => (window as any).__powerUser.take())) as PageRecord;
          const baseline: Baseline = {
            frame_p95_ms: Math.round(percentile(idle.frameMs, 0.95) * 10) / 10,
            frame_p99_ms: Math.round(percentile(idle.frameMs, 0.99) * 10) / 10,
            long_frame_share: idle.frameMs.filter((ms) => ms > 50).length / Math.max(1, idle.frameMs.length),
          };

          const plan = planRun(seed, { waves: WAVES, width: WIDTH, height: HEIGHT, sessions: sessions.length });
          const records: BurstRecord[] = [];
          const blanks: { wave: number; kinds: string; frames: string[] }[] = [];
          const startedAt = performance.now();
          let ran = 0;
          for (const [wave, { bursts }] of plan.entries()) {
            if ((performance.now() - startedAt) / 1000 > BUDGET_S) break;
            ran = wave + 1;
            await keepStreaming(page);
            const layout = bursts.some((burst) => LAYOUT_KINDS.has(burst.kind));
            // A wave that moves the layout on purpose is judged on its settle, after the input.
            if (!layout) await startShift(page, shiftUrl);
            const typed = await Promise.all(bursts.map((burst) => drive(page, burst, sessions)));
            if (layout) {
              await painted(page);
              await startShift(page, shiftUrl);
            }
            await painted(page);
            const typedText = typed.find((text) => text !== undefined);
            let caret: number[] | undefined;
            let keys: { dropped: number; reordered: boolean } | undefined;
            if (typedText !== undefined) {
              // The draft once the last key has drawn (bounded: a key that never lands is a dropped key).
              await page
                .waitForFunction(
                  (want) =>
                    String((window as any).cmuxAcpmuxDebug.typingStats().composer_text ?? "").replaceAll("\u00a0", " ")
                      .length >= want,
                  typedText.length,
                  { timeout: 3_000 },
                )
                .catch(() => undefined);
              keys = draftDiff(typedText, await draft(page));
              const stats = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as {
                samples?: { paint?: number }[];
              };
              caret = (stats.samples ?? []).flatMap((sample) => (sample.paint === undefined ? [] : [sample.paint]));
            }
            const shift = await stopShift(page);
            const recorded = (await page.evaluate(() => (window as any).__powerUser.take())) as PageRecord;
            if (recorded.blanks.length)
              blanks.push({ wave, kinds: bursts.map((burst) => burst.kind).join("+"), frames: recorded.blanks });
            const inputsFor = (kind: BurstKind) => {
              const types =
                kind === "flick" || kind === "momentum"
                  ? ["wheel"]
                  : kind === "sweep"
                    ? ["pointermove"]
                    : kind === "type" || kind === "send"
                      ? ["keydown"]
                      : kind === "paste" || kind === "image"
                        ? ["paste"]
                        : [];
              return recorded.inputs.filter((input) => types.includes(input.type)).map((input) => input.ms);
            };
            for (const burst of bursts)
              records.push({
                kind: burst.kind,
                wave,
                frameMs: recorded.frameMs,
                inputToPaintMs: inputsFor(burst.kind),
                ...(burst.kind === "type" &&
                  caret &&
                  keys && {
                    caretLagMs: caret,
                    droppedKeys: keys.dropped,
                    reordered: keys.reordered,
                  }),
                strayFrames: shift.strayFrames,
                strayWorstPx: shift.worst,
                stray: shift.stray.slice(0, 4),
                blankFrames: recorded.blankFrames,
              });
            // A wave's draft is its own.
            if (bursts.some((burst) => burst.kind === "paste" || burst.kind === "image")) await clearDraft(page);
          }

          const numbers = classNumbers(records);
          const breaches = judge(numbers, consoleErrors, undefined, baseline);
          const located = breaches.map((breach) => ({
            ...breach,
            waves:
              breach.kind === "console"
                ? []
                : records.filter((record) => record.kind === breach.kind).map((record) => record.wave),
            known: knownBreach(engine, breach),
          }));
          const strays = records.filter((record) => record.strayFrames > 0).slice(0, 8);
          const report = {
            engine,
            seed,
            waves: ran,
            planned: WAVES,
            replay: `POWER_USER_SEED=${seed} POWER_USER_WAVES=${ran} POWER_USER_ENGINES=${engine} bun test test/power-user-bursts.browser.test.ts`,
            baseline,
            numbers,
            breaches: located,
            blanks: blanks.slice(0, 12),
            strays: strays.map((record) => ({ wave: record.wave, kind: record.kind, stray: record.stray })),
            plan: plan.map((wave) => wave.bursts.map((burst) => burst.kind).join("+")),
          };
          console.log(`POWER-USER ${JSON.stringify(report)}`);
          if (OUT)
            await Bun.write(path.join(OUT, `power-user-${engine}-${seed}.json`), JSON.stringify(report, null, 2));
          const failing: Breach[] = located.filter(
            (breach) => !breach.known && (GATE_TIMING || !TIMING_WHATS.has(breach.what)),
          );
          if (!REPORT_ONLY) expect(failing, `power-user breaches (replay: ${report.replay})`).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
