import path from "node:path";
const root = process.argv[2]; const out = process.argv[3];
process.chdir(root);
const { chromium } = await import(Bun.resolveSync("playwright", root + "/"));
const { createServer } = await import(Bun.resolveSync("vite", root + "/"));
const { galleryFrame } = await import(path.join(root, "test/support/galleryFrame.ts"));
const vite = await createServer({ configFile: path.join(root, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const browser = await chromium.launch({ headless: true });
const url = `http://127.0.0.1:${vite.httpServer.address().port}${galleryFrame("agent-pane.since-divider", { variant: "line-worked-tokens" })}`;
// warm
const warm = await browser.newPage(); await warm.goto(url); await warm.locator(".cv-worked").first().waitFor(); await warm.close();
const ctx = await browser.newContext({ viewport: { width: 440, height: 300 }, recordVideo: { dir: out, size: { width: 440, height: 300 } } });
const page = await ctx.newPage();
await page.goto(url); await page.locator(".cv-worked").first().waitFor(); await page.waitForTimeout(800);
const sweep = async (from: number, to: number) => { const s = from > to ? -4 : 4; for (let w = from; s < 0 ? w >= to : w <= to; w += s) { await page.setViewportSize({ width: w, height: 300 }); await page.waitForTimeout(40); } };
await sweep(440, 120); await page.waitForTimeout(800); await sweep(120, 440); await page.waitForTimeout(800);
await ctx.close(); await browser.close(); await vite.close();
