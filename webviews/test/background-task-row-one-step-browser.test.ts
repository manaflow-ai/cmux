// l10n-allow-file: test fixture commands, output and summaries, not shipped UI.
// A finished background command's row opens in one step (Leo, 2026-11-09, on "Background command
// completed router-review 39920 process exit" opening in a "3 background tasks finished" group:
// "slow and bad loading state here :(").
//
// It opened in three stages: a one-line stub (the command, a gap, "Monitor … stream ended", Open in
// terminal), then 2-4 s later the Shell card with what the command printed, each stage pushing the
// rows under it down again. The note read acpmux's process registry only once it opened
// (backgroundTaskOutput.ts), so the stub drew until the reply came.
//
// The chat here is his shape: a prompt, three finished background commands, a reply under them. The
// registry answers each read after a delay, as a busy daemon does. The reader opens the middle note:
// - after it has sat on screen a moment (the usual case), and
// - at once, before any read could have answered.
// From the click to rest, every painted frame must show either nothing under the note or the whole
// card (the command, what it printed, "[exited with code 0]", the "stream ended" line and Open in
// terminal), never the stub; the note's height and the reply under it move in one motion; and the
// card's height never changes once that motion ends. On Chromium at four times slower script, the
// open stays in a frame's budget (support/foldFrameReport.ts).
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { costLine, installFoldProbe, measureToggle, SMOOTH_MS } from "./support/foldFrameReport";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("background-task-row-one-step-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("background-task-row-one-step-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("background task row one step", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
      try {
        browsers[name] = await engines[name].launch({ headless: true });
      } catch (error) {
        if (process.env.GITHUB_ACTIONS === "true") throw error;
        console.warn(
          `background-task-row-one-step-browser: ${name} cannot launch here: ${String(error).split("\n")[0]}`,
        );
      }
    }
  });
  afterAll(async () => {
    for (const each of Object.values(browsers)) await each?.close();
    await vite?.close();
  });

  /// How long each registry reply takes (a list, then a tail: twice this per read).
  const REPLY_MS = 300;
  const COMMAND = "router-review 39920 process exit";
  const SUMMARY = `Monitor "${COMMAND}" stream ended`;
  const OUTPUT = "router-review finished\n\n[exited with code 0]\n";
  const NOTE = "bg-2";
  const BELOW = "reply";
  let at = Date.now() - 86_400_000;
  const task = (id: string, command: string) => ({
    id,
    kind: "backgroundTask",
    version: 1,
    at: (at += 1_000),
    backgroundTask: {
      toolCallId: id,
      command,
      state: "completed",
      summary: `Monitor "${command}" stream ended`,
    },
  });
  const rows = () => [
    { id: "ask", kind: "user", version: 1, at: (at += 1_000), text: "we just pre-approve people sometimes?" },
    task("bg-1", "PR 39920 checks or fresh review finished"),
    task(NOTE, COMMAND),
    task("bg-3", "PR 39920 checks or review finished (2)"),
    {
      id: BELOW,
      kind: "assistant",
      version: 1,
      at: (at += 1_000),
      text: "The handshakes take milliseconds; the approval is what waits.",
    },
  ];

  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );

  const open = async (browser: Browser) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await installFoldProbe(page);
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRawRows" in window);
    await page.evaluate(async () => (window as unknown as { __loadStrings(): Promise<void> }).__loadStrings());
    await page.evaluate(
      ({ outputs, delay }) =>
        (
          window as unknown as { __backgroundOutputs(outputs: Record<string, string>, delay: number): void }
        ).__backgroundOutputs(outputs, delay),
      {
        outputs: { "bg-1": "checks green\n", [NOTE]: OUTPUT, "bg-3": "review SHIP\n" },
        delay: REPLY_MS,
      },
    );
    return page;
  };
  const show = (page: Page) =>
    page.evaluate((rows) => (window as unknown as { __showRawRows(rows: unknown): void }).__showRawRows(rows), rows());
  const header = `[data-row-id="${NOTE}"] button.cv-bgtask`;
  const click = async (page: Page) => {
    const box = (await page.locator(header).boundingBox())!;
    await page.mouse.click(box.x + 24, box.y + box.height / 2);
  };

  type Frame = { t: number; stub: boolean; full: boolean; body: boolean; height: number; below: number };
  /// Records each painted frame from now until `stop`, and when the note's header is pressed.
  const record = (page: Page) =>
    page.evaluate(
      ({ note, below, command, summary }) => {
        const state = { frames: [] as Frame[], clickAt: 0, on: true };
        (window as unknown as { __oneStep: typeof state }).__oneStep = state;
        document.addEventListener(
          "pointerdown",
          () => {
            if (!state.clickAt) state.clickAt = performance.now();
          },
          { capture: true },
        );
        const tick = (now: number) => {
          if (!state.on) return;
          const row = document.querySelector<HTMLElement>(`[data-row-id="${note}"]`);
          const next = document.querySelector<HTMLElement>(`[data-row-id="${below}"]`);
          const head = row?.querySelector<HTMLElement>("button.cv-bgtask");
          const shell = row?.querySelector<HTMLElement>(".cv-shell");
          const text = shell?.textContent ?? "";
          if (row && next && head)
            state.frames.push({
              t: now,
              stub: Boolean(row.querySelector(".cv-bgtask__details")),
              body: Boolean(row.querySelector(".cv-anchored-collapse")),
              full:
                text.includes(command) &&
                text.includes("router-review finished") &&
                text.includes("[exited with code 0]") &&
                text.includes(summary) &&
                Boolean(shell?.querySelector(".cv-bgtask__open")),
              height: row.getBoundingClientRect().height,
              below: next.getBoundingClientRect().top - head.getBoundingClientRect().top,
            });
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      },
      { note: NOTE, below: BELOW, command: COMMAND, summary: SUMMARY },
    );
  const collect = (page: Page) =>
    page.evaluate(() => {
      const state = (window as unknown as { __oneStep: { frames: Frame[]; clickAt: number; on: boolean } }).__oneStep;
      state.on = false;
      return { frames: state.frames, clickAt: state.clickAt };
    });

  /// Runs of frames in which `value` moves; a still gap of more than three frames ends a run.
  const motions = (frames: Frame[], value: (frame: Frame) => number) => {
    let runs = 0;
    let still = Infinity;
    for (let index = 1; index < frames.length; index += 1) {
      if (Math.abs(value(frames[index]!) - value(frames[index - 1]!)) > 0.5) {
        if (still > 3) runs += 1;
        still = 0;
      } else still += 1;
    }
    return runs;
  };

  type Result = {
    clickToFinal: number;
    stubFrames: number;
    partialFrames: number;
    heightMotions: number;
    belowMotions: number;
    lastChangeAfterFinal: number;
  };
  const measure = async (page: Page, wait: number): Promise<Result> => {
    await show(page);
    await settle(page);
    // The note as the reader finds it: on screen for `wait` ms (0: clicked as it arrives).
    if (wait) await page.waitForTimeout(wait);
    await record(page);
    await click(page);
    // Twice the registry's two replies and the fold, then rest.
    await page.waitForTimeout(REPLY_MS * 4 + 600);
    await settle(page);
    const { frames, clickAt } = await collect(page);
    const after = frames.filter((frame) => frame.t >= clickAt);
    const final = after.find((frame) => frame.full);
    let lastChange = 0;
    for (let index = 1; index < after.length; index += 1)
      if (Math.abs(after[index]!.height - after[index - 1]!.height) > 0.5) lastChange = after[index]!.t;
    return {
      clickToFinal: final ? Math.round(final.t - clickAt) : Infinity,
      stubFrames: after.filter((frame) => frame.stub).length,
      // A body drawn without the whole card: the stub, or a card still missing a line.
      partialFrames: after.filter((frame) => frame.body && !frame.full).length,
      heightMotions: motions(after, (frame) => frame.height),
      belowMotions: motions(after, (frame) => frame.below),
      lastChangeAfterFinal: final ? Math.round(lastChange - final.t) : Infinity,
    };
  };
  const line = (name: string, label: string, result: Result) =>
    `${name} ${label}: click to final content ${result.clickToFinal} ms; ${result.stubFrames} stub frames, ` +
    `${result.partialFrames} partial frames; note height moved ${result.heightMotions}x, row below moved ` +
    `${result.belowMotions}x; last height change ${result.lastChangeAfterFinal} ms after the final card`;
  /// The fold's own length (conversation.css `--cv-fold-duration`) and a few frames of settle.
  const FOLD_SETTLE = 180 + 120;
  const failures = (at: string, result: Result, reach: number) => {
    const out: string[] = [];
    if (result.stubFrames) out.push(`${at}: ${result.stubFrames} frames drew the stub`);
    if (result.partialFrames) out.push(`${at}: ${result.partialFrames} frames drew a body without the whole card`);
    if (result.heightMotions !== 1) out.push(`${at}: the note's height moved ${result.heightMotions} times (once)`);
    if (result.belowMotions !== 1) out.push(`${at}: the row below moved ${result.belowMotions} times (once)`);
    if (result.lastChangeAfterFinal > FOLD_SETTLE)
      out.push(`${at}: the card's height changed ${result.lastChangeAfterFinal} ms after it drew whole`);
    if (result.clickToFinal > reach) out.push(`${at}: ${result.clickToFinal} ms from the click to the whole card`);
    return out;
  };

  for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
    test(`${name}: a finished background command's row opens to its whole card in one step`, async () => {
      if (!browsers[name]) return;
      const out: string[] = [];
      // On screen a moment first: the card is drawn whole from the click's first frames.
      let page = await open(browsers[name]!);
      const seen = await measure(page, 1_000);
      await page.close();
      console.log(line(name, "after a second on screen", seen));
      out.push(...failures(`${name} after a second on screen`, seen, 120));
      // Clicked as it arrives: nothing opens until the read answers, then the whole card at once.
      page = await open(browsers[name]!);
      const fresh = await measure(page, 0);
      await page.close();
      console.log(line(name, "clicked as it arrives", fresh));
      out.push(...failures(`${name} clicked as it arrives`, fresh, REPLY_MS * 2 + 250));
      expect(out).toEqual([]);
    });
  }

  test("chromium: opening the note stays in a frame's budget at four times slower script", async () => {
    if (!browsers.chromium) return;
    const page = await open(browsers.chromium);
    await show(page);
    await settle(page);
    await page.waitForTimeout(1_000);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    const cost = await measureToggle(
      page,
      "open a background command",
      () => click(page),
      async () => {
        await page.waitForTimeout(REPLY_MS * 4 + 600);
        await settle(page);
      },
      cdp,
    );
    await page.close();
    console.log(costLine("chromium", cost));
    const out: string[] = [];
    const commits = Math.max(4, Math.ceil(cost.frames / 2));
    if (cost.commits > commits) out.push(`${cost.commits} React commits in ${cost.frames} frames (at most ${commits})`);
    if (cost.rowRenders > cost.mounted) out.push(`${cost.rowRenders} row renders for ${cost.mounted} mounted rows`);
    if (cost.smooth < 0.6)
      out.push(`${Math.round(cost.smooth * 100)}% of frames within ${SMOOTH_MS} ms (at least 60%)`);
    expect(out).toEqual([]);
  });
});
