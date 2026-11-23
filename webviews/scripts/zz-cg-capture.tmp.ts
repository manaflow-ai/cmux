import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "../test/support/galleryFrame";
const webviews = path.resolve(import.meta.dir, "..");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
const shots: [string, string[]][] = [
  ["agent-pane.composer-scrollbar", ["lane", "edge", "edge-full", "outside"]],
  ["agent-pane.dock-band", ["shipped", "frost", "frost-ramp", "frost-through"]],
];
for (const [entry, variants] of shots)
  for (const variant of variants)
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, theme })}`, { timeout: 180_000 });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", null, {
        timeout: 180_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(800);
      const file = `/tmp/cg-leo/shots/${entry.split(".")[1]}-${variant}-${theme.includes("Light") ? "light" : "dark"}.png`;
      await page.screenshot({ path: file });
      console.log(file);
      await page.close();
    }
await browser.close();
await vite.close();
