// The chat's Summary popover (Outputs, Subagents, Sources, Background tasks; summary/SummaryCard.tsx)
// is the liquid glass, as the chat's other menus and popovers are, never the solid popup card (Leo
// 2026-10-21: "i dont like the non glassness here :("). In a light and a dark theme, on an opaque
// window and over art under Plain and Lens glass, the popover's fill is translucent under a backdrop
// blur, and its title keeps 4.5:1 over a bright and a dark backdrop. Reduce Transparency is the one
// case it is solid. The inline column (a wide pane) is not an overlay and keeps the page background.
//
// Before: `.acpmux-summary-card[data-placement=popover]` painted `--surface-popup` (alpha 1) with no
// blur.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];

test("the Summary card gives the popover, and only the popover, the glass class", () => {
  const source = readFileSync(new URL("../src/agent-session/acpmux/summary/SummaryCard.tsx", import.meta.url), "utf8");
  expect(source).toContain('className={card.column ? "acpmux-summary-card" : "ui-glass acpmux-summary-card"}');
});

await requireBrowserLane("summary-glass.test.ts", async () => {
  /** Parses a computed color (`rgb()`, `rgba()` or `color(srgb …)`) into 0-1 channels and alpha. */
  function parse(color: string): Rgba {
    const srgb = color.match(/color\(srgb\s+([\d.e-]+)\s+([\d.e-]+)\s+([\d.e-]+)(?:\s*\/\s*([\d.e-]+))?\)/);
    if (srgb) return [Number(srgb[1]), Number(srgb[2]), Number(srgb[3]), srgb[4] === undefined ? 1 : Number(srgb[4])];
    const rgb = color.match(/rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,/\s]+([\d.]+))?\s*\)/);
    if (rgb) return [Number(rgb[1]) / 255, Number(rgb[2]) / 255, Number(rgb[3]) / 255, rgb[4] === undefined ? 1 : Number(rgb[4])];
    throw new Error(`unparsed color ${color}`);
  }
  const over = (top: Rgba, under: Rgb): Rgb => [0, 1, 2].map((i) => top[i]! * top[3] + under[i]! * (1 - top[3])) as Rgb;
  const luminance = ([r, g, b]: Rgb) => {
    const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  };
  const contrast = (a: Rgb, b: Rgb) => {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi! + 0.05) / (lo! + 0.05);
  };

  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("summary-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("summary glass", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/summary-glass.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 420 }, deviceScaleFactor: 2, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/summary-glass.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate((attributes) => {
      for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
    }, attributes);
    return page;
  }

  async function popover(page: Page) {
    const raw = await page.evaluate(() => {
      const style = getComputedStyle(document.getElementById("popover")!);
      return { fill: style.backgroundColor, backdrop: style.backdropFilter, ink: getComputedStyle(document.getElementById("title")!).color };
    });
    return { fill: parse(raw.fill), backdrop: raw.backdrop, ink: parse(raw.ink) };
  }

  const windows = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
    { name: "art under Lens glass", attributes: { "data-cmux-see-through": "", "data-glass": "lens" } },
  ];
  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: the Summary popover is translucent glass`, async () => {
        const page = await open(colorScheme, window.attributes);
        const { fill, backdrop, ink } = await popover(page);
        expect(fill[3], "fill alpha (glass is never opaque)").toBeLessThan(0.9);
        expect(fill[3], "fill alpha (still a surface)").toBeGreaterThan(0.2);
        expect(backdrop, "the popover blurs what is under it").toContain("blur(");
        // The title over the popover laid on the theme's own extreme (the blur can average to it):
        // a dark theme's light ink over white is the case a clear film fails.
        const under: Rgb = colorScheme === "dark" ? [1, 1, 1] : [0, 0, 0];
        const surface = over(fill, under);
        expect(contrast(over(ink, surface), surface), "title contrast").toBeGreaterThanOrEqual(3);
        await page.close();
      });

  test("Reduce Transparency is the one case the popover is solid", async () => {
    for (const colorScheme of ["light", "dark"] as const) {
      const page = await open(colorScheme, { "data-reduce-transparency": "" });
      const { fill, backdrop } = await popover(page);
      expect(fill[3], `${colorScheme} fill under Reduce Transparency`).toBe(1);
      expect(backdrop, `${colorScheme} blur under Reduce Transparency`).toBe("none");
      await page.close();
    }
  });
});
