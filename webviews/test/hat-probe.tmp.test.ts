import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
setDefaultTimeout(300_000);
test("probe", async () => {
  const { createServer } = await import("vite");
  const server = await createServer({ root: path.resolve(import.meta.dir, ".."), configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
  await server.listen();
  const browser = await chromium.launch({ headless: true });
  const entry = "agent-pane.composer-hat-groups";
  await warmGalleryFrame(server, entry, { browser, params: { variant: "two-subagents" } });
  for (const v of ["two-subagents-before"]) for (const width of [900]) { const page = await browser.newPage({ viewport: { width, height: 360 } }); const port0 = (server.httpServer!.address() as { port: number }).port; await page.goto(`http://127.0.0.1:${port0}${galleryFrame(entry, { variant: v, width })}`); await page.waitForSelector(".acpmux-running-tray__head", { timeout: 60000 }); await page.waitForTimeout(1500); await page.screenshot({ path: `/tmp/hatprobe/${v}.png` }); }
  const port = (server.httpServer!.address() as { port: number }).port;
  for (const width of [400, 900]) {
    const page = await browser.newPage({ viewport: { width, height: 360 } });
    page.on("console", (m) => { if (m.type() === "error") console.log("console:", m.text().slice(0, 200)); });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "two-subagents", width })}`);
    await page.waitForSelector(".acpmux-running-tray__head", { timeout: 60000 });
    await page.waitForTimeout(1500);
    const info = await page.evaluate(() => {
      const s = document.querySelector<HTMLElement>(".acpmux-running-tray__summary");
      const l = document.querySelector<HTMLElement>(".acpmux-running-tray__summary-line");
      return { form: s?.dataset.summary, text: document.querySelector(".acpmux-running-tray__head")?.textContent, line: l?.clientWidth };
    });
    console.log(width, JSON.stringify(info));
    await page.screenshot({ path: `/tmp/hatprobe/two-${width}.png` });
  }
  await browser.close(); await server.close();
  expect(1).toBe(1);
});
