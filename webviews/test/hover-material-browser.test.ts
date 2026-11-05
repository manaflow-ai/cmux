// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// The hover surfaces' material in the gallery (ui/HoverMaterial.gallery.tsx), both schemes: every
// surface renders over the chat and the frame reports ready. CMUX_HOVER_MATERIAL_CAPTURE_DIR=<dir>
// keeps a still per variant and scheme.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/hover-material-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-material-browser.test.ts", async () => {
  const ENTRY = "ui.hover-material";
  const VARIANTS = ["compare", "shipped", "blur-control"];
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANTS[0]! } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of VARIANTS)
    for (const colorScheme of ["dark", "light"] as const)
      test(`${variant}: every hover surface draws over the chat (${colorScheme})`, async () => {
        const page = await browser!.newPage({ viewport: { width: 1000, height: 380 }, colorScheme, deviceScaleFactor: 2 });
        try {
          const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
          await page.goto(base + galleryFrame(ENTRY, { variant, colorScheme, width: 1000, height: 380 }));
          await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
          const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
          const surfaces = await page.evaluate(
            () =>
              [...document.querySelectorAll<HTMLElement>(".hm-stage .ui-glass")].filter(
                (surface) => surface.getBoundingClientRect().width > 0,
              ).length,
          );
          // Every ancestor that ends the backdrop a blur can read (a filter, opacity, a mask, a
          // backdrop-filter of its own, will-change of one of them, mix-blend-mode).
          const roots = await page.evaluate(() => {
            const surface = document.querySelector<HTMLElement>(".hm-stage .ui-glass");
            const found: string[] = [];
            const own = surface ? getComputedStyle(surface) : undefined;
            if (own)
              found.push(
                `surface backdrop-filter=${own.backdropFilter} background-color=${own.backgroundColor} background-image=${own.backgroundImage}`,
              );
            const root = document.documentElement;
            found.push(
              `root ${[...root.attributes].filter((attr) => attr.name.startsWith("data-")).map((attr) => `${attr.name}=${attr.value}`).join(" ")}`,
            );
            for (let node = surface?.parentElement; node; node = node.parentElement) {
              const style = getComputedStyle(node);
              const marks = [
                style.filter !== "none" && `filter=${style.filter}`,
                style.opacity !== "1" && `opacity=${style.opacity}`,
                style.backdropFilter !== "none" && `backdrop-filter=${style.backdropFilter}`,
                style.maskImage !== "none" && `mask=${style.maskImage}`,
                style.mixBlendMode !== "normal" && `blend=${style.mixBlendMode}`,
                style.willChange !== "auto" && `will-change=${style.willChange}`,
                style.clipPath !== "none" && `clip-path=${style.clipPath}`,
              ].filter(Boolean);
              if (marks.length) found.push(`${node.tagName.toLowerCase()}.${[...node.classList].join(".")}: ${marks.join(" ")}`);
            }
            return found;
          });
          console.log(`[backdrop ${variant} ${colorScheme}] ${roots.join(" | ")}`);
          const captures = process.env.CMUX_HOVER_MATERIAL_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
          if (captures) {
            await mkdir(captures, { recursive: true });
            await page.screenshot({ path: path.join(captures, `hover-material-${variant}-${colorScheme}.png`) });
            // Each surface alone, padded, so what shows through it can be read at full size.
            const boxes = await page.evaluate(() =>
              [...document.querySelectorAll<HTMLElement>(".hm-stage .ui-glass, .hm-blur-control")].map((node) => {
                const box = node.getBoundingClientRect();
                const look = node.closest(".hm-column")?.className.match(/hm-look--(\w+)/)?.[1] ?? "x";
                return { look, kind: node.classList.contains("ui-card") ? "card" : node.classList.contains("hm-blur-control") ? "control" : "tooltip", x: box.x - 12, y: box.y - 12, width: box.width + 24, height: box.height + 24 };
              }),
            );
            for (const box of boxes)
              await page.screenshot({
                path: path.join(captures, `zoom-${variant}-${colorScheme}-${box.look}-${box.kind}.png`),
                clip: { x: Math.max(0, box.x), y: Math.max(0, box.y), width: box.width, height: box.height },
              });
          }
          expect(ready).toBe("1");
          expect(surfaces).toBe(variant === "compare" ? 6 : 2);
        } finally {
          await page.close();
        }
      });
});
