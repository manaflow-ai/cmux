import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
setDefaultTimeout(300_000);
const SCENES = [
  ["agent-pane.turn-boundary-gaps", "inbox-read"],
  
  
];
let vite: any; let browser: Browser;
beforeAll(async () => {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  browser = await chromium.launch({ headless: true });

});
afterAll(async () => { await browser?.close(); await vite?.close(); });
for (const [entry, variant] of SCENES)
test(`probe ${entry}#${variant}`, async () => {
  const page = await browser.newPage({ viewport: { width: 800, height: 1100 } });
  const port = vite.httpServer.address().port;
  await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760, reducedMotion: "true" })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
  await page.waitForTimeout(1500);
  const rows = await page.evaluate(() => [...document.querySelectorAll(".acpmux-row")].map((n) => {
    const r = n.getBoundingClientRect();
    const kids = [...n.querySelectorAll("*")].map((k) => k.getBoundingClientRect()).filter((b) => b.height > 0);
    const inkTop = Math.min(...kids.map((b) => b.top), r.bottom), inkBottom = Math.max(...kids.map((b) => b.bottom), r.top);
    return `${n.className.slice(0, 90)} | top ${r.top.toFixed(1)} h ${r.height.toFixed(1)} ink ${inkTop.toFixed(1)}-${inkBottom.toFixed(1)} | ${(n.textContent ?? "").slice(0, 50).replace(/\s+/g, " ")}`;
  }));
  console.log(`== ${entry}#${variant}\n` + rows.join("\n"));
  const detail = await page.evaluate(() => {
    const out: string[] = [];
    const foot = [...document.querySelectorAll(".acpmux-row.acpmux-turnSummary")][0]!;
    const next = foot.nextElementSibling ?? [...document.querySelectorAll(".acpmux-row")][[...document.querySelectorAll(".acpmux-row")].indexOf(foot) + 1]!;
    for (const root of [foot, next]) {
      const walk = (n: Element, d: number) => { const b = n.getBoundingClientRect(); const cs = getComputedStyle(n);
        out.push(`${"  ".repeat(d)}${n.tagName.toLowerCase()}.${String(n.className?.baseVal ?? n.className).slice(0,70)} top ${b.top.toFixed(1)} bot ${b.bottom.toFixed(1)} h ${b.height.toFixed(1)} pad ${cs.paddingTop}/${cs.paddingBottom} mar ${cs.marginTop}/${cs.marginBottom} minh ${cs.minHeight} pos ${cs.position}`);
        if (d < 5) for (const c of n.children) walk(c, d + 1); };
      walk(root, 0);
    }
    return out.join("\n");
  });
  
  await page.screenshot({ path: `/home/cmux/probe-${variant}.png` });
  await page.close();
  expect(rows.length).toBeGreaterThan(0);
});
