// Scratch, not committed: step 6, hiding the hat. In `row` its control is today's top-edge tuck; in `hide`
// it is the header button. Each is clicked, and the pull tab must take the hat's place.
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";

const out = path.resolve(process.env.FAST_CHECKS_OUT || "hat-hide-shots");
fs.mkdirSync(out, { recursive: true });
const ENTRY = "agent-pane.composer-hat-open";
const server = await createServer({
  root: import.meta.dir,
  configFile: path.join(import.meta.dir, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await server.listen();
const port = (server.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true });
await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "hide-head" } });
const report: Record<string, unknown> = {};
try {
  for (const [arm, variant, control] of [
    ["row", "row-open", ".acpmux-running-tray__tuck"],
    ["hide", "hide-head", ".acpmux-running-tray__hide"],
  ] as const)
    for (const theme of ["light", "dark"]) {
      const page = await browser.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, colorScheme: theme, exp: "composer-hat-open", arm })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const composer = page.locator(".acpmux-composer").first();
      const crop = async (name: string) => {
        await page.waitForTimeout(450);
        const box = (await composer.boundingBox())!;
        await page.screenshot({
          path: path.join(out, `${name}-${theme}.png`),
          clip: { x: box.x - 8, y: Math.max(0, box.y - 200), width: box.width + 16, height: box.height + 208 },
        });
      };
      await page.locator(".acpmux-running-tray__title").hover();
      await page.locator(control).hover();
      await crop(`6a-${arm}-hide-hover`);
      await page.locator(control).click();
      await page.waitForTimeout(500);
      report[`${arm}.${theme}.trayGone`] = (await page.locator(".acpmux-running-tray").count()) === 0;
      report[`${arm}.${theme}.pullTab`] = await page.locator(".acpmux-tray-pull__tab").count();
      await crop(`6b-${arm}-hidden`);
      await page.close();
    }
} finally {
  console.log(`REPORT ${JSON.stringify(report, null, 1)}`);
  for (const name of fs.readdirSync(out).filter((n) => n.endsWith(".png")))
    console.log(`PNGB64 ${name} ${fs.readFileSync(path.join(out, name)).toString("base64")}`);
  await browser.close();
  await server.close();
}
