// Scratch (not committed): before/after stills of the chat's composer and a subagent's, light and dark.
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";

const out = process.env.FAST_CHECKS_OUT ?? "/tmp/shots";
const tag = process.env.TAG ?? "shot";
const { createServer } = await import("vite");
const server = await createServer({
  root: path.resolve(import.meta.dir),
  configFile: path.resolve(import.meta.dir, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await server.listen();
const browser = await chromium.launch({ headless: true });
const entry = "agent-pane.subagents";
const variants = (process.env.VARIANTS ?? "own-pane-chat,own-pane").split(",");
await warmGalleryFrame(server, entry, { browser, params: { variant: variants[0]! } });
const port = (server.httpServer!.address() as { port: number }).port;
for (const variant of variants)
  for (const colorScheme of ["light", "dark"]) {
    const page = await browser.newPage({
      viewport: { width: 900, height: 640 },
      deviceScaleFactor: 2,
      colorScheme: colorScheme as "light" | "dark",
    });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", null, {
        timeout: 60_000,
      });
      await page.waitForTimeout(400);
      const clip = await page.evaluate(() => {
        const box = document.querySelector(".acpmux-composer")!.getBoundingClientRect();
        const top = Math.max(0, box.top - 90);
        return {
          x: 0,
          y: top,
          width: window.innerWidth,
          height: Math.min(window.innerHeight - top, box.bottom - top + 20),
        };
      });
      const png = await page.screenshot({ clip });
      console.log(`SHOT ${tag}-${variant}-${colorScheme} ${png.toString("base64")}`);
      console.log("shot", tag, variant, colorScheme);
    } catch (error) {
      console.log("FAILED", variant, colorScheme, error);
    } finally {
      await page.close();
    }
  }
await browser.close();
await server.close();
