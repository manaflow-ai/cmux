// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-gallery-tool-media-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmGalleryFrame(vite, "agent-pane.chat-gallery", { browser, params: { variant: "tool-outputs" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["dark", "light"] as const)
    test(`tool output is discoverable, filterable and opens the image viewer (${colorScheme})`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 720 }, colorScheme });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(
          base +
            galleryFrame("agent-pane.chat-gallery", {
              variant: "tool-outputs",
              colorScheme,
              width: 760,
              height: 720,
            }),
        );
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
        const gallery = page.locator(".acpmux-chat-gallery");
        expect(await gallery.locator("[data-gallery-kind]").count()).toBe(2);
        expect(await gallery.locator('[data-gallery-kind="tool"] img').count()).toBe(1);
        expect(await gallery.locator('[data-gallery-kind="image"] img').count()).toBe(1);
        const captures = process.env.CMUX_GALLERY_TOOL_CAPTURE_DIR;
        if (captures) {
          await mkdir(captures, { recursive: true });
          await page.screenshot({ path: path.join(captures, `gallery-tool-media-${colorScheme}.png`) });
        }
        await gallery.getByRole("button", { name: "Tools 1", exact: true }).click();
        expect(await gallery.locator("[data-gallery-kind]").count()).toBe(1);
        const source = await gallery.locator("img").getAttribute("src");
        await gallery.locator("[data-open-image]").click();
        await page.locator(".acpmux-image-viewer").waitFor();
        expect(await gallery.count()).toBe(0);
        expect(await page.locator(".acpmux-image-viewer-image").getAttribute("src")).toBe(source);
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });

  for (const colorScheme of ["dark", "light"] as const)
    test(`tool image viewer steps through reply images (${colorScheme})`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 720 }, colorScheme });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(
          base +
            galleryFrame("agent-pane.chat-gallery", {
              variant: "tool-outputs",
              colorScheme,
              width: 760,
              height: 720,
            }),
        );
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        const gallery = page.locator(".acpmux-chat-gallery");
        expect(await gallery.locator("[data-gallery-kind]").count()).toBe(2);
        const toolSource = await gallery.locator('[data-gallery-kind="tool"] img').getAttribute("src");
        const replySource = await gallery.locator('[data-gallery-kind="image"] img').getAttribute("src");
        expect(toolSource).toBeTruthy();
        expect(replySource).toBeTruthy();
        await gallery.locator('[data-gallery-kind="tool"] [data-open-image]').click();
        const viewer = page.locator(".acpmux-image-viewer");
        await viewer.waitFor();
        expect(await viewer.locator(".acpmux-image-viewer-image").getAttribute("src")).toBe(toolSource);
        await viewer.getByRole("button", { name: /next/i }).click();
        expect(await viewer.locator(".acpmux-image-viewer-image").getAttribute("src")).toBe(replySource);
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
