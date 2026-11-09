// The composer hat (subagents/SubagentTray.tsx) and the composer card under it are one glass, lit
// once from above (bottomStack.css; Leo's image of 2026-11-05, the hat over the composer). With a
// hat that draws a card joined to the docked card, the hat's top takes the card's material light (the
// specular line, the soft band into the top corners and the sheen), and the card gives up its own top
// light, keeping only the return along its bottom. Over art under Plain glass the hat's frost is the
// card's vivid one. Reduce Transparency, Lens over art and the gallery's `cards` look keep what they
// drew; a card with no hat keeps its own top light.
//
// Before: the card's bright top line and sheen ran across the middle of the stack, under the hat, and
// the hat's top drew only the hairline.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-hat-material.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

const HARNESS = "/test/browser/composer-hat-material.html";

await requireBrowserLane("composer-hat-material.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-hat-material: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer hat material", () => test("chromium", () => {}));
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
    await warmViteServer(vite, HARNESS);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 400 }, deviceScaleFactor: 2, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${HARNESS}`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((attributes) => {
      for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
    }, attributes);
    return page;
  }

  const style = (page: Page, id: string) =>
    page.evaluate((id) => {
      const computed = getComputedStyle(document.getElementById(id)!);
      return { shadow: computed.boxShadow, backdrop: computed.backdropFilter };
    }, id);

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
  const windows: { name: string; attributes: Record<string, string> }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
  ];

  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: the hat's top is lit and the card under it is not`, async () => {
        const page = await open(colorScheme, { ...window.attributes, "data-theme": colorScheme });
        const hat = await style(page, "hat");
        const hatted = await style(page, "hatted");
        const bare = await style(page, "bare");
        // The hat draws the card's light, at the card's glint: the same band and sheen as a bare card.
        expect(layerAlpha(hat.shadow, SPECULAR_BAND), "hat specular band").toBeGreaterThan(0.2);
        expect(layerAlpha(hat.shadow, SHEEN), "hat sheen").toBeGreaterThan(0.03);
        expect(layerAlpha(hat.shadow, SPECULAR_BAND)).toBeCloseTo(layerAlpha(bare.shadow, SPECULAR_BAND), 3);
        expect(layerAlpha(hat.shadow, SHEEN)).toBeCloseTo(layerAlpha(bare.shadow, SHEEN), 3);
        // The card under it: no top light at the join, its return along the bottom kept.
        expect(layerAlpha(hatted.shadow, SPECULAR_BAND), "card band under the hat").toBe(-1);
        expect(layerAlpha(hatted.shadow, SHEEN), "card sheen under the hat").toBe(-1);
        expect(layerAlpha(hatted.shadow, RETURN_BAND), "card return").toBeGreaterThan(0.05);
        // A card with no hat keeps its own top light.
        expect(layerAlpha(bare.shadow, SPECULAR_BAND), "bare card band").toBeGreaterThan(0.2);
        await page.close();
      });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, art under Plain glass: the hat's frost is the card's vivid one`, async () => {
      const page = await open(colorScheme, { "data-cmux-see-through": "", "data-glass": "plain" });
      const hat = await style(page, "hat");
      const hatted = await style(page, "hatted");
      expect(hat.backdrop).toContain("saturate(1.8)");
      expect(hat.backdrop).toBe(hatted.backdrop);
      await page.close();
    });

  const kept: { name: string; attributes: Record<string, string> }[] = [
    { name: "Reduce Transparency", attributes: { "data-cmux-see-through": "", "data-reduce-transparency": "" } },
    { name: "Lens over art", attributes: { "data-cmux-see-through": "", "data-glass": "lens" } },
    { name: "the cards look", attributes: { "data-bottom-stack": "cards" } },
  ];
  for (const { name, attributes } of kept)
    test(`${name}: the hat draws no material light`, async () => {
      const page = await open("dark", { ...attributes, "data-theme": "dark" });
      const hat = await style(page, "hat");
      expect(layerAlpha(hat.shadow, SPECULAR_BAND)).toBe(-1);
      expect(layerAlpha(hat.shadow, SHEEN)).toBe(-1);
      await page.close();
    });
});
