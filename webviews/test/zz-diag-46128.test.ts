// Temporary diagnostic (not committed): raw press samples, split into script and layout time.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmViteServer } from "./support/warmDevServer";
setDefaultTimeout(900_000);
const { createServer } = await import("vite");
const webviews = path.resolve(import.meta.dir, "..");
const PAGE = "/test/browser/session-info-expand.html";
let vite: any;
let browser: Browser | undefined;
beforeAll(async () => {
  vite = await createServer({ root: webviews, configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  await warmViteServer(vite, PAGE);
  browser = await chromium.launch({ headless: true });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
const PRESS: Record<string, [string, string]> = {
  tasks: ["[data-section=tasks] .acpmux-session-info-fold", "ul[data-finished]"],
  usage: [".acpmux-session-info-usage-fold", "ul[data-sort]"],
  alsoHere: ["#open", "ul[data-also-here]"],
};
const N = Number(process.env.DIAG_PRESSES || 41);
test("diag", async () => {
  const { port } = vite.httpServer.address();
  const out: Record<string, unknown> = {};
  for (const list of Object.keys(PRESS)) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${PAGE}?list=${list}&n=5000`);
    await page.waitForFunction(() => typeof (window as any).__expand === "function");
    page.on("console", (m) => { if (m.text().startsWith("WR ")) console.log(list, m.text()); });
    const samples = [];
    for (let i = 0; i <= N; i++) {
      const s = await page.evaluate(async ([press, sel]) => {
        const painted = () => new Promise<void>((r) => requestAnimationFrame(() => { const c = new MessageChannel(); c.port1.onmessage = () => r(); c.port2.postMessage(0); }));
        const b = document.querySelector<HTMLElement>(press)!; let added = 0, removed = 0, attrs = 0; const mo = new MutationObserver((ms) => { for (const m of ms) { if (m.type === 'attributes') attrs++; for (const n of m.addedNodes) if ((n as Element).tagName === 'LI') added++; for (const n of m.removedNodes) if ((n as Element).tagName === 'LI') removed++; } }); mo.observe(document.body, { subtree: true, childList: true, attributes: true });
        const t0 = performance.now(); console.log("WR click", t0.toFixed(1)); b.click(); await Promise.resolve(); await Promise.resolve(); const t1 = performance.now();
        document.querySelector(sel)?.getBoundingClientRect(); const t2 = performance.now();
        await painted(); const t3 = performance.now(); console.log("WR painted", t3.toFixed(1)); mo.takeRecords(); mo.disconnect();
        const rows = document.querySelectorAll(`${sel} > li:not([data-rows-rest])`).length;
        await new Promise((r) => setTimeout(r, 50));
        b.isConnected ? b.click() : document.querySelector<HTMLElement>(press)!.click();
        await painted(); await new Promise((r) => setTimeout(r, 50));
        return { script: t1 - t0, layout: t2 - t1, total: t3 - t0, rows, added, removed, attrs };
      }, PRESS[list]!);
      if (i > 0) samples.push(s);
    }
    const med = (k: string) => { const v = samples.map((x: any) => x[k]).sort((a, b) => a - b); return Math.round(v[Math.floor(v.length / 2)] * 10) / 10; };
    out[list] = { script: med("script"), layout: med("layout"), total: med("total"), rows: (samples[0] as any).rows, added: (samples[0] as any).added, removed: (samples[0] as any).removed, attrs: (samples[0] as any).attrs };
    await page.close();
  }
  console.log(`DIAG ${process.env.DIAG_LABEL} ${JSON.stringify(out)}`);
});
