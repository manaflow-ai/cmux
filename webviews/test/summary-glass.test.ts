// The chat's Summary popover (Outputs, Subagents, Sources, Background tasks; summary/SummaryCard.tsx)
// is the liquid glass, as the chat's other menus and popovers are, never the solid popup card (Leo
// 2026-10-21: "i dont like the non glassness here :("). In a light and a dark theme (applied as the
// host does), on an opaque window and over art under Plain and Lens glass:
// - the popover is the chat menus' glass: the same fill and blur as a `.ui-popup.ui-glass` menu, a
//   translucent fill (never opaque) under a backdrop blur;
// - its muted ink (counts, a section title, a row's meta, the close button) keeps 3:1 over the theme's
//   own page (white under a light theme, black under a dark one);
// - under Plain glass its title keeps 3:1 even over the other extreme (a dark theme's light ink over
//   white). Under Lens the lens (ui/glass/lens.ts) draws its frost behind the glass, which this
//   harness does not, so there the check is the menus' glass and the theme's page.
// Reduce Transparency, from the host's attribute or the system setting, is the one case it is solid.
// The inline column (a wide pane) is not an overlay and keeps the page background.
//
// Before: `.acpmux-summary-card[data-placement=popover]` painted `--surface-popup` (alpha 1) with no
// blur.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// summary-glass-class.test.ts keeps the glass class on the popover in SummaryCard.tsx.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];

await requireBrowserLane("summary-glass.test.ts", async () => {
  /** Parses a computed color (`rgb()`, `rgba()` or `color(srgb …)`) into 0-1 channels and alpha. */
  function parse(color: string): Rgba {
    const srgb = color.match(/color\(srgb\s+([\d.e-]+)\s+([\d.e-]+)\s+([\d.e-]+)(?:\s*\/\s*([\d.e-]+))?\)/);
    if (srgb) return [Number(srgb[1]), Number(srgb[2]), Number(srgb[3]), srgb[4] === undefined ? 1 : Number(srgb[4])];
    const rgb = color.match(/rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,/\s]+([\d.]+))?\s*\)/);
    if (rgb)
      return [
        Number(rgb[1]) / 255,
        Number(rgb[2]) / 255,
        Number(rgb[3]) / 255,
        rgb[4] === undefined ? 1 : Number(rgb[4]),
      ];
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

  // The harness's base layer (shared/styles.css) is a dark page until a theme arrives, so each run
  // applies a theme the way the host does (applyAgentTheme).
  const themes = {
    light: { isDark: false, pageBackground: "transparent", text: "rgb(20, 20, 20)" },
    dark: { isDark: true, pageBackground: "transparent", text: "rgb(236, 236, 236)" },
  };

  async function open(
    colorScheme: "light" | "dark",
    attributes: Record<string, string>,
    reduceTransparency = false,
  ): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 420 }, deviceScaleFactor: 2, colorScheme });
    if (reduceTransparency) {
      // The system setting (prefers-reduced-transparency), which Playwright's emulateMedia lacks.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Emulation.setEmulatedMedia", {
        features: [
          { name: "prefers-reduced-transparency", value: "reduce" },
          { name: "prefers-color-scheme", value: colorScheme },
        ],
      });
    }
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/summary-glass.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate(
      async ([attributes, theme]) => {
        const themeModule = "/src/agent-session/shared/theme.ts";
        const { applyAgentTheme } = await import(/* @vite-ignore */ themeModule);
        applyAgentTheme(theme);
        for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
      },
      [attributes, themes[colorScheme]] as const,
    );
    return page;
  }

  const muted = ["counts", "section-title", "row-meta", "close"] as const;
  async function popover(page: Page) {
    const raw = await page.evaluate((muted) => {
      const style = (id: string) => getComputedStyle(document.getElementById(id)!);
      return {
        reduceMedia: matchMedia("(prefers-reduced-transparency: reduce)").matches,
        fill: style("popover").backgroundColor,
        backdrop: style("popover").backdropFilter,
        menuFill: style("menu").backgroundColor,
        menuBackdrop: style("menu").backdropFilter,
        title: style("title").color,
        text: style("row-text").color,
        muted: muted.map((id) => style(id).color),
      };
    }, muted);
    return {
      ...raw,
      fill: parse(raw.fill),
      menuFill: parse(raw.menuFill),
      title: parse(raw.title),
      text: parse(raw.text),
      muted: raw.muted.map(parse),
    };
  }

  const windows: { name: string; attributes: Record<string, string>; lens?: boolean }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
    {
      name: "art under Lens glass",
      // data-glass-lens: the lens is drawing (glassState.ts), which is what gives the glass its Lens tint.
      attributes: { "data-cmux-see-through": "", "data-glass": "lens", "data-glass-lens": "" },
      lens: true,
    },
  ];
  // The theme's own page and the other extreme the blur can average to.
  const ownPage: Record<"light" | "dark", Rgb> = { light: [1, 1, 1], dark: [0, 0, 0] };
  const otherExtreme: Record<"light" | "dark", Rgb> = { light: [0, 0, 0], dark: [1, 1, 1] };
  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: the Summary popover is the menus' translucent glass`, async () => {
        const page = await open(colorScheme, window.attributes);
        const look = await popover(page);
        const { fill, backdrop, title } = look;
        // The theme took: a light theme's ink is dark, a dark theme's light.
        expect(luminance([title[0], title[1], title[2]]) < 0.2, "the title's ink follows the theme").toBe(
          colorScheme === "light",
        );
        expect(fill[3], "fill alpha (glass is never opaque)").toBeLessThan(0.9);
        expect(fill[3], "fill alpha (still a surface)").toBeGreaterThan(0.2);
        expect(backdrop, "the popover blurs what is under it").toContain("blur(");
        expect(look.fill, "the popover's fill is a chat menu's").toEqual(look.menuFill);
        expect(backdrop, "the popover blurs as a chat menu does").toBe(look.menuBackdrop);
        const own = over(fill, ownPage[colorScheme]);
        for (const [index, ink] of look.muted.entries())
          expect(
            contrast(over(ink, own), own),
            `${muted[index]} contrast over the theme's page`,
          ).toBeGreaterThanOrEqual(3);
        expect(contrast(over(look.text, own), own), "row text contrast over the theme's page").toBeGreaterThanOrEqual(
          4.5,
        );
        if (!window.lens) {
          const other = over(fill, otherExtreme[colorScheme]);
          expect(contrast(over(title, other), other), "title contrast over the other extreme").toBeGreaterThanOrEqual(
            3,
          );
        }
        await page.close();
      });

  for (const via of ["data-reduce-transparency", "prefers-reduced-transparency"] as const)
    test(`Reduce Transparency (${via}) is the one case the popover is solid`, async () => {
      for (const colorScheme of ["light", "dark"] as const) {
        const media = via === "prefers-reduced-transparency";
        const page = await open(
          colorScheme,
          { "data-cmux-see-through": "", "data-glass": "plain", ...(media ? {} : { "data-reduce-transparency": "" }) },
          media,
        );
        const { reduceMedia, fill, backdrop } = await popover(page);
        expect(reduceMedia, `${colorScheme}: the system setting is emulated`).toBe(media);
        expect(fill[3], `${colorScheme} fill under Reduce Transparency`).toBe(1);
        expect(backdrop, `${colorScheme} blur under Reduce Transparency`).toBe("none");
        await page.close();
      }
    });
});
