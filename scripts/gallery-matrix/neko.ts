#!/usr/bin/env bun
// Focused, bounded Neko art review. Run through cmux-ci after gallery:build.
import { chromium } from "playwright";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve, extname } from "node:path";

if (process.env.CI !== "true" && process.env.CMUX_GALLERY_IN_VM !== "1") {
  throw new Error("Run this capture on the fleet through cmux-ci.");
}
const root = resolve(import.meta.dir, "../../webviews/dist/gallery");
const out = process.env.FAST_CHECKS_OUT ?? resolve(".cmux-scratch/neko-captures");
await mkdir(out, { recursive: true });
const mime: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
};
const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const path = resolve(root, `.${decodeURIComponent(new URL(request.url).pathname)}`);
    if (!path.startsWith(`${root}/`)) return new Response("Not found", { status: 404 });
    const file = Bun.file(path);
    return (await file.exists())
      ? new Response(file, { headers: { "content-type": mime[extname(path)] ?? file.type } })
      : new Response("Not found", { status: 404 });
  },
});
const browser = await chromium.launch({
  headless: true,
  ...(process.env.CMUX_CHROME_HEADLESS_SHELL
    ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
    : { channel: "chrome" }),
});
const results: unknown[] = [];
const DENSITIES = ["compact", "comfortable"] as const;
const UI_SCALES = [1, 1.25] as const;
try {
  for (const deviceScale of [1, 2]) {
    for (const mode of ["light", "dark"] as const) {
      for (const density of DENSITIES) {
        for (const uiScale of UI_SCALES) {
          const context = await browser.newContext({
            viewport: { width: 680, height: 570 },
            deviceScaleFactor: deviceScale,
            colorScheme: mode,
            reducedMotion: "reduce",
          });
          try {
            const page = await context.newPage();
            for (const set of ["noto", "fluent", "lucide", "authored", "earfold", "tailterm", "whisker"]) {
              const errors: string[] = [];
              const listener = (error: Error) => errors.push(error.message);
              page.on("pageerror", listener);
              const params = new URLSearchParams({
                entry: "agent-pane.neko-icon-family",
                variant: `${set}-${density}-${uiScale === 1 ? "1" : "1-25"}-${mode}`,
                source: "src/agent-session/acpmux/icons/NekoIconGallery.gallery.tsx",
                colorScheme: mode,
                locale: "en",
                reducedMotion: "true",
                width: "680",
                height: "570",
              });
              await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`, {
                waitUntil: "networkidle",
                timeout: 30000,
              });
              await page.waitForSelector('[data-gallery-ready="1"]', { timeout: 30000 });
              const stage = page.locator("[data-neko-gallery]");
              await stage
                .locator("img")
                .evaluateAll((images) => Promise.all(images.map((image) => (image as HTMLImageElement).decode())));
              await stage.locator("[data-neko-drawing]").evaluateAll((elements) =>
                Promise.all(
                  elements.map((element) => {
                    const image = new Image();
                    image.src = (element as HTMLElement).dataset.nekoDrawing!;
                    return image.decode();
                  }),
                ),
              );
              const provenance = await page.locator("[data-gallery-revision]").evaluate((el) => ({
                revision: (el as HTMLElement).dataset.galleryRevision,
                source: (el as HTMLElement).dataset.gallerySource,
              }));
              if (!provenance.revision || !provenance.source || errors.length)
                throw new Error(JSON.stringify({ provenance, errors }));
              const file = `${set}-${density}-${uiScale === 1 ? "1" : "1-25"}-${mode}-${deviceScale}x.png`;
              await stage.screenshot({ path: resolve(out, file), animations: "disabled" });
              results.push({
                set,
                density,
                uiScale,
                interfaceScale: (density === "compact" ? 0.875 : 1) * uiScale,
                mode,
                deviceScale,
                file,
                ...provenance,
                glyphSizeCssPx: 16 * (density === "compact" ? 0.875 : 1) * uiScale,
              });
              page.off("pageerror", listener);
            }
          } finally {
            await context.close();
          }
        }
      }
    }
  }
  await writeFile(resolve(out, "neko-captures.json"), JSON.stringify(results, null, 2));
  console.log(`Captured ${results.length} Neko comparisons at real 1x and 2x.`);
} finally {
  await browser.close();
  server.stop();
}
