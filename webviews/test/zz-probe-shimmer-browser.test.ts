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
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
for (const [entry, variant] of SCENES)
for (const band of [false, true])
test(`probe ${entry}#${variant} band=${band}`, async () => {
  const page = await browser.newPage({ viewport: { width: 800, height: 1100 }, deviceScaleFactor: 2 });
  const port = vite.httpServer.address().port;
  page.on("pageerror", (e) => console.log("PAGEERR", e.message));
  page.on("console", (m) => { if (m.type() === "error") console.log("CONSOLE", m.text().slice(0, 300)); });
  await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { ...(variant ? { variant } : {}), width: 640 })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
  if (band) await page.evaluate(() => { document.documentElement.dataset.thinkingBand = ""; document.documentElement.style.setProperty("--cv-shimmer-band", "48px"); });
  await page.waitForTimeout(300);
  const report = await page.evaluate(async () => {
    const out: string[] = [];
    const bands = [...document.querySelectorAll<HTMLElement>(".cv-shimmer__band")];
    for (const b of bands) b.classList.add("is-shimmer-active");
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    for (const a of document.getAnimations()) { a.pause(); const d = Number(a.effect?.getComputedTiming().duration) || 1000; a.currentTime = 0.5 * d; }
    await new Promise((r) => requestAnimationFrame(r));
    const f = (r?: DOMRect) => r ? `${r.left.toFixed(1)}-${r.right.toFixed(1)}` : "none";
    for (const b of bands) {
      const row = b.closest(".cv-worked, .cv-activity, .cv-tool") as HTMLElement;
      const base = b.parentElement!.querySelector(".cv-shimmer__base")?.getBoundingClientRect();
      const litL = b.querySelector(".cv-shimmer__lit-label")?.getBoundingClientRect();
      const litT = b.querySelector(".cv-shimmer__lit-time")?.getBoundingClientRect();
      const time = row?.querySelector(":scope .cv-shimmer__row > .cv-worked__time, :scope .cv-shimmer__row > .cv-worked__own, .cv-activity__time")?.getBoundingClientRect();
      const rowBox = b.parentElement!.getBoundingClientRect();
      const ff = (sel: string) => { const e = row?.querySelector(sel); return e ? getComputedStyle(e).fontVariantNumeric + "/" + getComputedStyle(e).fontSize : ""; };
      out.push(`[${(row?.textContent ?? "").slice(0, 34).replace(/\s+/g, " ")}] cb ${f(rowBox)} base ${f(base)} litLabel ${f(litL)} | time ${f(time)} litTime ${f(litT)} num ${ff(".cv-worked__time, .cv-activity__time")} vs ${ff(".cv-shimmer__lit-time")}`);
    }
    return out.join("\n");
  });
  console.log(`== ${entry}#${variant} band=${band}\n${report}`);
  for (const ph of [0.3, 0.6, 0.85, 0.95]) {
    await page.evaluate((p) => { for (const x of document.getAnimations()) { x.pause(); const d = Number(x.effect?.getComputedTiming().duration) || 1000; x.currentTime = p * d; } }, ph);
    await page.waitForTimeout(50);
    await page.screenshot({ path: `/home/cmux/probe-shimmer-${entry.split(".")[1]}-${band}-${ph}.png`, clip: { x: 0, y: 0, width: 560, height: 820 } });
  }
  await page.close();
  expect(1).toBe(1);
});
