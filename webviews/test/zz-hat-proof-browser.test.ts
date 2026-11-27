// l10n-allow-file: scratch proof capture, not committed.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(280_000);
const ENTRY = "agent-pane.subagent-tray";
const webviews = path.resolve(import.meta.dir, "..");
const out = process.env.FAST_CHECKS_OUT ?? "/tmp/hat-proof";
mkdirSync(out, { recursive: true });
const { createServer } = await import("vite");
let vite: Awaited<ReturnType<typeof createServer>> | undefined;
let browser: Browser | undefined;

beforeAll(async () => {
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, ENTRY, { browser });
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});

for (const theme of ["dark", "light"]) {
  test(`hat ${theme}`, async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 520 }, deviceScaleFactor: 2 });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(ENTRY, { frame: "component", theme }));
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(out, `subagent-tray-${theme}.png`) });
    const text = await page.evaluate(() => document.body.innerText);
    console.log(`hat-proof ${theme}: one-line text present=${/subagents? working/.test(text)}`);
    expect(text).not.toMatch(/subagents? working/);
    await page.close();
  });
}
