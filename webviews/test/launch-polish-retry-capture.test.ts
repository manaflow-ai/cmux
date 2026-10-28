import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import path from "node:path";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { createServer, type ViteDevServer } from "vite";
setDefaultTimeout(240_000);
let vite: ViteDevServer;
let browser: Browser;
beforeAll(async () => {
  vite = await createServer({ configFile: path.join(import.meta.dir, "..", "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.retry-model-menu", { browser, params: { variant: "closed" } });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
test("capture real retry popup after pointer leaves prompt", async () => {
  for (const colorScheme of ["light", "dark"]) {
    const page = await browser.newPage({ viewport: { width: 560, height: 460 } });
    try {
      await page.goto(`http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.retry-model-menu", { variant: "closed", colorScheme, width: 560, height: 460 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator('button[aria-label="Retry with another model"]').click();
      await page.locator('[role="menu"]').waitFor({ state: "visible" });
      await page.mouse.move(4, 4);
      await page.waitForFunction(() => document.getAnimations().every(a => a.playState !== "running" || a.effect?.getTiming().iterations === Infinity));
      console.log("__OPACITY__", colorScheme, await page.locator('.cv-user__actions').evaluate(el => getComputedStyle(el).opacity));
      const encoded = (await page.screenshot({ animations: "disabled" })).toString("base64");
      console.log(`__CAPTURE_BEGIN__${colorScheme}`);
      for (let offset=0; offset<encoded.length; offset+=1000) console.log("__PNG_CHUNK__"+encoded.slice(offset,offset+1000));
      console.log(`__CAPTURE_END__${colorScheme}`);
    } finally { await page.close(); }
  }
});
