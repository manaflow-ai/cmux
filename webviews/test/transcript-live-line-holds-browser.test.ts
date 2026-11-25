// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The running turn's live line holds still while the transcript follows the latest row (Leo, softened: "too much
// render shift when the thing restarts... stuff appears in succession causing shifts"). A running turn alternates
// between a reply and a finished run (live-turn-work `runs`, the default since #41213, keeps each finished run in
// sight over the line). Every painted frame is read with the view at the latest row: the line's row keeps one
// height, and its drawn box (its top) and its words one distance from the view's bottom, whichever row is over it.
// Its row is the footer's 32 slot; its words are drawn in a 22 box at the slot's top, 8 under a run (the footer gap),
// so its words sit 30 under a step row's centre (Leo, 2026-11-21 05:23Z: "see the space/gap between tool calls and
// the current shimmer? this isnt great."; transcriptGrid.ts LIVE_GAP_LOOKS `shipped`). First written for #43627.
//
// Before (cmux#24569): under a run the line was one tool row tall (22), under a reply the footer's slot (32), so
// each change of the row over it moved the line's top 10 px and its words 5 px. The perf cron's
// transcript_replay.live.cls read 1.39 at babcb18cd89 against 0.0013 before #41213, all of it from that line. The
// `jumps` look (<html data-live-gap="jumps">, the 8 gap over a bare 22 row) is played too and must still move: it is
// what flipping TRANSCRIPT_LIVE_STEP_BOX to `line` alone does, so this file goes red on it.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-live-line-holds-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-live-line-holds-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("the live line holds still", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Rested = {
    step: string;
    over: string;
    height: number;
    box: number;
    top: number;
    fromBottom: number;
    atEnd: number;
    spare: number;
    gap: number;
    footerGap: number;
  };
  async function playSwitches(look: string): Promise<Rested[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    // FAST_CHECKS_OUT (a cmux-ci run): a video of the whole play, for the PR.
    const out = process.env.FAST_CHECKS_OUT;
    const context = await browser!.newContext({
      viewport: { width: 900, height: 640 },
      ...(out ? { recordVideo: { dir: out, size: { width: 900, height: 640 } } } : {}),
    });
    const page = await context.newPage();
    // Before the transcript's scripts run, as the gallery's documentAttributes do.
    await page.addInitScript((value) => {
      document.addEventListener("readystatechange", () => {
        document.documentElement.dataset.liveGap = value;
      });
    }, look);
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLiveRows" in window);
    await page.evaluate(() => (window as unknown as { __loadStrings(): Promise<void> }).__loadStrings());

    const trace = await page.evaluate(
      () =>
        new Promise<
          Array<{
            step: string;
            over: string;
            height: number;
            box: number;
            top: number;
            fromBottom: number;
            atEnd: number;
            spare: number;
            gap: number;
            footerGap: number;
          }>
        >((done) => {
          type Row = Record<string, unknown>;
          const show = (rows: Row[]) =>
            (window as unknown as { __showLiveRows(rows: Row[]): void }).__showLiveRows(rows);
          const sent = Date.now() - 30_000;
          const user = {
            id: "u",
            kind: "user",
            version: 1,
            at: sent,
            text: "Find every retry loop and fix the cap.",
          };
          // Far taller than the view at any font, so the view follows the latest row from the first step (a CI
          // web job once read the first step with the column shorter than the view: words 40.8 px up, not 30).
          const earlier = {
            id: "a0",
            kind: "assistant",
            version: 1,
            at: sent + 500,
            text: Array.from(
              { length: 40 },
              (_, index) =>
                `Call site ${index + 1} retries on every error and sleeps a fixed second between attempts, so ` +
                "the cap has to apply here as well.",
            ).join("\n\n"),
          };
          const call = (id: string) => ({
            kind: "tool",
            text: "",
            tool: {
              id,
              title: `rg retry ${id}`,
              kind: "execute",
              status: "completed",
              command: `rg retry ${id}`,
              startedAt: sent + 1_000,
            },
          });
          const run = (id: string, at: number, calls: string[]) => ({
            id,
            kind: "activity",
            version: 1,
            at,
            items: calls.map(call),
          });
          const reply = (id: string, at: number, text: string) => ({ id, kind: "assistant", version: 1, at, text });
          // Each step lands one more row over the live line: a run, a reply, a run, a reply.
          const steps: Array<[string, Row[]]> = [];
          const rows: Row[] = [user, earlier];
          steps.push(["reply", [...rows]]);
          for (let index = 0; index < 3; index += 1) {
            rows.push(run(`r${index}`, sent + 2_000 + index * 2_000, [`c${index}a`, `c${index}b`]));
            steps.push(["run", [...rows]]);
            rows.push(reply(`a${index + 1}`, sent + 3_000 + index * 2_000, `Call site ${index + 15} also retries.`));
            steps.push(["reply", [...rows]]);
          }
          const out: Array<{
            step: string;
            over: string;
            height: number;
            box: number;
            top: number;
            fromBottom: number;
            atEnd: number;
            spare: number;
            gap: number;
            footerGap: number;
          }> = [];
          let frame = 0;
          let step = -1;
          const FRAMES_PER_STEP = 24;
          window.cmuxAfterPaint(
            () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              const line = document.querySelector<HTMLElement>('[data-row-id="thinking-live"]');
              const words = line?.querySelector<HTMLElement>(".cv-thinking");
              const drawn = line?.querySelector<HTMLElement>(".cv-worked");
              if (scroller && line && words && drawn && step >= 0) {
                const view = scroller.getBoundingClientRect();
                const box = line.getBoundingClientRect();
                const drawnBox = drawn.getBoundingClientRect();
                const above = (line.previousElementSibling as HTMLElement | null)?.getBoundingClientRect();
                // The footer-gap token as the transcript resolves it, Interface Size included.
                const probe = document.createElement("span");
                probe.style.cssText = "position:absolute;visibility:hidden;width:0;height:var(--grid-gap-footer)";
                scroller.append(probe);
                const footerGap = probe.getBoundingClientRect().height;
                probe.remove();
                out.push({
                  step: `${step} ${steps[step]![0]}`,
                  over: (line.previousElementSibling as HTMLElement | null)?.dataset.rowId ?? "?",
                  height: Math.round(box.height * 10) / 10,
                  box: Math.round(drawnBox.height * 10) / 10,
                  top: Math.round((view.bottom - drawnBox.top) * 10) / 10,
                  fromBottom: Math.round((view.bottom - words.getBoundingClientRect().bottom) * 10) / 10,
                  atEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
                  spare: Math.round(scroller.scrollHeight - scroller.clientHeight),
                  gap: above ? Math.round((box.top - above.bottom) * 10) / 10 : Number.NaN,
                  footerGap,
                });
              }
              frame += 1;
              if (frame >= steps.length * FRAMES_PER_STEP) {
                done(out);
                return false;
              }
            },
            () => {
              if (frame % FRAMES_PER_STEP === 0 && step < steps.length - 1) {
                step += 1;
                show(steps[step]![1]);
              }
            },
          );
        }),
    );
    await context.close();

    console.log(
      [
        `look ${look}`,
        "step | row over the line | row height | line box | line top from the view's bottom | words from the view's bottom | px from the end | px it scrolls | gap over it",
      ]
        .concat(
          trace.map(
            (row) =>
              `${row.step} | ${row.over} | ${row.height} | ${row.box} | ${row.top} | ${row.fromBottom} | ${row.atEnd} | ${row.spare} | ${row.gap}`,
          ),
        )
        .join("\n"),
    );
    // Each step's last frame, once the arrival's glide (tailGlide.ts, a translate the reader sees as the new row
    // rising in) has played: where the line rests under that row, with the view at the latest row.
    const rested = [...new Map(trace.map((row) => [row.step, row])).values()];
    expect(rested.length).toBe(7);
    for (const row of rested) expect(row.atEnd).toBeLessThanOrEqual(1);
    // The column overflows the view at every step, so the view sits at the latest row rather than at the top.
    for (const row of rested) expect(row.spare).toBeGreaterThan(100);
    expect(new Set(rested.map((row) => row.over))).toEqual(new Set(["a0", "r0", "a1", "r1", "a2", "r2", "a3"]));
    return rested;
  }
  const spread = (values: number[]) => Math.max(...values) - Math.min(...values);

  test("a run or a reply landing over the live line moves neither its box, its top nor its words", async () => {
    const rested = await playSwitches("shipped");
    // One row, one drawn box, one top and one place for its words, whichever row is over it.
    expect(new Set(rested.map((row) => row.height)).size).toBe(1);
    expect(new Set(rested.map((row) => row.box)).size).toBe(1);
    expect(spread(rested.map((row) => row.top)), "the line's top across the switches").toBeLessThanOrEqual(0.5);
    expect(spread(rested.map((row) => row.fromBottom)), "its words across the switches").toBeLessThanOrEqual(0.5);
    // Its row is the footer's 32 slot, its words in a one-line row's 22 at the slot's top, the footer gap (8) over it
    // under each run and each reply: 30 from a step row's centre to its words' centre.
    for (const row of rested) expect(row.height).toBe(32);
    for (const row of rested) expect(row.box).toBe(22);
    for (const row of rested)
      expect(Math.abs(row.gap - row.footerGap), `gap over the line at step ${row.step}`).toBeLessThanOrEqual(0.5);
    for (const row of rested.filter((each) => each.step.endsWith("run")))
      expect(22 / 2 + row.gap + row.box / 2, `centre to centre at step ${row.step}`).toBe(30);
  });

  // The same play with TRANSCRIPT_LIVE_STEP_BOX flipped to `line` alone: the row under a run is 22 with the composer
  // gap under it, under a reply the 32 slot with the block gap, so each switch moves the line's top 18 and its words 13.
  test("the bare flip to a 22 row (the `jumps` look) moves the line at each switch", async () => {
    const rested = await playSwitches("jumps");
    expect(spread(rested.map((row) => row.top))).toBeGreaterThan(5);
    expect(spread(rested.map((row) => row.fromBottom))).toBeGreaterThan(5);
  });
});
