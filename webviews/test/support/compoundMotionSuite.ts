// The compound-motion map's suite, shared by compound-motion.test.ts and compound-motion-folds.test.ts.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import type { Sample } from "../browser/compound-motion.harness";
import {
  COMPOUND_CASES,
  EVENT_STEP,
  type CompoundCase as Scenario,
} from "../../src/agent-session/acpmux/conversation/compoundCases";
import { analyzeRun, summarize, type CaseReport, type RunReport } from "./compoundMotionReport";
import { FramesUnsupported, open120Hz } from "./frames120";
import { warmViteServer } from "./warmDevServer";

/// The send cases (the composer's collapse and the sent prompt's rows) and the rest (folds, streams,
/// recap), each with the control: two files, so each stays inside its file's time limit on a slow runner.
export const isSendCase = (scenario: Scenario) =>
  scenario.startsWith("send-") || scenario === "queue-scrolled" || scenario === "steer";

/// Runs `pick`'s compound cases (and the control) on both arms and prints their map. Each test file
/// calls it inside its own requireBrowserLane (the CI scripts find a browser file by that name in it).
export async function compoundMotionSuite(file: string, pick: (scenario: Scenario) => boolean) {
  const PAGE = "/test/browser/compound-motion.html";
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn(`${file}: skipping (run \`bunx playwright install chromium\`)`);
    describe.skip("compound motion", () => test("no chromium", () => {}));
    return;
  }
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn(`${file}: skipping, this Chrome draws no frames on the test's clock (set CMUX_CHROME_HEADLESS_SHELL)`);
    describe.skip("compound motion", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, `node_modules/.vite-${file.replace(/\.test\.ts$/, "")}`),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  /// The window after the event: 72 frames, 600 ms at 120 Hz (every motion token ends inside it).
  const WINDOW_FRAMES = 72;
  const RUNS = Number(process.env.CMUX_COMPOUND_RUNS) || 3;
  const ARMS = ["separate", "transaction"] as const;
  const only = process.env.CMUX_COMPOUND_CASES?.split(",");
  const CASES: Scenario[] = COMPOUND_CASES.filter(
    (scenario) => (scenario === "control" || pick(scenario)) && (only === undefined || only.includes(scenario)),
  );

  async function once(arm: string, scenario: Scenario): Promise<RunReport | undefined> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?clock=frames&arm=${arm}`, {
      clock: "frames",
      viewport: { width: 760, height: 820 },
    });
    try {
      await frames.page.waitForFunction(() => "__compound" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const samples = (await frames.page.evaluate(
        (scenario) =>
          (window as unknown as { __compound: { run(options: object): Promise<unknown> } }).__compound.run({
            scenario,
          }),
        scenario,
      )) as Sample[];
      await frames.stop();
      return analyzeRun(samples, EVENT_STEP[scenario], WINDOW_FRAMES);
    } finally {
      await frames.close();
    }
  }

  const map = new Map<string, CaseReport>();
  for (const scenario of CASES)
    for (const arm of ARMS)
      test(`${scenario} (${arm})`, async () => {
        const runs: RunReport[] = [];
        for (let run = 0; run < RUNS; run += 1) {
          const report = await once(arm, scenario);
          expect(report).toBeDefined();
          runs.push(report!);
        }
        const summary = summarize(runs);
        map.set(`${scenario}|${arm}`, summary);
        console.log(`compound-motion ${scenario} ${arm}: ${JSON.stringify({ summary, runs })}`);
        // The control: nothing happens, nothing moves (a harness that reads motion with none is broken).
        if (scenario === "control") expect(summary.movingFrames).toBe(0);
        // A fold the reader opens keeps the line they clicked where it is (the anchor holds: 0 is the
        // goal), so its proof the event ran is the line reading open.
        else if (scenario === "fold-stream") expect(summary.opened).toBe(true);
        // Everything else moves: a case that reads still is not in view, or its event never ran.
        else expect(summary.travel).toBeGreaterThan(0.5);
        // The send's composer collapse and its rows: one motion with the transaction, never two.
        // send-5-one-commit still takes a 31 px frame before its glide: #50851 (the room joining the
        // playing glide fixes it but holds the rows a frame after the composer collapsed, a one-two in
        // agent-pane-send-one-motion's idle tall sends).
        if (arm === "transaction" && scenario.startsWith("send-") && scenario !== "send-5-one-commit")
          expect(summary.phases).toBeLessThanOrEqual(1);
      });

  afterAll(() => {
    const lines = [
      "| case | arm | phases | shape (frames @ median px/frame) | max px/frame | net px | travel px | settle frames | end gap px |",
      "|---|---|---|---|---|---|---|---|---|",
    ];
    for (const [key, report] of map) {
      const [scenario, arm] = key.split("|");
      lines.push(
        `| ${scenario} | ${arm} | ${report.phases} | ${report.shape} | ${report.maxJump.toFixed(1)} | ${report.net.toFixed(1)} | ${report.travel.toFixed(1)} | ${report.settleFrames} | ${report.endGap.toFixed(1)} |`,
      );
    }
    console.log(`compound-motion map:\n${lines.join("\n")}`);
  });
}
