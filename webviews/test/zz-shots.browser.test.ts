// Scratch: before/after captures of the started-chat picker (Claude tab and OpenCode tab). Not for merge.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmViteServer } from "./support/warmDevServer";

setDefaultTimeout(240_000);
const { createServer } = await import("vite");
const webviews = path.resolve(import.meta.dir, "..");
let vite: Awaited<ReturnType<typeof createServer>>;
let browser: Browser;
beforeAll(async () => {
  vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  await warmViteServer(vite, "/test/browser/model-menu-fit.html");
  browser = await chromium.launch({ headless: true });
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});

for (const scheme of ["dark", "light"] as const)
  for (const tab of ["Claude Code", "OpenCode"])
    test(`shot ${tab} ${scheme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 640, height: 900 }, deviceScaleFactor: 2, colorScheme: scheme });
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/model-menu-fit.html`);
      // The native app injects --cmux-* from the theme; a synthetic light palette stands in for it.
      await page.evaluate((light) => {
        const root = document.documentElement;
        root.dataset.theme = light ? "light" : "dark";
        root.style.colorScheme = light ? "light" : "dark";
        const vars = light
          ? { "--cmux-text": "#1d1d1f", "--cmux-elevated-background": "#ffffff", "--cmux-app-window": "#f2f2f4" }
          : { "--cmux-text": "#ececec", "--cmux-elevated-background": "#1e1e1e", "--cmux-app-window": "#080808" };
        for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
        document.body.style.background = light ? "#e9e9ec" : "#161618";
      }, scheme === "light");
      await page.click(".acpmux-picker-button");
      await page.waitForSelector(".acpmux-quick-menu .acpmux-quick-rail-tab");
      if (tab !== "Claude Code") await page.click(`.acpmux-quick-rail-tab[aria-label="${tab}"]`);
      await page.waitForTimeout(400);
      const box = (await page.locator(".acpmux-quick-menu").first().boundingBox())!;
      const pad = 24;
      const clip = { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad), width: box.width + 2 * pad, height: box.height + 2 * pad };
      const b64 = (await page.screenshot({ clip })).toString("base64");
      const key = `${tab.replace(/ /g, "")}-${scheme}`;
      for (let i = 0; i < b64.length; i += 4000) console.log(`SHOT ${key} ${i} ${b64.slice(i, i + 4000)}`);
      await page.close();
    });
