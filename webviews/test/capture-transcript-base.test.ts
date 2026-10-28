// Temporary capture-only review harness; it is not shipped.
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "./support/galleryFrame";

const entry = "agent-pane.transcript-type";
const capture = process.env.CMUX_FONT_CAPTURE_DIR;
if (!capture) throw new Error("CMUX_FONT_CAPTURE_DIR is required");
await mkdir(capture, { recursive: true });
const vite = await createServer({
  root: path.resolve(import.meta.dir, ".."),
  configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
for (const [engine, launcher] of [["chromium", chromium], ["webkit", webkit]] as const) {
  const browser = await launcher.launch({ headless: true });
  try {
    for (const theme of ["light", "dark"] as const) {
      const page = await browser.newPage({ viewport: { width: 760, height: 1100 } });
      try {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "reading", theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".cv-edit-diff__body [data-line]").first().waitFor({ state: "attached" });
        await page.locator(".cv-diagram__error").waitFor();
        await page.evaluate(async () => {
          const { setChatDisplay } = await import("/gallery/src/agent-session/acpmux/chatDisplay.ts");
          setChatDisplay({ "agentPane.display.font.size": 28 });
        });
        for (const [width, zoom] of [[760, 1], [390, 1.25]] as const) {
          await page.setViewportSize({ width, height: 1100 });
          await page.evaluate((value) => {
            document.documentElement.style.zoom = String(value);
            document.querySelector("main.acpmux-scroll")!.scrollTop = 0;
          }, zoom);
          await page.screenshot({ path: path.join(capture, `base-${engine}-${theme}-28-${width}.png`) });
        }
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }
}
await vite.close();
