// l10n-allow-file: benchmark output, not shipped UI.
// An open anchored menu (ui/anchor.ts useUiAnchor) while the scroller around it scrolls: each
// scroll event runs the anchor's update. In headless Chrome, per run of UPDATES scroll steps:
//   layouts   layouts Chrome ran during the steps (CDP Performance LayoutCount), per update
//   ms        main-thread time for all the steps
// Prints p50 and the spread (min..max) of RUNS runs.
//   bun bench/anchor-scroll.bench.ts [updates] [runs]   (default 200 5)
/// <reference types="bun" />
import { chromium } from "playwright";

const [updatesArg, runsArg] = process.argv.slice(2).map(Number);
const UPDATES = updatesArg || 200;
const RUNS = runsArg || 5;

const built = await Bun.build({ entrypoints: [`${import.meta.dir}/anchor-scroll.page.tsx`], minify: true });
if (!built.success) throw new Error(built.logs.join("\n"));
const script = await built.outputs[0]!.text();

const browser = await chromium.launch({ executablePath: process.env.CHROME ?? "/usr/bin/google-chrome" });
const results: { layouts: number; ms: number }[] = [];
for (let run = 0; run < RUNS; run++) {
  const page = await browser.newPage();
  await page.setContent(`<!doctype html><body style="margin:0"><div id="root"></div></body>`);
  await page.addScriptTag({ content: script });
  await page.waitForFunction(() => document.getElementById("scroller"));
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable");
  const layouts = async () =>
    (await cdp.send("Performance.getMetrics")).metrics.find((metric) => metric.name === "LayoutCount")!.value;
  const before = await layouts();
  const ms = await page.evaluate((updates) => {
    const scroller = document.getElementById("scroller")!;
    const start = performance.now();
    for (let i = 0; i < updates; i++) {
      scroller.scrollTop = i % 100;
      scroller.dispatchEvent(new Event("scroll"));
    }
    return performance.now() - start;
  }, UPDATES);
  results.push({ layouts: ((await layouts()) - before) / UPDATES, ms });
  await page.close();
}
await browser.close();

const stat = (key: "layouts" | "ms") => {
  const values = results.map((result) => result[key]).sort((a, b) => a - b);
  const fmt = (v: number) => v.toFixed(2);
  return `${fmt(values[Math.floor(values.length / 2)]!)} (${fmt(values[0]!)}..${fmt(values.at(-1)!)})`;
};
console.log(`anchor scroll: ${UPDATES} scroll updates of an open menu, p50 (min..max) of ${RUNS} runs`);
console.log(`  layouts/update ${stat("layouts")}`);
console.log(`  ms             ${stat("ms")}`);
