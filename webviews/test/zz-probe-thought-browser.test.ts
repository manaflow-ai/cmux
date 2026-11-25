import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame } from "./support/galleryFrame";
setDefaultTimeout(300_000);
let vite: any; let browser: Browser;
beforeAll(async () => {
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  browser = await chromium.launch({ headless: true, executablePath: "/usr/bin/google-chrome" });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
test("probe", async () => {
  const page = await browser.newPage({ viewport: { width: 800, height: 1100 }, deviceScaleFactor: 2 });
  const port = vite.httpServer.address().port;
  await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.claude-desktop-organization", { variant: "shared", width: 760, reducedMotion: "true" })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
  await page.evaluate(() => document.fonts.ready);
  const rowsDump = await page.evaluate(() => [...document.querySelectorAll(".acpmux-row")].map((n) => n.className.slice(0,80) + " / " + (n.textContent ?? "").replace(/\s+/g," ").slice(0,90)));
  console.log(rowsDump.join("\n"));
  const out = await page.evaluate(() => [...document.querySelectorAll(".cv-step-thought")].map((b) => {
    const parts = [...b.children].map((c) => { const r = c.getBoundingClientRect(); const cs = getComputedStyle(c); return `${c.tagName}.${String((c as any).className?.baseVal ?? c.className)} L${r.left.toFixed(1)} R${r.right.toFixed(1)} T${r.top.toFixed(1)} H${r.height.toFixed(1)} ws=${cs.whiteSpace} ov=${cs.textOverflow} disp=${cs.display}`; });
    const cs = getComputedStyle(b);
    return `${b.className} disp=${cs.display} cols=${cs.gridTemplateColumns}\n  ` + parts.join("\n  ") + "\n  HTML " + b.outerHTML.slice(0, 600);
  }));
  console.log(out.join("\n"));
  await page.screenshot({ path: "/home/cmux/probe-thought.png", fullPage: true });
  expect(out.length).toBeGreaterThan(0);
});
