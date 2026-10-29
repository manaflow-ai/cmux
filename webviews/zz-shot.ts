// Capture (not committed): gallery stills in Linux Chromium, printed base64 between markers.
import path from "node:path";
import { readFileSync } from "node:fs";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./test/support/galleryFrame";

const label = process.argv[2]!;
const shots: [string, string, Record<string, string | number>, string?][] = JSON.parse(process.argv[3]!);
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(process.cwd(), "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch({ headless: true });
const port = (vite.httpServer!.address() as { port: number }).port;
const warmed = new Set<string>();
for (const [name, entry, params, selector] of shots) {
  try {
    if (!warmed.has(entry)) {
      await warmGalleryFrame(vite, entry, { browser, params: { variant: String(params.variant) } });
      warmed.add(entry);
    }
    const page = await browser.newPage({ viewport: { width: Number(params.width ?? 640), height: Number(params.height ?? 520) }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, params)}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 120_000 });
    await page.waitForFunction(() => Boolean(document.querySelector(".cv-shell .cv-line")), undefined, { timeout: 60_000 });
    if (selector) await page.evaluate((s) => document.querySelector(s)?.scrollIntoView({ block: "center" }), selector);
    await page.mouse.move(2, 2);
    // fixed-wait: let the fold's motion and fonts settle before the still.
    await page.waitForTimeout(900);
    const file = `/tmp/shot-${label}-${name}.png`;
    const target = selector ? page.locator(selector).first() : page;
    await (selector ? target.screenshot({ path: file }) : page.screenshot({ path: file }));
    const data = readFileSync(file).toString("base64");
    for (let at = 0; at < data.length; at += 3000) console.log(`@@SHOT ${label}-${name} ${at / 3000} ${data.slice(at, at + 3000)}`);
    console.log(`@@DONE ${label}-${name} ${Math.ceil(data.length / 3000)}`);
    await page.close();
  } catch (error) {
    console.log(`@@FAIL ${label}-${name} ${String(error).split("\n")[0]}`);
  }
}
await browser.close();
await vite.close();
process.exit(0);
