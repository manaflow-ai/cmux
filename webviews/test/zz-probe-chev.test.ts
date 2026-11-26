import { test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
test("probe", async () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
  await vite.listen();
  const browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.transcript-chevron-column", { browser, params: { variant: "light", colorScheme: "light" } });
  const page = await browser.newPage({ viewport: { width: 760, height: 640 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
  await page.goto(`http://127.0.0.1:${(vite.httpServer!.address() as any).port}${galleryFrame("agent-pane.transcript-chevron-column", { variant: "light", colorScheme: "light" })}`);
  await page.locator("[data-chevron-column]").waitFor({ state: "attached" });
  const m = () => page.evaluate(() => {
    const col = document.querySelector("[data-chevron-column]")!;
    const r = col.getBoundingClientRect();
    return { ready: document.documentElement.dataset.galleryReady, col: [r.left, r.width], chev: [...col.querySelectorAll(".cv-tool__chevron")].map((n) => n.getBoundingClientRect().right), cls: col.className, parent: (col.parentElement as HTMLElement).className, pl: getComputedStyle(col).paddingLeft };
  });
  console.log("t0", JSON.stringify(await m()));
  const cmd = page.locator('[data-label="command"] .cv-command');
  await cmd.hover();
  console.log("hover", JSON.stringify(await m()), JSON.stringify(await page.evaluate(() => [scrollX, document.scrollingElement!.scrollWidth, document.scrollingElement!.clientWidth, [...document.querySelectorAll("*")].filter((n) => n.getBoundingClientRect().right > 751).slice(0, 12).map((n) => [n.tagName, String(n.className).slice(0,60), Math.round(n.getBoundingClientRect().right), getComputedStyle(n).overflowX])])));
  console.log("rows", JSON.stringify(await page.evaluate(() => { const out: any = {}; out.rows = [...document.querySelectorAll(".chevron-column-gallery__row")].map((n) => { const c = getComputedStyle(n); const r = n.getBoundingClientRect(); return [r.left, r.width, c.position, c.left, c.right, c.marginLeft, c.width]; }); out.scrolled = [...document.querySelectorAll("*")].concat([document.documentElement]).filter((n) => n.scrollLeft).map((n) => [n.tagName, String(n.className).slice(0,50), n.scrollLeft, n.scrollWidth, n.clientWidth]); return out; })));
  await browser.close(); await vite.close();
}, 240000);
