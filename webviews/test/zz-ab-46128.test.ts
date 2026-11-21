// Temporary A/B (not committed): the harness's own __expand press-to-paint, variants interleaved by round.
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
const VARIANTS = (process.env.AB_VARIANTS ?? "base,head").split(",");
const ROUNDS = Number(process.env.AB_ROUNDS || 6);
const K = Number(process.env.AB_PRESSES || 10);
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
test("ab", async () => {
  const { port } = vite.httpServer.address();
  const samples: Record<string, Record<string, number[]>> = {};
  const rows: Record<string, Record<string, number>> = {};
  for (let round = 0; round < ROUNDS; round++) {
    for (const v of round % 2 ? [...VARIANTS].reverse() : VARIANTS) {
      copyFileSync(`/tmp/46128/${v}.tsx`, TARGET);
      await new Promise((r) => setTimeout(r, 300));
      for (const list of (process.env.AB_LISTS ?? "tasks,usage,alsoHere").split(",")) {
        const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
        try {
        await page.goto(`http://127.0.0.1:${port}${PAGE}?list=${list}&n=5000&v=${v}&r=${round}`);
        await page.waitForFunction(() => typeof (window as any).__expand === "function");
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
        const metrics = async () => Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((m) => [m.name, m.value]));
        for (let press = 0; press <= K; press++) {
          const m0 = await metrics();
          const opened = await page.evaluate(() => (window as any).__expand());
          const m1 = await metrics();
          if (press > 0) {
            ((samples[v] ??= {})[list] ??= []).push(opened.ms);
            for (const key of ["TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration"])
              ((samples[`${v}:${key}`] ??= {})[list] ??= []).push((m1[key] - m0[key]) * 1000);
          }
          (rows[v] ??= {})[list] = opened.rows;
          await page.evaluate(() => (window as any).__expand());
        }
        } catch (error) { console.log(`AB-ERR ${v} ${list} ${String(error).split("\n")[0]}`); }
        await page.close();
      }
    }
  }
  const p = (xs: number[], q: number) => { const s = [...xs].sort((a, b) => a - b); return Math.round(s[Math.floor(s.length * q)]! * 10) / 10; };
  for (const v of Object.keys(samples))
    console.log(`AB ${v} ${JSON.stringify(Object.fromEntries(Object.entries(samples[v]!).map(([l, xs]) => [l, { n: xs.length, p50: p(xs, 0.5), p25: p(xs, 0.25), p75: p(xs, 0.75), rows: rows[v]?.[l] }])))}`);
});
