// The focused composer's rim is a subtle brighten, not a bright glass frame (Leo 2026-11-07: "the
// frame, the border on the composer, like it being this, like super duper prominent glass, I feel
// like is sort of strange"; 2026-10-21: "a subtle hairline border that brightens slightly on
// focus"). Measured as the eye sees it: each rim layer's computed color is laid over the page in
// a dark and a light theme, and the edge's contrast against the page is compared.
//
// - The focused hairline (--acpmux-composer-edge-focus) stays above the resting one, so focus still
//   reads, and below the 28% step it was.
// - In a dark theme the card's top edge, the hairline plus the glass material's top-lit line
//   (glass.css "GLASS MATERIAL"), focused, is quieter than it was (a 28% hairline under the full
//   material light).
//
// Real Chromium from Playwright on the composer-rim harness; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type RGB = [number, number, number];
type RGBA = [number, number, number, number];
type Layer = { offsetY: number; spread: number; blur: number; color: RGBA };

await requireBrowserLane("composer-focus-rim-quiet.test.ts", async () => {
  const THEMES = {
    dark: { text: [230, 230, 235] as RGB, page: [34, 34, 47] as RGB },
    light: { text: [29, 29, 31] as RGB, page: [246, 246, 248] as RGB },
  } as const;
  /** The material's top-lit line at full strength (glass.css --glass-material-specular). */
  const FULL_SPECULAR = 0.48;
  const BEFORE_FOCUS = 0.28;

  const over = (base: RGB, [r, g, b, a]: RGBA): RGB => [
    base[0] + (r - base[0]) * a,
    base[1] + (g - base[1]) * a,
    base[2] + (b - base[2]) * a,
  ];
  function luminance(rgb: RGB): number {
    const [r, g, b] = rgb.map((channel) => {
      const c = channel / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }
  function contrast(a: RGB, b: RGB): number {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  }

  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-focus-rim-quiet: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer focus rim", () => test("chromium", () => {}));
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

  async function open(theme: keyof typeof THEMES): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 640 }, deviceScaleFactor: 2 });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    const { text, page: bg } = THEMES[theme];
    await page.evaluate(
      ({ theme, text, bg }) => {
        const root = document.documentElement;
        root.dataset.theme = theme;
        root.style.colorScheme = theme;
        root.style.setProperty("--agent-text", `rgb(${text.join(" ")})`);
        root.style.setProperty("--agent-page-bg", `rgb(${bg.join(" ")})`);
        document.body.style.background = `rgb(${bg.join(" ")})`;
      },
      { theme, text: [...text], bg: [...bg] },
    );
    return page;
  }

  /** The composer card's inset layers with their colors in sRGB 0-255 and alpha. */
  function layers(page: Page): Promise<Layer[]> {
    return page.evaluate(() => {
      const shadow = getComputedStyle(document.getElementById("composer")!).boxShadow;
      const entries: string[] = [];
      let depth = 0;
      let start = 0;
      for (let index = 0; index < shadow.length; index++) {
        const char = shadow[index];
        if (char === "(") depth++;
        else if (char === ")") depth--;
        else if (char === "," && depth === 0) {
          entries.push(shadow.slice(start, index));
          start = index + 1;
        }
      }
      entries.push(shadow.slice(start));
      // Resolve each color to rgba through a canvas, whatever form Chromium serializes it in.
      const ctx = document.createElement("canvas").getContext("2d")!;
      const rgba = (css: string): [number, number, number, number] => {
        ctx.clearRect(0, 0, 1, 1);
        ctx.fillStyle = css;
        ctx.fillRect(0, 0, 1, 1);
        const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
        return a === 0 ? [0, 0, 0, 0] : [r, g, b, a / 255];
      };
      return entries
        .filter((entry) => /\binset\b/.test(entry))
        .map((entry) => {
          const color = entry.match(/(?:rgba?|color)\([^)]*\)/)?.[0] ?? "transparent";
          const lengths = [...entry.replace(/\([^)]*\)/g, "").matchAll(/(-?[\d.]+)px/g)].map((m) => Number(m[1]));
          return {
            offsetY: lengths[1] ?? 0,
            spread: lengths[3] ?? 0,
            blur: lengths[2] ?? 0,
            color: rgba(color),
          };
        });
    });
  }
  /** The hairline ring: crisp, with a spread. */
  const ring = (all: Layer[]) => all.find(({ spread, blur }) => spread > 0 && blur === 0)!;
  /** The top-lit line: crisp, one hairline down, no spread. */
  const topLine = (all: Layer[]) => all.find(({ spread, blur, offsetY }) => spread === 0 && blur === 0 && offsetY > 0);
  /** The color the eye sees on the card's top edge: the page, the ring, then the top-lit line. */
  const topEdge = (bg: RGB, all: Layer[]) => {
    const line = topLine(all);
    const withRing = over(bg, ring(all).color);
    return line ? over(withRing, line.color) : withRing;
  };

  for (const theme of ["dark", "light"] as const)
    test(`${theme}: the focused rim brightens a step over the resting one, and is quieter than the 28% frame`, async () => {
      const page = await open(theme);
      const { text, page: bg } = THEMES[theme];
      const rest = await layers(page);
      await page.focus("#composer-field");
      const focused = await layers(page);
      await page.close();

      const restRing = contrast(over(bg, ring(rest).color), bg);
      const focusRing = contrast(over(bg, ring(focused).color), bg);
      const beforeRing = contrast(over(bg, [...text, BEFORE_FOCUS]), bg);
      expect(focusRing, "focus still brightens the hairline").toBeGreaterThan(restRing * 1.02);
      expect(focusRing, "the focused hairline is quieter than the 28% step").toBeLessThan(beforeRing * 0.97);

      // The whole top edge as it reads focused, ring and the material's top-lit line, in a dark
      // theme (in a light one the white line on a near-white card was never a frame).
      if (theme === "light") return;
      const white: RGB = [255, 255, 255];
      const beforeTop = contrast(over(over(bg, [...text, BEFORE_FOCUS]), [...white, FULL_SPECULAR]), bg);
      const focusTop = contrast(topEdge(bg, focused), bg);
      expect(topLine(focused), "the glass card keeps a top-lit line").toBeDefined();
      expect(focusTop, "the focused top edge is quieter than the full glass frame").toBeLessThan(beforeTop * 0.9);
      expect(focusTop, "the focused top edge still reads against the page").toBeGreaterThan(1.05);
    });
});
