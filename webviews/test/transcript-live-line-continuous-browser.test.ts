// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// The running turn's one live line keeps going across steps and never flickers (Leo, 2026-11-01, on
// "Ran grep …" drawn over a separate "Thinking 15s": "this should be replacing the thinking area
// and its shimmer across things", "like the thinking or whatever it should just keep going", "and
// shouldn't flicker"). A turn steps through Thinking, a call running, the call done, a thought, the
// next call and that one done. Every painted frame is read: the line is one element from start to end
// (no unmount and remount), its shimmer band is one element whose animation never starts again, the
// line always draws words (no blank frame between calls), its clock is the turn's and never goes
// back, and between calls it names the finished step instead of going back to "Thinking".
//
// Before: the line went "Running grep 0s" (a clock that started again at each call) to "Thinking
// 15s" under the call's own "Ran grep …" row.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-live-line-continuous-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-live-line-continuous-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("the live line keeps going", () => test("chromium", () => {}));
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

  test("one live line, one shimmer and one clock from the prompt to the last step, with no blank frame", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await installPaintedFrames(page);
    // The shimmer runs: no Reduce Motion.
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLiveRows" in window);
    await page.evaluate(() => (window as unknown as { __loadStrings(): Promise<void> }).__loadStrings());

    const trace = await page.evaluate(
      () =>
        new Promise<
          Array<{ frame: number; step: string; text: string; time: string; line: number; band: number; anim: number }>
        >((done) => {
          type Row = Record<string, unknown>;
          const show = (rows: Row[]) =>
            (window as unknown as { __showLiveRows(rows: Row[]): void }).__showLiveRows(rows);
          // The prompt went 15 s ago, so the turn's clock reads 15s and up from the first frame.
          const sent = Date.now() - 15_000;
          const user = { id: "u", kind: "user", version: 1, at: sent, text: "Find where the quota is read." };
          const call = (id: string, command: string, status: string) => ({
            kind: "tool",
            text: "",
            tool: { id, title: command, kind: "execute", status, command, startedAt: Date.now() },
          });
          const grep = "grep -n -E 'environ|GH_QUOTA_[A-Z_]+|low_water' ~/.local/bin/gh-quota";
          const sed = "sed -n 1,40p ~/.local/bin/gh-quota";
          const run = (version: number, items: unknown[]) => ({
            id: "run",
            kind: "activity",
            version,
            at: sent + 1_000,
            items,
          });
          const steps: Array<[string, Row[]]> = [
            ["thinking", [user]],
            ["grep running", [user, run(1, [call("c1", grep, "in_progress")])]],
            ["grep done", [user, run(2, [call("c1", grep, "completed")])]],
            [
              "thought",
              [user, run(3, [call("c1", grep, "completed"), { kind: "thought", text: "The low water mark" }])],
            ],
            ["sed running", [user, run(4, [call("c1", grep, "completed"), call("c2", sed, "in_progress")])]],
            ["sed done", [user, run(5, [call("c1", grep, "completed"), call("c2", sed, "completed")])]],
          ];
          // Each element the trace meets gets a number the first time; a new number is a new element.
          const ids = new WeakMap<Element, number>();
          let next = 0;
          const idOf = (node: Element | null) => {
            if (!node) return -1;
            if (!ids.has(node)) ids.set(node, (next += 1));
            return ids.get(node)!;
          };
          const rows: Array<{
            frame: number;
            step: string;
            text: string;
            time: string;
            line: number;
            band: number;
            anim: number;
          }> = [];
          let frame = 0;
          let step = -1;
          const FRAMES_PER_STEP = 12;
          window.cmuxAfterPaint(
            () => {
              const article = document.querySelector('article[data-row-id="thinking-live"]');
              const band = article?.querySelector(".cv-shimmer__band") ?? null;
              const animation = band?.getAnimations()[0];
              rows.push({
                frame,
                step: steps[step]![0],
                text: article?.querySelector(".cv-shimmer__base")?.textContent ?? "",
                time: article?.querySelector(".cv-worked__time")?.textContent ?? "",
                line: idOf(article),
                band: idOf(band),
                anim: Number(animation?.currentTime ?? -1),
              });
              frame += 1;
              if (frame >= steps.length * FRAMES_PER_STEP) {
                done(rows);
                return false;
              }
            },
            () => {
              // Each step lands in a frame's callbacks, as a chat's snapshot does.
              if (frame % FRAMES_PER_STEP === 0 && step < steps.length - 1) {
                step += 1;
                show(steps[step]![1]);
              }
            },
          );
        }),
    );
    await page.close();

    // The per-frame trace, for the PR: one line per painted frame.
    console.log(
      ["frame | step | line el | band el | band t (ms) | text | time"]
        .concat(
          trace.map(
            (row) =>
              `${row.frame} | ${row.step} | #${row.line} | #${row.band} | ${row.anim.toFixed(1)} | ${row.text} | ${row.time}`,
          ),
        )
        .join("\n"),
    );

    expect(trace.length).toBeGreaterThan(60);
    // One line element and one shimmer band from the first frame to the last: never remounted.
    expect(new Set(trace.map((row) => row.line))).toEqual(new Set([trace[0]!.line]));
    expect(new Set(trace.map((row) => row.band))).toEqual(new Set([trace[0]!.band]));
    expect(trace[0]!.line).toBeGreaterThan(0);
    // The shimmer never starts again: its animation's time only moves forward.
    for (let index = 1; index < trace.length; index += 1)
      expect(trace[index]!.anim).toBeGreaterThanOrEqual(trace[index - 1]!.anim);
    // No blank frame: the line always says something, with the turn's time beside it.
    for (const row of trace) {
      expect(row.text.length).toBeGreaterThan(0);
      expect(row.time).toMatch(/^\d+s$/);
    }
    // The turn's clock, never the call's: it never reads under the 15 s the turn has run, nor goes back.
    const seconds = trace.map((row) => Number.parseInt(row.time, 10));
    expect(Math.min(...seconds)).toBeGreaterThanOrEqual(15);
    for (let index = 1; index < seconds.length; index += 1)
      expect(seconds[index]!).toBeGreaterThanOrEqual(seconds[index - 1]!);
    // Between calls the line holds the finished step, never "Thinking" under its row.
    const last = (step: string) => trace.filter((row) => row.step === step).at(-1)!.text;
    expect(last("thinking")).toBe("Thinking");
    expect(last("grep running")).toStartWith("Running grep");
    expect(last("grep done")).toStartWith("Ran grep");
    expect(last("thought")).toStartWith("Ran grep");
    expect(last("sed running")).toStartWith("Running sed");
    expect(last("sed done")).toStartWith("Ran sed");
  });
});
