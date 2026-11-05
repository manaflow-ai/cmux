// The composer's input box is the shared glass material (glass.css, "GLASS MATERIAL"; Leo 2026-11-05,
// on the Dock beside our composer: "the glass is a pretty big deal"). On an opaque window and over
// art under Plain glass, in a light and a dark theme, the card draws a specular rim lit from above
// and a little left (the crisp top line and a soft band round the top corners), a fainter return
// along the bottom and right, a sheen under its top edge, and a soft two-step shadow, dark themes
// too. Over art its frost keeps the art's colors vivid (saturate 1.8), and in the dock (where no
// transcript row is ever under it) it draws no Chromium underlay, so the art shows through. Reduce Transparency keeps the
// solid card with no specular band and no frost; appearance.borders none clears the rim's light.
//
// Before: the card's rim was two hairlines (white at 22% on dark) and a dark theme drew no shadow,
// so over a wallpaper it read as a flat translucent box; in Chromium the 70% underlay under its
// tint covered about 85% of the art.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/glass-material.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Look = { fill: number; backdrop: string; shadow: string };

await requireBrowserLane("glass-material.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("glass-material: skipping (run `bunx playwright install chromium`)");
    describe.skip("glass material", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/composer-rim.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: 2, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((attributes) => {
      for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
    }, attributes);
    return page;
  }

  async function look(page: Page, id = "composer"): Promise<Look> {
    const raw = await page.evaluate((id) => {
      const style = getComputedStyle(document.getElementById(id)!);
      return { fill: style.backgroundColor, backdrop: style.backdropFilter, shadow: style.boxShadow };
    }, id);
    const alpha = raw.fill.match(/\/\s*([\d.]+)\)|rgba\([^)]*,\s*([\d.]+)\)/);
    return { fill: alpha ? Number(alpha[1] ?? alpha[2]) : 1, backdrop: raw.backdrop, shadow: raw.shadow };
  }

  /** The alpha of the color right before `geometry` in a computed box-shadow list, or -1 when absent. */
  function layerAlpha(shadow: string, geometry: string): number {
    for (const layer of shadow.split(/,(?![^()]*\))/)) {
      if (!layer.includes(geometry)) continue;
      const color = layer.match(/color\(srgb [\d.e-]+ [\d.e-]+ [\d.e-]+(?: \/ ([\d.e-]+))?\)|rgba?\([^)]*\)/);
      if (!color) return -1;
      if (color[0].startsWith("color(")) return color[1] === undefined ? 1 : Number(color[1]);
      const parts = color[0].match(/[\d.]+/g)!;
      return parts.length > 3 ? Number(parts[3]) : 1;
    }
    return -1;
  }

  const SPECULAR_BAND = "1px 1.5px 1px -1px inset";
  const RETURN_BAND = "-1px -1px 1px -1px inset";
  const SHEEN = "0px 16px 20px -16px inset";
  const DEPTH = "0px 12px 32px -12px";
  const windows: { name: string; attributes: Record<string, string> }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
  ];

  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: the card draws the material's rim, sheen and depth`, async () => {
        const page = await open(colorScheme, { ...window.attributes, "data-theme": colorScheme });
        for (const id of ["composer", "strip-composer"]) {
          const { shadow } = await look(page, id);
          expect(layerAlpha(shadow, SPECULAR_BAND), `${id} specular band`).toBeGreaterThan(0.3);
          expect(layerAlpha(shadow, RETURN_BAND), `${id} return along the bottom and right`).toBeGreaterThan(0.1);
          expect(layerAlpha(shadow, SHEEN), `${id} sheen under the top edge`).toBeGreaterThan(0.05);
          expect(layerAlpha(shadow, DEPTH), `${id} depth shadow`).toBeGreaterThan(0.2);
          // The specular light is brighter than its return: lit from above.
          expect(layerAlpha(shadow, SPECULAR_BAND)).toBeGreaterThan(layerAlpha(shadow, RETURN_BAND));
        }
        await page.close();
      });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, art under Plain glass: the frost keeps the art's colors vivid`, async () => {
      const page = await open(colorScheme, { "data-cmux-see-through": "", "data-glass": "plain" });
      const { fill, backdrop } = await look(page);
      expect(backdrop).toContain("blur(24px)");
      expect(backdrop).toContain("saturate(1.8)");
      // Chromium's underlay (glass.css) is the fill's color layer: under floating glass it hides
      // crisp text at 70%. A card outside the dock keeps it.
      expect(fill, "a card outside the dock keeps Chromium's 70% underlay").toBeCloseTo(0.7, 2);
      await page.close();
    });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, art under Plain glass: the docked card draws no underlay, so the art shows through`, async () => {
      const page = await open(colorScheme, { "data-cmux-see-through": "", "data-glass": "plain" });
      const { fill, backdrop } = await look(page, "docked-composer");
      expect(fill, "no underlay under the docked card").toBe(0);
      expect(backdrop).toContain("saturate(1.8)");
      const tint = await page.evaluate(
        () => getComputedStyle(document.getElementById("docked-composer")!).backgroundImage,
      );
      expect(tint, "its tint is still drawn").toContain("gradient");
      await page.close();
    });

  test("an opaque window keeps the card's tint and blur (the transcript under it, not art)", async () => {
    const page = await open("dark", {});
    const { fill, backdrop } = await look(page);
    expect(fill).toBeCloseTo(0.7, 2);
    expect(backdrop).toContain("blur(24px)");
    expect(backdrop).not.toContain("saturate(1.8)");
    await page.close();
  });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, Reduce Transparency: a solid card, no specular band and no frost`, async () => {
      const page = await open(colorScheme, {
        "data-cmux-see-through": "",
        "data-glass": "plain",
        "data-reduce-transparency": "",
      });
      const { fill, backdrop, shadow } = await look(page);
      expect(fill).toBe(1);
      expect(backdrop).toBe("none");
      expect(layerAlpha(shadow, SPECULAR_BAND)).toBe(-1);
      expect(layerAlpha(shadow, SHEEN)).toBe(-1);
      // Nor the material's depth: the card keeps its old shadow.
      expect(layerAlpha(shadow, DEPTH)).toBe(-1);
      await page.close();
    });

  test("appearance.borders none clears the rim's light and keeps the depth", async () => {
    const page = await open("dark", { "data-borders": "none", "data-theme": "dark" });
    const { shadow } = await look(page);
    expect(layerAlpha(shadow, SPECULAR_BAND)).toBe(0);
    expect(layerAlpha(shadow, SHEEN)).toBe(0);
    expect(layerAlpha(shadow, DEPTH)).toBeGreaterThan(0.2);
    await page.close();
  });

  test("over art under Lens glass the card keeps the lens's own rim", async () => {
    const page = await open("dark", { "data-cmux-see-through": "", "data-glass": "lens" });
    const { shadow } = await look(page);
    expect(layerAlpha(shadow, SPECULAR_BAND)).toBe(-1);
    expect(shadow).toMatch(/0px 0\.5px 0px 0px inset/);
    await page.close();
  });
});
