// cmux-web-test-timeout: 240
// l10n-allow-file: fixture prompts and browser diagnostics.
// Vim mode in the real chat composer (agentPane.vimMode): the gallery's composer with the setting on,
// driven by real keys in a browser. Esc shows NORMAL, motions and edits change the prompt and type
// nothing, i shows INSERT and types again.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-vim-gallery.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.composer-vim-mode";
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "insert" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  test("Esc, motions and edits drive the prompt; i types again", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
    try {
      const port = (server.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "insert" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const tag = page.locator(".acpmux-vim-mode");
      const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
      const text = async () => (await prompt.innerText()).trim();
      expect(await tag.getAttribute("data-vim-mode")).toBe("insert");
      await prompt.click();
      await page.keyboard.press("Meta+a");
      await page.keyboard.press("Control+a");
      await page.keyboard.press("Backspace");
      await page.keyboard.type("hello big world");
      expect(await text()).toBe("hello big world");
      await page.keyboard.press("Escape");
      expect(await tag.getAttribute("data-vim-mode")).toBe("normal");
      // b back to "world", b to "big", dw deletes it; nothing typed.
      await page.keyboard.type("bbdw");
      expect(await text()).toBe("hello world");
      // $ x deletes the last character.
      await page.keyboard.type("$x");
      expect(await text()).toBe("hello worl");
      // u undoes the x.
      await page.keyboard.type("u");
      expect(await text()).toBe("hello world");
      // 0 cw changes "hello" and types in Insert mode.
      await page.keyboard.type("0cw");
      expect(await tag.getAttribute("data-vim-mode")).toBe("insert");
      await page.keyboard.type("goodbye");
      expect(await text()).toBe("goodbye world");
    } finally {
      await page.close();
    }
  });
});
