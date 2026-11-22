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
import path from "node:path";
import type { Browser, Page } from "playwright";
import { summarize, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-sim-browser.test.ts", async () => {
  const PAGE = "/test/browser/chat-sim.html";
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-chat-sim"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    const { port } = vite.httpServer!.address() as { port: number };
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 720, height: 1400 } });
    page.on("pageerror", (error) => console.error(`chat-sim page: ${error.message}`));
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
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

  // `CHAT_SIM_DUMP=scenario:step`: prints the drawn rows' boxes at that step (where each gap lives).
  const dumpAt = process.env.CHAT_SIM_DUMP?.split(":");
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
});
