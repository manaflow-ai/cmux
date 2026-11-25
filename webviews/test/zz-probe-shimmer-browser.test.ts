import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
setDefaultTimeout(300_000);
const SCENES: [string, string][] = [
  ["agent-pane.live-spot-shimmer", "plain"],
  ["agent-pane.tool-row-shimmer", ""],
];
let vite: any; let browser: Browser;
beforeAll(async () => {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  browser = await chromium.launch({ headless: true, executablePath: process.env.CMUX_BROWSER_EXECUTABLE });
  for (const [e, v] of SCENES) await warmGalleryFrame(vite, e, { browser, params: v ? { variant: v } : {} });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
for (const [entry, variant] of SCENES)
for (const band of [false, true])
test(`probe ${entry}#${variant} band=${band}`, async () => {
  const page = await browser.newPage({ viewport: { width: 800, height: 1100 } });
  const port = vite.httpServer.address().port;
  await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { ...(variant ? { variant } : {}), width: 640 })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
  if (band) await page.evaluate(() => { document.documentElement.dataset.thinkingBand = ""; document.documentElement.style.setProperty("--cv-shimmer-band", "48px"); });
  await page.waitForTimeout(300);
  const report = await page.evaluate(async () => {
    const out: string[] = [];
    const bands = [...document.querySelectorAll<HTMLElement>(".cv-shimmer__band, .cv-row-shimmer")];
    for (const b of bands) { b.classList.add("is-shimmer-active"); }
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    for (const p of [0, 0.25, 0.5, 0.75, 0.9, 0.97, 1]) {
      for (const a of document.getAnimations()) { a.pause(); const d = Number(a.effect?.getComputedTiming().duration) || 1000; a.currentTime = Math.min(p, 0.999) * d; }
      await new Promise((r) => requestAnimationFrame(r));
      for (const b of bands) {
        const isRow = b.classList.contains("cv-row-shimmer");
        const bandEl = isRow ? b.querySelector<HTMLElement>(".cv-row-shimmer__band")! : b;
        const lit = bandEl.querySelector<HTMLElement>(isRow ? ".cv-row-shimmer__lit" : ".cv-shimmer__lit")!;
        // the label's own words box
        const own = isRow ? b.parentElement! : (b.parentElement!.querySelector<HTMLElement>(".cv-shimmer__base") ?? b.parentElement!);
        const ob = own.getBoundingClientRect();
        // the box the band may paint in: its clip chain
        let L = -1e9, R = 1e9;
        const bb = bandEl.getBoundingClientRect(); L = Math.max(L, bb.left); R = Math.min(R, bb.right);
        if (isRow) { const cb = b.getBoundingClientRect(); L = Math.max(L, cb.left); R = Math.min(R, cb.right); }
        for (let n: HTMLElement | null = bandEl.parentElement; n && n !== document.body; n = n.parentElement) {
          const cs = getComputedStyle(n);
          if (cs.overflowX !== "visible") { const r = n.getBoundingClientRect(); L = Math.max(L, r.left); R = Math.min(R, r.right); }
        }
        // painted lit text extent: union of lit children boxes (or lit box)
        const kids = [...lit.children].map((k) => k.getBoundingClientRect()).filter((r) => r.width > 0);
        const lb = lit.getBoundingClientRect();
        const tl = kids.length ? Math.min(...kids.map((k) => k.left)) : lb.left, tr = kids.length ? Math.max(...kids.map((k) => k.right)) : lb.right;
        const vl = Math.max(L, tl), vr = Math.min(R, tr);
        if (vr > vl && (vr > ob.right + 0.5 || vl < ob.left - 0.5)) {
          const row = b.closest(".cv-worked, .cv-activity, .cv-tool, div")!;
          out.push(`p=${p} [${(row.textContent ?? "").slice(0, 40).replace(/\s+/g, " ")}] own ${ob.left.toFixed(1)}-${ob.right.toFixed(1)} visible ${vl.toFixed(1)}-${vr.toFixed(1)} band ${bb.left.toFixed(1)}-${bb.right.toFixed(1)}`);
        }
      }
    }
    return [`${bands.length} bands, ${document.getAnimations().length} anims`, ...out].join("\n");
  });
  console.log(`== ${entry}#${variant} band=${band}\n${report}`);
  for (const a of [0.9]) { await page.evaluate((p) => { for (const x of document.getAnimations()) { const d = Number(x.effect?.getComputedTiming().duration) || 1000; x.currentTime = p * d; } }, a); }
  await page.screenshot({ path: `/home/cmux/probe-shimmer-${entry.split(".")[1]}-${band}.png` });
  await page.close();
  expect(1).toBe(1);
});
