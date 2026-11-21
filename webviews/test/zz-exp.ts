import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { loadEntrySources } from "../scripts/gallery/entries";
const webviews = path.resolve(import.meta.dir, "..");
const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const port = (vite.httpServer!.address() as any).port;
const sources = (await loadEntrySources()).filter(({ entry }) => entry.host !== "native");
const pick = (process.env.ENTRIES ?? "").split(",").filter(Boolean);
const chosen = pick.length ? sources.filter((s) => pick.includes(s.entry.id)) : sources.slice(0, 6);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
await page.addInitScript(() => {
  const w = window as any; w.__m = []; w.__lt = [];
  new PerformanceObserver((l) => { for (const e of l.getEntries()) w.__lt.push(`${Math.round(e.startTime)}+${Math.round(e.duration)}`); }).observe({ type: "longtask", buffered: true });
  new MutationObserver((l) => { for (const r of l) w.__m.push([Math.round(performance.now()), r.type, (r.target as Element).nodeName + "." + String((r.target as Element).className ?? "").slice(0, 30) + (r.attributeName ? "@" + r.attributeName : "")]); }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
});
const cdp = await page.context().newCDPSession(page);
await cdp.send("Performance.enable");
const metric = async () => Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((m: any) => [m.name, m.value]));
const schemes = [{}, { colorScheme: "light" }, { colorScheme: "light", highContrast: "1" }, { background: "busy" }];
for (const { entry, path: source } of chosen)
  for (const s of schemes) {
    const q = new URLSearchParams({ entry: entry.id, variant: Object.keys(entry.variants)[0]!, entryPath: source, frame: "component", reducedMotion: "true", ...s });
    const m0 = await metric();
    const t0 = performance.now();
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?${q}`);
    const t1 = performance.now();
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 30000 });
    const t2 = performance.now();
    const m1 = await metric();
    const cpu = `task=${Math.round((m1.TaskDuration - m0.TaskDuration) * 1000)} script=${Math.round((m1.ScriptDuration - m0.ScriptDuration) * 1000)} layout=${Math.round((m1.LayoutDuration - m0.LayoutDuration) * 1000)}`;
    const info = await page.evaluate(() => {
      const r = performance.getEntriesByType("resource") as PerformanceResourceTiming[];
      const nav = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming;
      return { n: r.length, lastResp: Math.round(Math.max(...r.map((x) => x.responseEnd))), dcl: Math.round(nav.domContentLoadedEventEnd), load: Math.round(nav.loadEventEnd), now: Math.round(performance.now()), m: (window as any).__m.length, hist: Object.entries((window as any).__m.reduce((a: any, x: any) => { const k = Math.floor(x[0] / 100) * 100; a[k] = (a[k] ?? 0) + 1; return a; }, {})).map(([k, v]) => `${k}:${v}`).join(" "), lt: (window as any).__lt.join(" "), fonts: document.fonts.status, imgs: document.images.length, lr: (performance.getEntriesByType("resource") as any[]).filter((r) => r.responseEnd > 400).map((r) => `${Math.round(r.startTime)}-${Math.round(r.responseEnd)} ${r.name.slice(-50)}`) };
    });
    console.log(entry.id, JSON.stringify(s), `goto=${Math.round(t1 - t0)} ready=${Math.round(t2 - t1)}`, cpu, JSON.stringify(info));
  }
await browser.close();
await vite.close();
process.exit(0);
