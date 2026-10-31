// Throwaway capture for PR #28324's media; never committed.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(300_000);
const webviews = path.resolve(import.meta.dir, "..");
let vite: any;
let browser: Browser;
const shots: [string, string, string, (page: Page) => Promise<void>][] = [
  ["tool-row", "agent-pane.tool-row-column", "column", async (page) => {
    const row = page.locator(".cv-tool", { hasText: "Read" }).first();
    await row.click({ timeout: 3000 }).catch(() => undefined);
  }],
  ["agent-message", "agent-pane.agent-message-row", "lanes", async (page) => {
    await page.locator(".cv-agentmsg__line > [data-interactive]").first().click({ timeout: 3000 }).catch(() => undefined);
  }],
];
beforeAll(async () => {
  const { createServer } = await import("vite");
  vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1", strictPort: false }, logLevel: "error" });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  for (const [, entry, variant] of shots) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
});
afterAll(async () => { await browser?.close(); await vite?.close(); });
test("capture", async () => {
  const { port } = vite.httpServer.address();
  for (const [name, entry, variant, act] of shots) {
    const page = await browser.newPage({ viewport: { width: 640, height: 520 }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForLoadState("networkidle");
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    await act(page);
    await page.waitForTimeout(900);
    const png = (await page.screenshot()).toString("base64");
    console.log(`SHOT_${name}=${png}`);
    await page.close();
  }
});
