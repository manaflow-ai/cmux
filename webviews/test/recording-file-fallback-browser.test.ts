// l10n-allow-file: synthetic recording fixture labels.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("recording-file-fallback-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const entry = "agent-pane.recording-uploads";
  const variant = "large-inline-recording";
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });
  for (const scheme of ["light", "dark"] as const)
    test(`a 5 MiB legacy recording stays attached in ${scheme}`, async () => {
      const page = await browser.newPage({ viewport: { width: 780, height: 560 }, colorScheme: scheme });
      try {
        const port = (server.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme: scheme })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const recording = page.locator(".acpmux-attachment-link[data-saved]");
        try {
          await recording.waitFor({ timeout: 10_000 });
        } finally {
          // Captures are fixture-only and are retained even on the red/base run.
          const directory = process.env.RECORDING_CAPTURE_DIR ?? "artifacts/attachment-recording";
          await mkdir(directory, { recursive: true });
          await page.screenshot({ path: path.join(directory, `recording-${scheme}.png`) });
        }
        expect(await recording.count()).toBe(1);
        expect(await recording.locator(".acpmux-attachment-link-name").textContent()).toContain(".wav");
        expect(await page.locator(".acpmux-md").textContent()).toContain(
          "Keep the original recording with these notes.",
        );
        expect(await page.locator(".acpmux-attachment-audio").count()).toBe(0);
      } finally {
        await page.close();
      }
    });
});
