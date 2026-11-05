// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The gallery's background axis (src/gallery/env.ts BACKGROUNDS, frame/background.ts): every UI PR
// was reviewed over an opaque window while Leo uses a picture behind the app's glass, so pages that
// painted over a picture shipped (#28867, #29058). With `background=<picture>` a stage renders as
// the app renders a window whose background the user set: the page background is clear
// (`--cmux-surface-background` at alpha 0, so desktop.ts marks the page see-through), the document
// root shows the window's tint over the picture, the glass lens gets the same still, and a glass
// surface keeps its translucent tint and blur. Without it the window stays opaque. Real Chromium on
// the gallery frame; CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-background-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  // A component with a `.ui-glass` surface at rest: the feature tip's glass look.
  const ENTRY = "ui.feature-tip";
  const VARIANT = "browser-glass";
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function look(params: Record<string, string>) {
    const page = await browser!.newPage({ viewport: { width: 760, height: 520 } });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
      const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
      await page.goto(base + galleryFrame(ENTRY, { variant: VARIANT, frame: "component", ...params }));
      await page.waitForFunction(
        () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
        undefined,
        { timeout: 90_000 },
      );
      await page.locator(".ui-glass").first().waitFor();
      const seen = await page.evaluate(() => {
        const root = document.documentElement;
        const rootStyle = getComputedStyle(root);
        const probe = document.createElement("span");
        probe.style.backgroundColor = "var(--cmux-surface-background)";
        root.append(probe);
        const surface = getComputedStyle(probe).backgroundColor;
        probe.remove();
        const glass = getComputedStyle(document.querySelector(".ui-glass")!);
        const backdrop = (window as unknown as { cmuxBackdropState?: { image: string | null; tint: string } })
          .cmuxBackdropState;
        return {
          ready: root.dataset.galleryReady,
          background: root.dataset.galleryBackground ?? null,
          seeThrough: root.hasAttribute("data-cmux-see-through"),
          surface,
          rootImage: rootStyle.backgroundImage,
          backdropImage: backdrop?.image ?? null,
          backdropTint: backdrop?.tint ?? null,
          glassFilter: glass.backdropFilter || glass.getPropertyValue("-webkit-backdrop-filter"),
          glassFill: glass.backgroundColor,
        };
      });
      return { ...seen, errors };
    } finally {
      await page.close();
    }
  }

  // A computed color's alpha: `rgb(r, g, b)`, `rgba(r, g, b, a)`, or the CSS Color 4 form a
  // color-mix() computes to (`color(srgb r g b / a)`, `oklab(l a b / a)`), whose alpha follows a slash.
  const alpha = (color: string) => {
    const body = /^[a-z-]+\((.*)\)$/.exec(color.trim())?.[1];
    if (!body) return Number.NaN;
    if (body.includes("/")) return Number(body.split("/")[1]!.trim());
    const parts = body.split(",");
    if (parts.length === 4) return Number(parts[3]);
    return parts.length === 3 || body.trim().split(/\s+/).length >= 3 ? 1 : Number.NaN;
  };

  describe("gallery background axis", () => {
    test("no background: an opaque window, as by default", async () => {
      const seen = await look({});
      expect(seen.ready).toBe("1");
      expect(seen.background).toBeNull();
      expect(seen.seeThrough).toBe(false);
      expect(alpha(seen.surface)).toBe(1);
      expect(seen.rootImage).toBe("none");
      expect(seen.errors).toEqual([]);
    });

    for (const picture of ["light", "dark", "busy"] as const)
      for (const colorScheme of ["dark", "light"] as const)
        test(`${picture} picture, ${colorScheme} theme: clear page, tint over the picture, glass over it`, async () => {
          const seen = await look({ background: picture, colorScheme });
          expect(seen.ready).toBe("1");
          expect(seen.background).toBe(picture);
          // The glass tokens of a window over a picture (WebTheme.pageBackground, desktop.ts).
          expect(seen.seeThrough).toBe(true);
          expect(alpha(seen.surface)).toBe(0);
          // The window's tint over the picture: a translucent tint layer, then the bundled picture.
          expect(seen.rootImage).toMatch(
            /^linear-gradient\(rgba\([^)]*\), rgba\([^)]*\)\), url\("data:image\/svg\+xml/,
          );
          const tint = /linear-gradient\((rgba\([^)]*\))/.exec(seen.rootImage)?.[1] ?? "";
          expect(alpha(tint)).toBeGreaterThanOrEqual(0.52);
          expect(alpha(tint)).toBeLessThanOrEqual(0.76);
          // The lens gets the same still and tint the root paints (GlassBackdropFeed).
          expect(seen.backdropImage).toStartWith("data:image/svg+xml");
          expect(seen.rootImage).toContain(seen.backdropImage!.slice(0, 40));
          expect(alpha(seen.backdropTint ?? "")).toBe(alpha(tint));
          // The glass surface stays glass: a blur and a fill that lets the picture through.
          expect(seen.glassFilter).toContain("blur");
          expect(alpha(seen.glassFill)).toBeLessThan(1);
          expect(seen.errors).toEqual([]);
        });
  });
});
