// cmux-web-test-timeout: 600
// The churn lane of the chat simulator (src/agent-session/acpmux/sim/README.md "Churn"): a scenario
// plays in real time into the real VirtualTranscript with the pane's motion on, and a per-frame watcher
// (browser/chatChurnWatch.ts) counts the layout shifts above the reader's anchor and the rows drawn
// under a second, per minute of churn.
//
// Leo, 2026-11-22: "this is also a crazy situation for the folding and whatever the steer and you think
// and messages and situations come in and subagents come in and out", "i am still seeing flickers and
// flashes of bullshit. sub-second in and out bullshit."
//
// `CHAT_CHURN_SCENARIOS=a,b` picks scenarios; `CHAT_CHURN_OUT=FILE` writes the reports as JSON.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import { writeFileSync } from "node:fs";
import path from "node:path";
import type { Browser, Page } from "playwright";
import type { ChurnReport } from "./browser/chatChurnWatch";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-churn-browser.test.ts", async () => {
  const PAGE = "/test/browser/chat-sim.html?motion=on";
  /// One line: shifts and flashes per minute of churn, with what moved and what blinked.
  function churnLine(name: string, report: ChurnReport): string {
    const minutes = Math.max(report.durationMs, 1) / 60_000;
    const rate = (count: number) => (count / minutes).toFixed(1);
    const kinds = new Map<string, number>();
    for (const flash of report.flashes) kinds.set(flash.kind || flash.id, (kinds.get(flash.kind || flash.id) ?? 0) + 1);
    const list = [...kinds].map(([kind, count]) => `${kind}=${count}`).join(" ") || "none";
    return `${name}: ${minutes.toFixed(2)} min, ${report.frames} frames; shifts above anchor ${report.shifts.length} (${rate(report.shifts.length)}/min); sub-second rows ${report.flashes.length} (${rate(report.flashes.length)}/min: ${list}); blinks ${report.blinks.length}`;
  }
  setDefaultTimeout(1_500_000);
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
    await warmViteServer(vite, "/test/browser/chat-sim.html");
    const { port } = vite.httpServer!.address() as { port: number };
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 720, height: 1000 } });
    page.on("pageerror", (error) => console.error(`chat-churn page: ${error.message}`));
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.waitForFunction(() => "__chatSim" in window);
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const names = process.env.CHAT_CHURN_SCENARIOS?.split(",") ?? [
    "churn",
    "subagent",
    "long-turn-messages",
    "incoming-notice-turn",
  ];
  const reports: Record<string, ChurnReport> = {};
  afterAll(() => {
    if (process.env.CHAT_CHURN_OUT) writeFileSync(process.env.CHAT_CHURN_OUT, JSON.stringify(reports, null, 1));
  });

  for (const name of names)
    test(`chat churn in Chrome: ${name}`, async () => {
      const report = (await page!.evaluate(
        (name) => (window as unknown as { __chatSim: { live(name: string): Promise<unknown> } }).__chatSim.live(name),
        name,
      )) as ChurnReport;
      reports[name] = report;
      console.log(churnLine(name, report));
      for (const shift of report.shifts.slice(0, 30))
        console.log(
          `  shift +${(shift.at / 1000).toFixed(2)} s (${shift.step}) ${shift.frames} frames, ${shift.rows.length} rows up to ${shift.px}px above ${shift.anchor}: ${shift.rows.slice(0, 4).join(" ")}`,
        );
      for (const flash of report.flashes.slice(0, 30))
        console.log(
          `  flash +${(flash.at / 1000).toFixed(2)} s (${flash.step}) ${flash.kind} ${flash.id} on screen ${flash.shownMs} ms`,
        );
      for (const blink of report.blinks.slice(0, 30))
        console.log(`  blink +${(blink.at / 1000).toFixed(2)} s (${blink.step}) ${blink.id} gone ${blink.goneMs} ms`);
    }, 1_500_000);
});
