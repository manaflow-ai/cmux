// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The running turn's live line holds still while the transcript follows the latest row (Leo, softened: "too much
// render shift when the thing restarts... stuff appears in succession causing shifts"). A running turn alternates
// between a reply and a finished run (live-turn-work `runs`, the default since #41213, keeps each finished run in
// sight over the line). Every painted frame is read with the view at the latest row: the line's box keeps one
// height and its words one distance from the view's bottom, whichever row is over it. Its box is the footer's 32
// slot and, under a run, the run gap (16) sits over it (Leo chose 32/16 on 2026-11-16; transcriptGrid.ts
// MARK_LIVE_STEP, the footer slot and TRANSCRIPT_RUN_GAP).
//
// Before (cmux#24569): under a run the line was one tool row tall (22), under a reply the footer's slot (32), so
// each change of the row over it moved the line's top 10 px and its words 5 px. The perf cron's
// transcript_replay.live.cls read 1.39 at babcb18cd89 against 0.0013 before #41213, all of it from that line.
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

  test("a run or a reply landing over the live line moves neither its box nor its words", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    // FAST_CHECKS_OUT (a cmux-ci run): a video of the whole play, for the PR.
    const out = process.env.FAST_CHECKS_OUT;
    const context = await browser!.newContext({
      viewport: { width: 900, height: 640 },
      ...(out ? { recordVideo: { dir: out, size: { width: 900, height: 640 } } } : {}),
    });
    const page = await context.newPage();
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
            fromBottom: number;
            atEnd: number;
            spare: number;
            gap: number;
            runGap: number;
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
            fromBottom: number;
            atEnd: number;
            spare: number;
            gap: number;
            runGap: number;
          }> = [];
          let frame = 0;
          let step = -1;
          const FRAMES_PER_STEP = 24;
          window.cmuxAfterPaint(
            () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              const line = document.querySelector<HTMLElement>('[data-row-id="thinking-live"]');
              const words = line?.querySelector<HTMLElement>(".cv-thinking");
              if (scroller && line && words && step >= 0) {
                const view = scroller.getBoundingClientRect();
                const box = line.getBoundingClientRect();
                const above = (line.previousElementSibling as HTMLElement | null)?.getBoundingClientRect();
                // The run-gap token as the transcript resolves it, Interface Size included.
                const probe = document.createElement("span");
                probe.style.cssText = "position:absolute;visibility:hidden;width:0;height:var(--grid-gap-run)";
                scroller.append(probe);
                const runGap = probe.getBoundingClientRect().height;
                probe.remove();
                out.push({
                  step: `${step} ${steps[step]![0]}`,
                  over: (line.previousElementSibling as HTMLElement | null)?.dataset.rowId ?? "?",
                  height: Math.round(box.height * 10) / 10,
                  fromBottom: Math.round((view.bottom - words.getBoundingClientRect().bottom) * 10) / 10,
                  atEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
                  spare: Math.round(scroller.scrollHeight - scroller.clientHeight),
                  gap: above ? Math.round((box.top - above.bottom) * 10) / 10 : Number.NaN,
                  runGap,
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
        "step | row over the line | line height | words from the view's bottom | px from the end | px it scrolls | gap over it",
      ]
        .concat(
          trace.map(
            (row) =>
              `${row.step} | ${row.over} | ${row.height} | ${row.fromBottom} | ${row.atEnd} | ${row.spare} | ${row.gap}`,
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
    // One box and one place for its words, whichever row is over it.
    expect(new Set(rested.map((row) => row.height)).size).toBe(1);
    const places = rested.map((row) => row.fromBottom);
    expect(Math.max(...places) - Math.min(...places)).toBeLessThanOrEqual(0.5);
    // That box is the footer's 32 slot, with the run gap over it under each run.
    for (const row of rested) expect(row.height).toBe(32);
    for (const row of rested.filter((each) => each.step.endsWith("run")))
      expect(Math.abs(row.gap - row.runGap), `gap over the line at step ${row.step}`).toBeLessThanOrEqual(0.5);
  });
});
