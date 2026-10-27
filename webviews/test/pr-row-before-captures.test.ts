// l10n-allow-file: synthetic gallery evidence of the unchanged base renderer.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { chromium, type Browser } from "playwright";
import { createServer, type ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("pr-row-before-captures.test.ts", () => {
  setDefaultTimeout(120_000);
  const captures = path.resolve(import.meta.dir, "../artifacts/prrow-before");
  let browser: Browser;
  let vite: ViteDevServer;
  beforeAll(async () => {
    mkdirSync(captures, { recursive: true });
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.pr-dock", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    execFileSync("tar", ["-czf", `${captures}.tgz`, "-C", captures, "."]);
  });
  for (const width of [760, 320])
    test(`base PR row at ${width}px`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 420 } });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.pr-dock", { variant: "compact-count", width })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        if (await page.locator("aside.acpmux-chat-inspector").count())
          await page.locator(".acpmux-chat-inspector-toggle").click();
        await page.locator(".acpmux-pr-dock__disclosure").waitFor();
        await page.screenshot({ path: `${captures}/closed-${width}.jpg`, type: "jpeg", quality: 75 });
        await page.locator(".acpmux-pr-dock__disclosure").click();
        await page.locator(".acpmux-pr-dock__chip").first().waitFor();
        await page.screenshot({ path: `${captures}/open-${width}.jpg`, type: "jpeg", quality: 75 });
        expect(await page.locator(".acpmux-pr-dock__dismiss").count()).toBe(4);
      } finally {
        await page.close();
      }
    });
  test("base duplicate copy", async () => {
    const page = await browser.newPage({ viewport: { width: 480, height: 520 } });
    try {
      await page.addInitScript(() => {
        globalThis.cmuxExperiments = { "hover-actions": "all" };
      });
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.copy-controls", { variant: "output" })}`);
      const row = page.locator('[data-row-id="copy-tool"]');
      await row.locator("button.cv-tool").click();
      await row.locator(".cv-tool-output-card").waitFor();
      await row.locator("button.cv-tool").focus();
      await row.hover();
      await page.screenshot({ path: `${captures}/copy-controls.jpg`, type: "jpeg", quality: 75 });
      expect(await row.locator(".acpmux-row__copy").count()).toBe(1);
    } finally {
      await page.close();
    }
  });
});
