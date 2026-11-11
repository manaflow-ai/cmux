// cmux-web-test-timeout: 420
// A row that arrives in a running turn (thinking, a tool call, a call joining a group, a subagent)
// moves the chat at once and has everything at rest within 120 ms of the event, in one motion, at
// the same cost in a long chat as in a short one (Leo, 2026-11-09: "also the tool call shifting the
// chat animation and stuff is just too slow. it's really sluggish. thinking, tool calls, etc...
// cannot lag nor can they take long", and "there's some sort of "settling" and like ok maybe but the
// animations end to end need to just resolve faster").
//
// The page is send-stream-motion's (browser/send-stream-motion.harness.tsx: the real
// VirtualTranscript, its follow chase, a docked composer) on the frames' own clock, over a history
// of 51 and of 501 rows (`?history=17|167`). Each turn (conversation/scriptedTurn.ts ARRIVAL_TURNS)
// streams a paragraph, rests, and then one row arrives; support/rowArrivalReport.ts measures that
// arrival's frames: the first change, the last move, the last change of any kind (everything at
// rest), separate bursts of motion (a settle chained after the main move), and the animations it
// started.
//
// Measured on this page at f27448b431b (#39271's first head), the same in a 51-row and a 501-row chat:
// a call that finished, a thought that ended as a call started, and a subagent's report rested 228 ms
// after the event and a call joining a group 211 ms, each in two bursts (the follow chase's spring
// crept the last pixels home under a frame's notice, then snapped them); a call or thought starting
// on the live line rested at 128 ms (its words' roll, on the 120 ms entry step).
// Set CMUX_ROW_ARRIVAL_DUMP=prefix to keep the samples.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Sample, Scenario } from "./browser/send-stream-motion.harness";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { ARRIVAL_TURNS } from "../src/agent-session/acpmux/conversation/scriptedTurn";
import { arrivalReport, FRAME_MS, type ArrivalReport } from "./support/rowArrivalReport";

