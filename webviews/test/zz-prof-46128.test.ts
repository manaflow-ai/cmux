// Temporary CPU profile (not committed).
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import { copyFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmViteServer } from "./support/warmDevServer";
setDefaultTimeout(3_000_000);
const { createServer } = await import("vite");
const webviews = path.resolve(import.meta.dir, "..");
const PAGE = "/test/browser/session-info-expand.html";
const TARGET = path.join(webviews, "src/agent-session/acpmux/session-info/WindowedRows.tsx");
let vite: any;
let browser: Browser | undefined;
beforeAll(async () => {
  vite = await createServer({ root: webviews, configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false, hmr: false }, logLevel: "error" });
  await vite.listen();
  await warmViteServer(vite, PAGE);
  browser = await chromium.launch({ headless: true });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
test("prof", async () => {
  const { port } = vite.httpServer.address();
  for (const v of (process.env.PROF_VARIANTS ?? "base,fix3").split(",")) {
    copyFileSync(`/tmp/46128/${v}.tsx`, TARGET);
    await new Promise((r) => setTimeout(r, 300));
    for (const list of (process.env.PROF_LISTS ?? "alsoHere").split(",")) {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      await page.goto(`http://127.0.0.1:${port}${PAGE}?list=${list}&n=5000&v=${v}`);
      await page.waitForFunction(() => typeof (window as any).__expand === "function");
      for (let i = 0; i < 4; i++) await page.evaluate(() => (window as any).__expand());
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
      for (let i = 0; i < 40; i++) {
        await page.evaluate(() => (window as any).__expand());
        await page.evaluate(() => (window as any).__expand());
      }
      const { profile } = await cdp.send("Profiler.stop");
      const dt: Record<number, number> = {};
      for (let i = 0; i < profile.samples!.length; i++) dt[profile.samples![i]!] = (dt[profile.samples![i]!] ?? 0) + profile.timeDeltas![i]!;
      const self: Record<string, number> = {};
      const byId = new Map(profile.nodes.map((n) => [n.id, n]));
      const parent = new Map<number, number>();
      for (const n of profile.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
      const incl: Record<string, number> = {};
      for (const n of profile.nodes) {
        const t = dt[n.id] ?? 0;
        if (!t) continue;
        const f = n.callFrame;
        const k = `${f.functionName || "(anon)"} ${f.url.split("/").pop()?.split("?")[0]}:${f.lineNumber}`;
        self[k] = (self[k] ?? 0) + t;
        // inclusive for WindowedRows frames
        const seen = new Set<string>();
        for (let at: number | undefined = n.id; at !== undefined; at = parent.get(at)) {
          const g = byId.get(at)!.callFrame;
          if (!g.url.includes("WindowedRows")) continue;
          const gk = `${g.functionName || "(anon)"}:${g.lineNumber}`;
          if (seen.has(gk)) continue;
          seen.add(gk);
          incl[gk] = (incl[gk] ?? 0) + t;
        }
      }
      const top = Object.entries(self).sort((a, b) => b[1] - a[1]).slice(0, 18).map(([k, t]) => `${(t / 1000 / 40).toFixed(2)} ${k}`);
      const wr = Object.entries(incl).sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, t]) => `${(t / 1000 / 40).toFixed(2)} ${k}`);
      console.log(`PROF ${v} ${list} self ms/open-close:\n  ${top.join("\n  ")}\n PROF ${v} WindowedRows inclusive:\n  ${wr.join("\n  ")}`);
      await page.close();
    }
  }
});
