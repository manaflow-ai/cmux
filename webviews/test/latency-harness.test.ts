// The interaction-latency harness measures what it claims (test/latency/probe.ts, measure.ts), in
// headless Chromium and WebKit: a response applied in the input handler passes; one that awaits
// a 60 ms reply fails; a 120 ms busy handler is a long task. The pages' own actions run in
// `bun run latency` (scripts/latency/run.ts). Engines that are not installed are skipped.
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type BrowserType } from "playwright";
import { measureAction, type LatencyAction } from "./latency/measure";
import { installLatencyProbe } from "./latency/probe";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("latency-harness.test.ts", async () => {
  setDefaultTimeout(60_000);

  const engines: Array<[string, BrowserType]> = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const installed: Array<[string, BrowserType]> = [];
  for (const engine of engines) {
    try {
      const browser = await engine[1].launch({ headless: true });
      await browser.close();
      installed.push(engine);
    } catch {
      // Not installed here.
    }
  }

  const PAGE = `<!doctype html><button id="sync">sync</button><button id="slow">slow</button>
<button id="busy">busy</button><output id="out">0</output><script>
let n = 0;
const show = () => { document.getElementById("out").textContent = String(++n); };
document.getElementById("sync").onclick = show;
document.getElementById("slow").onclick = () => setTimeout(show, 60);
document.getElementById("busy").onclick = () => { const end = performance.now() + 120; while (performance.now() < end) {} show(); };
</script>`;

  const press = (id: string): LatencyAction => ({
    name: id,
    async prepare(page) {
      const value = await page.evaluate(() => document.getElementById("out")!.textContent);
      return `document.getElementById("out").textContent !== ${JSON.stringify(value)}`;
    },
    async input(page) {
      await page.click(`#${id}`);
    },
    async settle(page) {
      await page.waitForTimeout(80);
    },
  });

  describe.each(installed.length ? installed : [["none", chromium] as [string, BrowserType]])(
    "latency harness in %s",
    (name, engine) => {
      const run = installed.length ? test : test.skip;
      run("a response in the input handler passes, an awaited one fails, a busy handler is a long task", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage();
          await page.setContent(PAGE);
          await page.evaluate(installLatencyProbe);
          await page.waitForTimeout(300);
          const sync = await measureAction(page, { page: "probe", engine: name }, press("sync"), 3);
          expect(sync.pass).toBe(true);
          expect(sync.work).toBeLessThan(16.7);
          const slow = await measureAction(page, { page: "probe", engine: name }, press("slow"), 3);
          expect(slow.pass).toBe(false);
          expect(slow.work).toBeGreaterThanOrEqual(55);
          const busy = await measureAction(page, { page: "probe", engine: name }, press("busy"), 3);
          expect(busy.pass).toBe(false);
          expect(busy.longTaskRuns).toBeGreaterThan(0);
        } finally {
          await browser.close();
        }
      });
    },
  );
});
