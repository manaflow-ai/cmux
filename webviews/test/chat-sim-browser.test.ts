// cmux-web-test-timeout: 600
// The chat simulator's browser lane (src/agent-session/acpmux/sim/README.md): every scenario and the
// sanitized replay drawn step by step in Chrome by the real VirtualTranscript with the pane's CSS
// (browser/chat-sim.harness.tsx), with the rules read off the rows' drawn boxes: (a) a turn's first
// rows keep their gaps, (b) nothing folds before its turn ends.
//
// Leo, 2026-11-21: "it is noticeably bad when you start a new working for whatever and there is no
// space before ... the messages and whatever collapsing and stuff, sometimes it does so too soon in
// the midst of a turn". `CHAT_SIM_SCENARIOS=a,b` picks scenarios (`replay`, `long:N` too);
// `CHAT_SIM_OUT=FILE` writes the results as JSON.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { writeFileSync } from "node:fs";
import type { Browser, Page } from "playwright";
import type { ViteDevServer } from "vite";
import { summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS, scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { CHAT_SIM_PAGE, startChatSimServer } from "./support/chatSimServer";

await requireBrowserLane("chat-sim-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  const { chromium } = await import("playwright");
  let vite: ViteDevServer | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;
  beforeAll(async () => {
    const server = await startChatSimServer();
    vite = server.vite;
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 720, height: 1400 } });
    page.on("pageerror", (error) => console.error(`chat-sim page: ${error.message}`));
    await page.goto(`${server.base}${CHAT_SIM_PAGE}`);
    await page.waitForFunction(() => "__chatSim" in window);
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const names = process.env.CHAT_SIM_SCENARIOS?.split(",") ?? [...scenarioNames(), "replay"];
  const results: SimResult[] = [];
  afterAll(() => {
    if (process.env.CHAT_SIM_OUT) writeFileSync(process.env.CHAT_SIM_OUT, JSON.stringify(results, null, 1));
  });
  const broken = (result: SimResult, prefix: string) =>
    result.violations.filter((violation) => violation.rule.startsWith(prefix)).map((v) => `${v.rowId}: ${v.detail}`);

  // `CHAT_SIM_DUMP=scenario:step`: prints the drawn rows' boxes at that step (where each gap lives). The step is
  // after the last colon, so a `file:PATH` scenario works too.
  const dumpSpec = process.env.CHAT_SIM_DUMP;
  const dumpAt = dumpSpec
    ? [dumpSpec.slice(0, dumpSpec.lastIndexOf(":")), dumpSpec.slice(dumpSpec.lastIndexOf(":") + 1)]
    : undefined;
  if (dumpAt)
    test(`chat simulator in Chrome: the drawn rows of ${dumpAt[0]} at step ${dumpAt[1]}`, async () => {
      const rows = await page!.evaluate(
        ([name, step]) =>
          (window as unknown as { __chatSim: { at(name: string, step: number): Promise<unknown> } }).__chatSim.at(
            name!,
            Number(step),
          ),
        dumpAt,
      );
      console.log(JSON.stringify(rows, null, 1));
    });

  for (const name of dumpAt ? [] : names)
    test(`chat simulator in Chrome: ${name} keeps rules a and b`, async () => {
      const result = (await page!.evaluate(
        (name) => (window as unknown as { __chatSim: { run(name: string): Promise<unknown> } }).__chatSim.run(name),
        name,
      )) as SimResult;
      results.push(result);
      console.log(summarize(result));
      expect([...new Set(broken(result, "b-"))]).toEqual([]);
      expect([...new Set(broken(result, "a-"))]).toEqual([]);
    });

  // The watch mode (scripts/chat-sim-watch.ts): records handed in from the page play on fast real time and
  // the shot hook fires at each turn's start and end.
  if (!dumpAt && !process.env.CHAT_SIM_SCENARIOS)
    test("chat simulator in Chrome: watch plays handed-in records and shoots at turn boundaries", async () => {
      const shots: { why: string }[] = [];
      await page!.exposeFunction("__chatSimShot", async (shot: { why: string }) => void shots.push(shot));
      const scenario = SCENARIOS["incoming-notice-turn"]!();
      const result = (await page!.evaluate(
        (records) =>
          (window as unknown as { __chatSim: { watch(o: unknown): Promise<unknown> } }).__chatSim.watch({
            name: "handed-in",
            records,
            speed: 1000,
            maxGapMs: 20,
            minGapMs: 0,
            maxSeconds: 120,
          }),
        scenario.events,
      )) as { played: number; steps: number; turns: number; stoppedEarly: boolean };
      expect(result.stoppedEarly).toBe(false);
      expect(result.played).toBe(result.steps);
      expect(shots.filter((shot) => shot.why === "turn-start").length).toBe(result.turns);
      expect(shots.filter((shot) => shot.why === "turn-end").length).toBeGreaterThan(0);
      expect(shots.at(-1)?.why).toBe("end");
    });
});
