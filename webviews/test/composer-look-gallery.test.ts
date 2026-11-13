// cmux-web-test-timeout: 240
// l10n-allow-file: fixture labels and browser diagnostics.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-look-gallery.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.composer-look";
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant: "claude-chat" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  async function open(variant: string) {
    const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
    await page.addInitScript(() => {
      const looks: string[] = [];
      Object.assign(window, { initialComposerLooks: looks });
      new MutationObserver(() => {
        const composer = document.querySelector<HTMLElement>(".acpmux-composer");
        if (composer) looks.push(composer.dataset.composerLook ?? "claude");
      }).observe(document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["data-composer-look"],
      });
    });
    const port = (server.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }

  test("a static Claude fixture mounts in that look without a measured look-switch shift", async () => {
    const page = await open("claude-chat");
    try {
      const state = await page.evaluate(() => ({
        looks: (window as unknown as { initialComposerLooks: string[] }).initialComposerLooks,
        play: (window as unknown as { cmuxGalleryPlayReport: { steps: { layoutShift: number }[] } })
          .cmuxGalleryPlayReport,
        saved: localStorage.getItem("cmux.composer.look"),
      }));
      expect(state.looks.length).toBeGreaterThan(0);
      expect(new Set(state.looks)).toEqual(new Set(["claude"]));
      expect(state.play.steps.every(({ layoutShift }) => layoutShift === 0)).toBe(true);
      expect(state.saved).toBeNull();
    } finally {
      await page.close();
    }
  });

  test("a mounted Codex fixture preserves its draft when the reader picks Claude's dot", async () => {
    const page = await open("codex-send-accent-disc");
    try {
      const dot = page.locator('.acpmux-look-dots .nt-style-option[data-style="claude"]');
      await dot.hover();
      await dot.click();
      await page.waitForFunction(() => !document.querySelector('.acpmux-composer[data-composer-look="codex"]'));
      const looks = await page.evaluate(
        () => (window as unknown as { initialComposerLooks: string[] }).initialComposerLooks,
      );
      expect(looks[0]).toBe("codex");
      expect(looks.at(-1)).toBe("claude");
      expect(await page.locator(".acpmux-md-root").textContent()).toContain("Also cover the 503 path");
      expect(await page.evaluate(() => localStorage.getItem("cmux.composer.look"))).toBe("claude");
    } finally {
      await page.close();
    }
  });
});
