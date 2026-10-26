// The queued prompts above the chat composer (.acpmux-composer-queue, ComposerQueue.tsx) are the
// card's glass over art or a see-through window, not a near-clear film (Leo 2026-10-21: "this is
// also maybe a little too... glassy?"). Under Plain glass the band was the tray tone at 60% with no
// blur: the tray is the text at 9% over the agent page, which is transparent, so the fill was about
// 5% and the wallpaper read through crisp under the "Queued" label and the prompts. Now, in a light
// and a dark theme and under Plain and Lens glass, the band takes the card's tint and blur: a
// translucent fill (glass, never opaque) under a backdrop blur, a long queue's fold bar the same, and
// its label, prompts, actions and fold keep their contrast over a bright or dark backdrop. Reduce
// Transparency (the host's attribute or the system setting) makes the band and the fold the card's
// solid fill.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];

await requireBrowserLane("queued-glass.test.ts", async () => {
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
    console.warn("queued-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("queued glass", () => test("chromium", () => {}));
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

  // The harness's base layer (shared/styles.css) is a dark page until a theme arrives, so each run
  // applies a theme the way the host does (applyAgentTheme): over art the page itself is clear.
  const themes = {
    light: { isDark: false, pageBackground: "transparent", text: "rgb(20, 20, 20)" },
    dark: { isDark: true, pageBackground: "transparent", text: "rgb(236, 236, 236)" },
  };

  async function open(
    colorScheme: "light" | "dark",
    attributes: Record<string, string>,
    reduceTransparency = false,
  ): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: 2, colorScheme });
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
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
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

  async function band(page: Page) {
    const raw = await page.evaluate(() => {
      const style = (id: string) => getComputedStyle(document.getElementById(id)!);
      return {
        reduceMedia: matchMedia("(prefers-reduced-transparency: reduce)").matches,
        fill: style("queue").backgroundColor,
        backdrop: style("queue").backdropFilter,
        label: style("queue-kind").color,
        prompt: style("queued").color,
        longFill: style("long-queue").backgroundColor,
        foldFill: style("long-queue-fold").backgroundColor,
        foldBackdrop: style("long-queue-fold").backdropFilter,
        action: style("long-queued-action").color,
        fold: style("long-queue-fold-button").color,
        card: style("long-queue-composer").backgroundColor,
      };
    });
    return {
      reduceMedia: raw.reduceMedia,
      fill: parse(raw.fill),
      backdrop: raw.backdrop,
      label: parse(raw.label),
      prompt: parse(raw.prompt),
      longFill: parse(raw.longFill),
      foldFill: parse(raw.foldFill),
      foldBackdrop: raw.foldBackdrop,
      action: parse(raw.action),
      fold: parse(raw.fold),
      card: parse(raw.card),
    };
  }

  // The backdrops the band is laid on. The extreme: pure white under a dark theme's light ink, pure
  // black under a light theme's dark ink (the blur can average to either): the prompt keeps 3:1 there,
  // where the old Plain film left it at about 1:1. The theme's own page (white under a light theme,
  // black under a dark one, the tint the window's floor keeps the art near): the "Queued" label, a
  // prompt's actions and the fold, secondary ink, keep 3:1. And the art behind the band in Leo's
  // capture (a dark theme's window over a light wallpaper, rgb(91 88 79)): the prompt keeps 4.5:1 in
  // either theme, and in the capture's own dark theme the secondary ink keeps 3:1, where the old film
  // gave the label about 1.9:1.
  const themePage: Record<"light" | "dark", Rgb> = { dark: [0, 0, 0], light: [1, 1, 1] };
  const extreme: Record<"light" | "dark", Rgb> = { dark: [1, 1, 1], light: [0, 0, 0] };
  const capture: Rgb = [91 / 255, 88 / 255, 79 / 255];
  const modes = [
    { name: "Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
    { name: "Lens glass", attributes: { "data-cmux-see-through": "", "data-glass": "lens" } },
  ];

  for (const colorScheme of ["light", "dark"] as const)
    for (const mode of modes)
      test(`${colorScheme}, art under ${mode.name}: the queued band is the card's glass and reads`, async () => {
        const page = await open(colorScheme, mode.attributes);
        const look = await band(page);
        const { fill, backdrop, label, prompt } = look;
        // The theme took: a light theme's ink is dark, a dark theme's light.
        expect(luminance([prompt[0], prompt[1], prompt[2]]) < 0.2, "the prompt's ink follows the theme").toBe(
          colorScheme === "light",
        );
        expect(fill[3], "fill alpha (glass, never opaque)").toBeLessThan(0.9);
        // The old Plain band was ~0.05: the tray (9%) at 60%.
        expect(fill[3], "fill alpha (a surface, not a film)").toBeGreaterThanOrEqual(0.4);
        expect(backdrop, "the band blurs what is under it").toContain("blur(");
        // A long queue's fold bar is the same glass as its band.
        expect(look.foldFill, "the fold bar's fill is the band's").toEqual(look.longFill);
        expect(look.foldBackdrop, "the fold bar blurs as the band does").toBe(backdrop);
        const edge = over(fill, extreme[colorScheme]);
        expect(contrast(over(prompt, edge), edge), "prompt contrast over the extreme backdrop").toBeGreaterThanOrEqual(
          3,
        );
        const art = over(fill, capture);
        expect(contrast(over(prompt, art), art), "prompt contrast over the captured art").toBeGreaterThanOrEqual(4.5);
        const own = over(fill, themePage[colorScheme]);
        for (const [name, ink] of [
          ["Queued label", label],
          ["a prompt's action", look.action],
          ["the fold", look.fold],
        ] as const) {
          expect(contrast(over(ink, own), own), `${name} contrast over the theme's page`).toBeGreaterThanOrEqual(3);
          if (colorScheme === "dark")
            expect(contrast(over(ink, art), art), `${name} contrast over the captured art`).toBeGreaterThanOrEqual(3);
        }
        await page.close();
      });

  // Reduce Transparency, from the host's attribute and from the system setting, in every top-strip
  // layout (the default, bump, plain and tray): the band and its fold are the card's solid fill with
  // no blur (the tray over a clear page left them a 9% film; the plain strip left the band clear text).
  const strips = [undefined, "bump", "plain", "tray"] as const;
  for (const via of ["data-reduce-transparency", "prefers-reduced-transparency"] as const)
    for (const strip of strips)
      test(`Reduce Transparency (${via}), ${strip ?? "default"} strip: the band and its fold are solid and unblurred`, async () => {
        for (const colorScheme of ["light", "dark"] as const) {
          const media = via === "prefers-reduced-transparency";
          const page = await open(
            colorScheme,
            {
              "data-cmux-see-through": "",
              "data-glass": "plain",
              ...(strip ? { "data-top-strip": strip } : {}),
              ...(media ? {} : { "data-reduce-transparency": "" }),
            },
            media,
          );
          const look = await band(page);
          const at = `${colorScheme}, ${strip ?? "default"} strip`;
          expect(look.reduceMedia, `${at}: the system setting is emulated`).toBe(media);
          expect(look.backdrop, `${at}: the band does not blur`).toBe("none");
          expect(look.foldBackdrop, `${at}: the fold does not blur`).toBe("none");
          for (const [name, fill] of [
            ["the band", look.fill],
            ["a long band", look.longFill],
            ["the fold", look.foldFill],
          ] as const) {
            expect(fill[3], `${at}: ${name} is opaque`).toBe(1);
            expect(fill, `${at}: ${name} is the card's fill`).toEqual(look.card);
          }
          await page.close();
        }
      });
});
