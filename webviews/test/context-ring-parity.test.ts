// The context affordance is one compact control in Claude's quiet footer and Codex's inner row
// (HQ #3322/#3325). The fuller breakdown stays in the shared context card and Session Info.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("context-ring-parity.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("context ring parity", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "claude-chat" } });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "codex-chat" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (page: Page, variant: string) => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.waitForSelector(".acpmux-context-ring");
  };

  test("Claude and Codex use the same hit area and glyph size", async () => {
    const context = await browser.newContext({ viewport: { width: 760, height: 420 } });
    const page = await context.newPage();
    const measure = () =>
      page.$eval(".acpmux-context-ring", (ring) => {
        const box = ring.getBoundingClientRect();
        const glyph = ring.querySelector("svg")!.getBoundingClientRect();
        return { width: box.width, height: box.height, glyphWidth: glyph.width, glyphHeight: glyph.height };
      });
    await open(page, "claude-chat");
    const claude = await measure();
    await open(page, "codex-chat");
    const codex = await measure();
    expect(claude).toEqual(codex);
    expect(claude).toEqual({ width: 22, height: 22, glyphWidth: 12, glyphHeight: 12 });
    await context.close();
  });
});
