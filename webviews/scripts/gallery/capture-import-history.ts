// l10n-allow-file: capture script for the import-history placement prototype.
// Captures each placement of the "Bring your history" prototype (src/prototypes/import-history) from a
// built gallery in headless Chromium, dark, one PNG per case. Run on cmux-ci (never on a laptop):
//   bun run gallery:build && bun scripts/gallery/capture-import-history.ts <out dir>
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? "import-history-shots");
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
const base = `http://127.0.0.1:${address.port}`;

const cases = [
  { file: "a-chief-first-turn", entry: "prototype.import-history-chief-turn", variant: "offer", w: 560, h: 340 },
  {
    file: "a2-chief-first-turn-running",
    entry: "prototype.import-history-chief-turn",
    variant: "running",
    w: 560,
    h: 340,
  },
  {
    file: "b-settings-agents-card",
    entry: "prototype.import-history-settings",
    variant: "agents-card",
    w: 1100,
    h: 720,
  },
  { file: "c-new-tab-chip", entry: "prototype.import-history-new-tab", variant: "chip", w: 760, h: 300 },
  { file: "c2-new-tab-chip-running", entry: "prototype.import-history-new-tab", variant: "running", w: 760, h: 300 },
];

const browser = await chromium.launch();
let failed = 0;
try {
  for (const c of cases) {
    const context = await browser.newContext({
      viewport: { width: c.w, height: c.h },
      deviceScaleFactor: 2,
      colorScheme: "dark",
    });
    const page = await context.newPage();
    page.on("pageerror", (error) => console.error(`${c.file}: page error ${error.message}`));
    const query = new URLSearchParams({
      entry: c.entry,
      variant: c.variant,
      colorScheme: "dark",
      width: String(c.w),
      frame: "component",
    });
    try {
      await page.goto(`${base}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 60_000,
      });
      await page.mouse.move(0, 0);
      await page.evaluate(
        () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 600)))),
      );
      await page.screenshot({ path: path.join(out, `${c.file}.png`) });
      console.log(`captured ${c.file}`);
    } catch (error) {
      failed++;
      console.error(`${c.file}: ${(error as Error).message}`);
      await page.screenshot({ path: path.join(out, `${c.file}-FAILED.png`) }).catch(() => {});
    }
    await context.close();
  }
} finally {
  await browser.close();
  server.httpServer.close();
}
process.exit(failed ? 1 : 0);
