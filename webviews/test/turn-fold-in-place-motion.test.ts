// cmux-web-test-timeout: 420
// A turn's end folds its work in place, fast, at 120 Hz (Leo, 2026-11-11: "The big chat transcript
// should not be the thing that looks like it's floating up, okay? ... It looks like the Star Wars
// scroll-up animation ... It should just be there, because it already was there. Now all you're doing
// is just moving [stuff] around. So, like, it should not be slow. It should not look like a PowerPoint
// transition slide fade-in.").
//
// The page is send-stream-motion's (browser/send-stream-motion.harness.tsx: the real VirtualTranscript,
// its follow chase, a docked composer) on the frames' own clock (`clock: "frames"`), sampling every
// mounted row each frame (`?rows=1`). Each scripted turn (scriptedTurn.ts TRANSITION_TURNS) runs to its
// end; from the frame its end lands (step `end`) it measures:
// - `settleFrames`: frames until no row in view moves or animates any more: the fold's whole motion;
// - `faded`: rows in view drawn under full ink at any frame of the end (a fade in or out);
// - `answerLost`: frames in which a row of the reply that was in view when the turn ended was not;
// - `worstPx`: the most a row in view moved in one frame.
// It asserts the fold settles inside BUDGET_FRAMES at 120 Hz with no fade and the answer in view.
// CMUX_TURN_FOLD_LOOKS=collapse,clip,snap prints the same numbers per look, for the PR's table.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Sample } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { TRANSITION_TURNS } from "../src/agent-session/acpmux/conversation/scriptedTurn";

/// One 120 Hz frame, ms.
const FRAME_MS = 1000 / 120;
/// The fold's clock (turnEndFold.ts TURN_END_FOLD_MS, the micro step): 120 ms, 15 frames.
const FOLD_MS = 120;
/// The fold's budget: its clock, plus the frames the swap takes to be placed and measured (two) and one
/// for the last frame's rounding. Before this change the end took the settle's 180 ms, grown to 720 ms
/// and past for a long move, with the rows that went fading over it.
const BUDGET_FRAMES = Math.ceil(FOLD_MS / FRAME_MS) + 3;
/// Drawn under this, a row is fading.
const FULL_INK = 0.99;
/// The reply's rows (scriptedTurn.ts SCRIPTED_ANSWER_ID and its later segments).
const ANSWER = "live-answer";

type FoldReport = {
  scenario: string;
  look: string;
  settleFrames: number;
  faded: string[];
  answerLost: number;
  worstPx: number;
};

/// The end's numbers from `samples`.
function foldReport(samples: Sample[], scenario: string, look: string): FoldReport {
  const first = samples.findIndex((sample) => sample.phase === "end");
  const report: FoldReport = { scenario, look, settleFrames: 0, faded: [], answerLost: 0, worstPx: 0 };
  if (first < 1) return report;
  const answer = new Set(
    (samples[first - 1]!.rows ?? []).filter((row) => row.inView && row.id.startsWith(ANSWER)).map((row) => row.id),
  );
  const faded = new Set<string>();
  let last = first;
  for (let index = first; index < samples.length; index += 1) {
    const before = new Map((samples[index - 1]!.rows ?? []).map((row) => [row.id, row]));
    const rows = samples[index]!.rows ?? [];
    let moved = false;
    for (const row of rows) {
      if (!row.inView) continue;
      if (row.opacity < FULL_INK) faded.add(row.id);
      if (row.moving) moved = true;
      const old = before.get(row.id);
      if (!old) continue;
      const step = Math.abs(row.top - old.top);
      if (step > 0.5 || Math.abs(row.height - old.height) > 0.5) moved = true;
      report.worstPx = Math.max(report.worstPx, Math.round(step * 10) / 10);
    }
    const shown = new Set(rows.filter((row) => row.inView).map((row) => row.id));
    if ([...answer].some((id) => !shown.has(id))) report.answerLost += 1;
    if (moved) last = index;
  }
  report.settleFrames = last - first + 1;
  report.faded = [...faded];
  return report;
}

await requireBrowserLane("turn-fold-in-place-motion.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(180_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn(
      "turn-fold-in-place-motion: skipping, this Chrome draws no frames on the test's clock (run scripts/ci/ensure-system-chrome.sh and set CMUX_CHROME_HEADLESS_SHELL)",
    );
    describe.skip("turn fold in place", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-send-stream-motion"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
  });
  afterAll(async () => {
    await vite?.close();
  });

  async function samples(scenario: string, look = ""): Promise<Sample[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const query = `clock=frames&rows=1${look ? `&turnEnd=${look}` : ""}`;
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?${query}`, { clock: "frames" });
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText("History answer 6.").waitFor();
      frames.start();
      const out = (await frames.page.evaluate(
        (scenario) =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
            scenario,
          }),
        scenario,
      )) as Sample[];
      await frames.stop();
      return out;
    } finally {
      await frames.close();
    }
  }

  test.each([...TRANSITION_TURNS])(
    "%s: the fold settles within the 120 Hz budget, fades nothing and keeps the answer in view",
    async (scenario) => {
      const report = foldReport(await samples(scenario), scenario, "shipped");
      console.log(`TURN_FOLD_MOTION ${JSON.stringify(report)}`);
      expect({ scenario, settleFrames: Math.min(report.settleFrames, BUDGET_FRAMES) }).toEqual({
        scenario,
        settleFrames: report.settleFrames,
      });
      expect({ scenario, faded: report.faded }).toEqual({ scenario, faded: [] });
      expect({ scenario, answerLost: report.answerLost }).toEqual({ scenario, answerLost: 0 });
    },
  );

  // CMUX_TURN_FOLD_TRACE=tool-group,...: each frame of the end, from the frame before it, as
  // `frame animations | id top opacity moving` per row in view, to see what moves past the budget.
  test.skipIf(!process.env.CMUX_TURN_FOLD_TRACE)("frame trace (CMUX_TURN_FOLD_TRACE)", async () => {
    for (const scenario of (process.env.CMUX_TURN_FOLD_TRACE ?? "").split(",").filter(Boolean)) {
      const all = await samples(scenario);
      const first = all.findIndex((sample) => sample.phase === "end");
      for (let index = Math.max(0, first - 1); index < Math.min(all.length, first + 30); index += 1) {
        const sample = all[index]!;
        const rows = (sample.rows ?? [])
          .filter((row) => row.inView)
          .map((row) => `${row.id} ${row.top.toFixed(1)} ${row.opacity.toFixed(2)}${row.moving ? " M" : ""}`);
        console.log(`TURN_FOLD_TRACE ${scenario} f${index - first} a${sample.animations} | ${rows.join(" ; ")}`);
      }
    }
  });

  test.skipIf(!process.env.CMUX_TURN_FOLD_LOOKS)("every look (CMUX_TURN_FOLD_LOOKS)", async () => {
    for (const look of (process.env.CMUX_TURN_FOLD_LOOKS ?? "").split(",").filter(Boolean))
      for (const scenario of TRANSITION_TURNS)
        console.log(`TURN_FOLD_MOTION ${JSON.stringify(foldReport(await samples(scenario, look), scenario, look))}`);
  });
});
