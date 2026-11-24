/// <reference types="bun" />
import { chromium } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await installPaintedFrames(page);
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(${Number(process.argv[2] ?? 3000)})`);
  await page.locator(".acpmux-scroll").hover();
  if (process.env.MINIMAP === "0") await page.evaluate(() => (window as any).__minimap(false));
  const fl = () =>
    page.evaluate(async () => {
      const d = (window as any).__debug;
      await d.startFling(3, { wait: true, nominal_ms: 1000 / 120 });
      const s = d.perfStats();
      return { react: s.react, spans: s.spans, other: s.other };
    });
  await fl();
  if (process.env.TRACE) {
    await browser.startTracing(page, {
      path: process.env.TRACE_OUT ?? "/tmp/tsprof/trace.json",
      categories: [
        "devtools.timeline",
        "disabled-by-default-devtools.timeline",
        "blink.user_timing",
        "disabled-by-default-devtools.timeline.invalidationTracking",
        ...(process.env.SELSTATS ? ["disabled-by-default-blink.debug"] : []),
      ],
    });
    console.log(JSON.stringify(await fl()));
    await browser.stopTracing();
    process.exit(0);
  }
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
  await cdp.send("Profiler.start");
  console.log(JSON.stringify(await fl()));
  const { profile } = await cdp.send("Profiler.stop");
  const byId = new Map(profile.nodes.map((n: any) => [n.id, n]));
  const self = new Map<string, number>();
  const dt = profile.timeDeltas;
  let i = 0;
  for (const id of profile.samples) {
    const n: any = byId.get(id);
    const cf = n.callFrame;
    const k = `${cf.functionName || "(anon)"} ${cf.url.split("/").pop()}:${cf.lineNumber}`;
    self.set(k, (self.get(k) ?? 0) + (dt[i++] ?? 0));
  }
  const tot = [...self.values()].reduce((a, b) => a + b, 0);
  for (const [k, v] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 45))
    console.log((v / 1000).toFixed(1).padStart(8), ((100 * v) / tot).toFixed(1).padStart(5), k);
  await Bun.write("/tmp/tsprof/fling.cpuprofile", JSON.stringify(profile));
} finally {
  await browser.close();
  await served.close();
}
