import path from "node:path";
import { chromium, type Browser } from "playwright";
import { createServer } from "vite";
import { loadEntrySources } from "../scripts/gallery/entries";
const webviews = path.resolve(import.meta.dir, "..");
const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error", plugins: process.env.CACHE ? [{ name: "cache", configureServer(server: any) { server.middlewares.use((req: any, res: any, next: any) => { (globalThis as any).__req = ((globalThis as any).__req ?? 0) + 1; const a = performance.now(); res.on("finish", () => { (globalThis as any).__ms = ((globalThis as any).__ms ?? 0) + performance.now() - a; const u = String(req.url).replace(/\?.*/, ""); const m = ((globalThis as any).__u ??= new Map()); m.set(u, (m.get(u) ?? 0) + 1); }); const set = res.setHeader.bind(res); res.setHeader = (k: string, v: any) => set(k, k.toLowerCase() === "cache-control" && String(v) === "no-cache" ? "private, max-age=3600" : v); next(); }); } }] : [] });
await vite.listen();
const port = (vite.httpServer!.address() as any).port;
const sources = (await loadEntrySources()).filter(({ entry }) => entry.host !== "native");
const pick = (process.env.ENTRIES ?? "").split(",").filter(Boolean);
const chosen = sources.filter((s) => pick.includes(s.entry.id));
const W = Number(process.env.W ?? 1);
const browsers = Number(process.env.B ?? 1);
const bs: Browser[] = [];
import fs from "node:fs"; import os from "node:os";
for (let i = 0; i < browsers; i++) {
  if (process.env.P) {
    const ctx = await chromium.launchPersistentContext(fs.mkdtempSync(path.join(os.tmpdir(), "cc-")), { headless: true, viewport: { width: 760, height: 900 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
    bs.push({ newPage: () => ctx.newPage(), close: () => ctx.close() } as any);
  } else bs.push(await chromium.launch({ headless: true, args: (process.env.ARGS ?? "").split(" ").filter(Boolean) }));
}
const url = (entry: any, src: string, s: any) => `http://127.0.0.1:${port}/gallery/frame.html?${new URLSearchParams({ entry: entry.id, variant: Object.keys(entry.variants)[0]!, entryPath: src, frame: "component", reducedMotion: "true", ...s })}`;
// warm
{ const p = await bs[0]!.newPage(); for (const { entry, path: src } of chosen) { await p.goto(url(entry, src, {})); await p.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60000 }); } await p.close(); }
(globalThis as any).__req = 0; (globalThis as any).__ms = 0; (globalThis as any).__u = new Map();
const times: number[] = [];
const t0 = performance.now();
await Promise.all(Array.from({ length: W }, async (_, w) => {
  const page = await bs[w % browsers]!.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
  for (const { entry, path: src } of chosen) for (const s of [{ colorScheme: "light" }, { background: "busy" }]) {
    const a = performance.now();
    await page.goto(url(entry, src, s));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60000 });
    times.push(performance.now() - a);
  }
}));
const wall = performance.now() - t0;
times.sort((a, b) => a - b);
console.log(`W=${W} B=${browsers} loads=${times.length} wall=${Math.round(wall)} p50=${Math.round(times[times.length >> 1]!)} max=${Math.round(times.at(-1)!)} throughput=${(times.length / wall * 1000).toFixed(2)}/s`);
console.log("server requests", (globalThis as any).__req, "ms", Math.round((globalThis as any).__ms)); console.log([...(globalThis as any).__u].sort((a: any, b: any) => b[1] - a[1]).slice(0, 15));
for (const b of bs) await b.close();
await vite.close();
process.exit(0);
