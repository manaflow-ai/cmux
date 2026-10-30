// Scratch: before/after captures of the inline effort picker for PR #27849. Not for merge.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(240_000);
const { createServer } = await import("vite");
let vite: Awaited<ReturnType<typeof createServer>>;
let browser: Browser;
beforeAll(async () => {
  const root = path.resolve(import.meta.dir, "..");
  vite = await createServer({
    root,
    configFile: path.join(root, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.inline-model-effort", { browser });
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});

for (const variant of ["codex", "codex-hover"])
  test(`shot ${variant}`, async () => {
    const page = await browser.newPage({ viewport: { width: 680, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark" });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.inline-model-effort", { variant, width: 680, height: 900, theme: "dark" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForTimeout(400);
    const menu = page.locator(".acpmux-quick-menu").first();
    const png = await menu.screenshot();
    const b64 = png.toString("base64");
    for (let i = 0; i < b64.length; i += 4000) console.log(`SHOT ${variant} ${i} ${b64.slice(i, i + 4000)}`);
    console.log(`SHOT ${variant} END`);
    await page.close();
  });
