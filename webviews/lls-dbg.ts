// debug probe: per closed preview, box and line rects
import { chromium } from "playwright";
import path from "node:path";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";
const webviews = process.cwd();
const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const browser = await chromium.launch({ headless: true });
await warmGalleryFrame(vite, ["agent-pane.thought-shapes"], { browser });
const { port } = vite.httpServer.address();
const page = await browser.newPage({ viewport: { width: 360, height: 900 } });
for (const variant of ["short", "wrapping-line"]) {
  await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.thought-shapes", { variant, frame: "component", width: 360 })}`);
  await page.locator(".cv-tool, .cv-worked").first().waitFor({ state: "visible" });
  const worked = page.locator("button.cv-worked.is-toggle").last();
  if (await worked.count()) await worked.click();
  await page.waitForTimeout(800);
  const out = await page.evaluate(() => [...document.querySelectorAll(".cv-thought__preview")].map((b) => {
    const s = getComputedStyle(b); const r = b.getBoundingClientRect(); const range = document.createRange(); range.selectNodeContents(b);
    return { cls: b.className, box: [r.top, r.bottom, r.width], pad: [s.paddingTop, s.paddingBottom, s.marginTop], disp: s.display, clamp: s.webkitLineClamp, ov: s.overflow, lines: [...range.getClientRects()].map((l) => [Math.round(l.top), Math.round(l.bottom), Math.round(l.width)]).slice(0, 6), text: b.textContent.slice(0, 50) };
  }));
  console.log("DBG", variant, JSON.stringify(out));
  await page.locator(".cv-thought").first().screenshot({ path: `${process.env.FAST_CHECKS_OUT}/${variant}-${process.env.LOOK}.png` }).catch(() => {});
}
await browser.close(); await vite.close();
