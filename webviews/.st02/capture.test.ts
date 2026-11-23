import { test, setDefaultTimeout } from "bun:test";
import path from "node:path";
import { mkdirSync, renameSync, readdirSync } from "node:fs";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";
setDefaultTimeout(600_000);
const ENTRY = "agent-pane.received-sent-activity";
const OUT = process.env.ST02_OUT!;
const TAG = process.env.ST02_TAG!;
test("capture", async () => {
  mkdirSync(OUT, { recursive: true });
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  const browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "leos-1159-closed" } });
  const port = (vite.httpServer!.address() as { port: number }).port;
  const looks: [string, Record<string, string>][] = [["light", { colorScheme: "light" }], ["dark", { colorScheme: "dark" }], ["glass", { colorScheme: "dark", background: "busy" }]];
  const shoot = async (variant: string, look: string, params: Record<string, string>, video = false) => {
    const dir = path.join(OUT, "vid-tmp");
    const context = await browser.newContext({ viewport: { width: 800, height: 640 }, deviceScaleFactor: 2, ...(video && { recordVideo: { dir, size: { width: 800, height: 640 } } }) });
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760, ...params })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(600);
    if (video) {
      for (let i = 0; i < 2; i++) {
        const w = page.locator(".cv-worked").last();
        await w.click(); await page.waitForTimeout(1800);
        await w.click(); await page.waitForTimeout(1200);
      }
      await w_open(page);
    } else await page.screenshot({ path: path.join(OUT, `${TAG}-${variant}-${look}.png`) });
    await context.close();
    if (video) for (const f of readdirSync(dir)) renameSync(path.join(dir, f), path.join(OUT, `${TAG}-${look}-open-close.webm`));
  };
  const w_open = async (page: any) => { await page.locator(".cv-worked").last().click(); await page.waitForTimeout(1500); };
  for (const [look, params] of looks) for (const v of ["leos-1159-opened", "every-kind-running", "every-kind-opened"]) await shoot(v, look, params);
  await shoot("leos-1159-closed", "dark", { colorScheme: "dark" }, true);
  await browser.close(); await vite.close();
});