await requireBrowserLane("row-arrival-settle.test.ts", async () => {
  const PAGE = "/test/browser/send-stream-motion.html";
  setDefaultTimeout(180_000);
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    console.warn(
      "row-arrival-settle: skipping, this Chrome draws no frames on the test's clock (run scripts/ci/ensure-system-chrome.sh and set CMUX_CHROME_HEADLESS_SHELL)",
    );
    describe.skip("row arrivals", () => test("no chrome-headless-shell", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    // React's production build, as the app ships it, from send-stream-motion's dependency cache.
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

  async function samples(scenario: Scenario, turns: number, look = "", options: object = {}): Promise<Sample[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const query = `clock=frames&rows=1&history=${turns}${look ? `&tailGlide=${look}` : ""}`;
    const frames = await open120Hz(`http://127.0.0.1:${port}${PAGE}?${query}`, { clock: "frames" });
    try {
      await frames.page.waitForFunction(() => "__sendStream" in window);
      await frames.page.getByText(`History answer ${turns - 1}.`).waitFor();
      frames.start();
      const out = (await frames.page.evaluate(
        ({ scenario, options }) =>
          (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream.run({
            scenario,
            settleMs: 300,
            ...options,
          }),
        { scenario, options },
      )) as Sample[];
      await frames.stop();
      return out;
    } finally {
      await frames.close();
    }
  }

  /// A short chat (51 rows) and a long one (501 rows).
  const SHORT = 17;
  const LONG = 167;
  /// From the event to everything at rest.
  const MAX_REST_MS = 120;
  /// The chat moves in the frame the row lands in, or the next: never behind the stream.
  const MAX_FIRST_MS = 2 * FRAME_MS + 0.5;
  /// One line of the reply at the chat font; no frame moves a row in view by more than two thirds of
  /// one (turn-transition-jumps.test.ts).
  const MAX_FRAME_PX = (2 / 3) * 22.75;

  /// The two events of each turn: the row starts, then takes its place (scriptedTurn.ts playArrival).
  const STEPS = ["begin", "land"] as const;
  const reports = new Map<string, Record<(typeof STEPS)[number], ArrivalReport>>();
  async function report(scenario: Scenario, turns: number) {
    const key = `${scenario}@${turns}`;
    const cached = reports.get(key);
    if (cached) return cached;
    const out = await samples(scenario, turns);
    if (process.env.CMUX_ROW_ARRIVAL_DUMP)
      await Bun.write(`${process.env.CMUX_ROW_ARRIVAL_DUMP}-${key}.json`, JSON.stringify(out));
    const made = Object.fromEntries(STEPS.map((step) => [step, arrivalReport(out, step)!])) as Record<
      (typeof STEPS)[number],
      ArrivalReport
    >;
    for (const step of STEPS) {
      expect({ step, ran: made[step] !== undefined }).toEqual({ step, ran: true });
      console.log(`row-arrival ${scenario} ${step} rows=${turns * 3} ${JSON.stringify(made[step])}`);
    }
    reports.set(key, made);
    return made;
  }

  test.each([...ARRIVAL_TURNS])("%s: everything rests within 120 ms of the event, in one motion", async (scenario) => {
    for (const turns of [SHORT, LONG])
      for (const step of STEPS) {
        const window = (await report(scenario, turns))[step];
        // Labelled, so a failure names the case.
        const at = { scenario, step, rows: turns * 3 };
        expect({ ...at, restMs: window.restMs }).toEqual({ ...at, restMs: Math.min(window.restMs, MAX_REST_MS) });
        expect({ ...at, firstMs: window.firstMs }).toEqual({ ...at, firstMs: Math.min(window.firstMs, MAX_FIRST_MS) });
        expect({ ...at, bursts: window.bursts }).toEqual({ ...at, bursts: Math.min(window.bursts, 1) });
        expect({ ...at, worstPx: window.worstPx }).toEqual({ ...at, worstPx: Math.min(window.worstPx, MAX_FRAME_PX) });
      }
  });

  test.each([...ARRIVAL_TURNS])(
    "%s: an arrival costs the same in a 501-row chat as in a 51-row one",
    async (scenario) => {
      for (const step of STEPS) {
        const short = (await report(scenario, SHORT))[step];
        const long = (await report(scenario, LONG))[step];
        // The same rows mount (the view's window), the same animations start, and it rests as soon.
        const at = { scenario, step };
        expect({ ...at, mounted: long.mounted }).toEqual({ ...at, mounted: Math.min(long.mounted, short.mounted + 2) });
        expect({ ...at, started: long.started }).toEqual({ ...at, started: Math.min(long.started, short.started + 1) });
        expect({ ...at, restMs: long.restMs }).toEqual({
          ...at,
          restMs: Math.min(long.restMs, short.restMs + FRAME_MS + 0.5),
        });
      }
    },
  );

  // The reader wheels up 16 ms into a call's landing, while the rows above come home and the live
  // line under the call glides: from then on nothing moves but their own scroll (each row stays
  // where it is drawn in the thread's content: its top on screen plus the scroll offset), until the
  // turn ends. The review of #39271 found the rows under a change gliding on after the reader's
  // input held the chase.
  test("the reader's wheel during an arrival holds every row where it is drawn", async () => {
    const out = await samples("arrive-tool", SHORT, "", { wheel: { at: "land", afterMs: 16, px: 60 } });
    const wheeled = out.find((sample) => sample.wheeledAt !== undefined)?.wheeledAt;
    expect(wheeled).toBeDefined();
    // The frames after the wheel's, up to the turn's end.
    const after = out.filter((sample) => sample.phase === "land" && sample.t > wheeled! + FRAME_MS);
    expect(after.length).toBeGreaterThan(20);
    let most = 0;
    let moved: string | undefined;
    for (let index = 1; index < after.length; index += 1) {
      const before = new Map((after[index - 1]!.rows ?? []).map((row) => [row.id, row]));
      for (const row of after[index]!.rows ?? []) {
        const was = before.get(row.id);
        // Every mounted row: the live line under the glass composer shows through it.
        if (!was) continue;
        const shift = Math.abs(row.top + after[index]!.scrollTop - (was.top + after[index - 1]!.scrollTop));
        if (shift > most) {
          most = shift;
          moved = row.id;
        }
      }
    }
    expect({ most: Math.round(most * 10) / 10, moved }).toEqual({
      most: Math.min(Math.round(most * 10) / 10, 0.5),
      moved,
    });
  });

  // The gallery's looks on the same page (CMUX_ROW_ARRIVAL_LOOKS=quick,glide,jump): each arrival's
  // rest per look, for the PR's table.
  test.skipIf(!process.env.CMUX_ROW_ARRIVAL_LOOKS)("every tail-glide look (CMUX_ROW_ARRIVAL_LOOKS)", async () => {
    for (const look of (process.env.CMUX_ROW_ARRIVAL_LOOKS ?? "").split(",").filter(Boolean))
      for (const scenario of ARRIVAL_TURNS)
        for (const turns of [SHORT, LONG])
          for (const out of [await samples(scenario, turns, look)])
            for (const step of STEPS)
              console.log(
                `row-arrival look ${look} ${scenario} ${step} rows=${turns * 3} ${JSON.stringify(arrivalReport(out, step))}`,
              );
  });
});
