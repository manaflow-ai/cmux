// The chat composer's input box is glass, never opaque (Leo 2026-10-21, "we need a bit more glass on
// the input box"; the standing rule: glass, never solid). On every window (opaque, or over art
// under Plain or Lens glass) and in a light and a dark theme, the card (.acpmux-composer-box) and its
// location strip have a translucent fill under a backdrop blur, and the card draws the glass's light
// rim: a top-lit line one device pixel (--cmux-hairline) inside its edge and a fainter one along its
// bottom. The prompt stays legible: on an opaque window its ink against the card laid over the
// brightest and the darkest page is 4.5:1 or more. Only Reduce Transparency makes the card opaque.
//
// Before: on an opaque window the card was the solid composer surface (alpha 1) with no blur, so the
// transcript rows that scroll under it (Leo 2026-10-19) vanished behind a slab.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-glass.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rgba = [number, number, number, number];
type Look = { fill: Rgba; backdrop: string; shadow: string; ink: Rgba };

await requireBrowserLane("composer-glass.test.ts", async () => {
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

  function over(top: Rgba, under: [number, number, number]): [number, number, number] {
    return [0, 1, 2].map((i) => top[i]! * top[3] + under[i]! * (1 - top[3])) as [number, number, number];
  }

  function luminance([r, g, b]: [number, number, number]): number {
    const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  function contrast(a: [number, number, number], b: [number, number, number]): number {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi! + 0.05) / (lo! + 0.05);
  }

  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-glass: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer glass", () => test("chromium", () => {}));
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

  async function look(page: Page, id: string, field?: string): Promise<Look> {
    const raw = await page.evaluate(
      ([id, field]) => {
        const style = getComputedStyle(document.getElementById(id!)!);
        const ink = field ? getComputedStyle(document.getElementById(field)!).color : "rgb(0, 0, 0)";
        return { fill: style.backgroundColor, backdrop: style.backdropFilter, shadow: style.boxShadow, ink };
      },
      [id, field],
    );
    return { fill: parse(raw.fill), backdrop: raw.backdrop, shadow: raw.shadow, ink: parse(raw.ink) };
  }

  const windows: { name: string; attributes: Record<string, string> }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
    { name: "art under Lens glass", attributes: { "data-cmux-see-through": "", "data-glass": "lens" } },
  ];
  const boxes = [
    ["composer", "composer-field"],
    ["strip-composer", "strip-composer-field"],
    ["queue-composer", "queue-composer-field"],
    ["shell", "shell-field"],
  ] as const;

  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: the input box is translucent glass with a light rim`, async () => {
        const page = await open(colorScheme, window.attributes);
        for (const [id, field] of boxes) {
          const { fill, backdrop, shadow, ink } = await look(page, id, field);
          expect(fill[3], `${id} fill alpha (glass is never opaque)`).toBeLessThan(0.9);
          expect(fill[3], `${id} fill alpha (still a surface)`).toBeGreaterThan(0.2);
          expect(backdrop, `${id} blurs what is under it`).toContain("blur(");
          // On an opaque window the rows under the card can be anything: the prompt over the card laid
          // on the brightest and the darkest page. Over art the window's tint floor already keeps
          // primary text at 4.5:1 (desktop.ts), whatever the art.
          const pages: [number, number, number][] =
            window.attributes["data-cmux-see-through"] === undefined
              ? [
                  [1, 1, 1],
                  [0, 0, 0],
                ]
              : [];
          for (const page of pages) {
            const card = over(fill, page);
            expect(
              contrast(over(ink, card), card),
              `${id} prompt contrast over ${page.join(",")}`,
            ).toBeGreaterThanOrEqual(4.5);
          }
          // The light rim: a top line one device pixel (0.5 CSS px at 2x) that is not transparent.
          if (window.attributes["data-glass"] !== "lens")
            expect(shadow, `${id} draws the top-lit hairline`).toMatch(
              /color\(srgb 1 1 1 \/ [\d.]+\) 0px 0\.5px 0px 0px inset/,
            );
          else expect(shadow, `${id} draws the liquid glass's specular hairline`).toMatch(/0px 0\.5px 0px 0px inset/);
        }
        // The location strip is part of the box: the same glass.
        const strip = await look(page, "strip");
        expect(strip.fill[3], "strip fill alpha").toBeLessThan(0.9);
        expect(strip.backdrop, "strip blurs what is under it").toContain("blur(");
        await page.close();
      });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, the default composer uses the balanced glass level`, async () => {
      const page = await open(colorScheme, {});
      for (const id of ["composer", "strip-composer", "codex-strip-composer"]) {
        const { fill, backdrop } = await look(page, id);
        expect(fill[3], `${id} keeps the selected 70% tint`).toBeCloseTo(0.7, 2);
        expect(backdrop, `${id} keeps the selected 24px blur`).toContain("blur(24px)");
      }
      await page.close();
    });

  // Codex's look (composerLook.css) draws a new chat's folder and computer strip as a tray with a
  // faint wash of the text colour. On an opaque window that wash went over the solid composer
  // surface with no blur (after #24457): an opaque tray on a glass card. The tray is the card's
  // glass there too (glass is never opaque), and the folder name (muted text) stays at 4.5:1 over
  // the darkest page. Over a pure white page it is about 3.1:1, as the default strip's is about
  // 3.4:1 under the same 70% glass: the card's glass, not the tray's.
  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}, an opaque window: the Codex look's tray is the card's glass`, async () => {
      const page = await open(colorScheme, {});
      const tray = await look(page, "codex-strip", "codex-strip-folder");
      expect(tray.fill[3], "Codex tray fill alpha (glass is never opaque)").toBeLessThan(0.9);
      expect(tray.fill[3], "Codex tray fill alpha (still a surface)").toBeGreaterThan(0.2);
      expect(tray.backdrop, "Codex tray blurs what is under it").toContain("blur(");
      const surface = over(tray.fill, [0, 0, 0]);
      expect(
        contrast(over(tray.ink, surface), surface),
        "folder name contrast over a black page",
      ).toBeGreaterThanOrEqual(4.5);
      await page.close();
    });

  test("over art the Codex look's tray stays glass, as before", async () => {
    for (const attributes of [
      { "data-cmux-see-through": "", "data-glass": "plain" },
      { "data-cmux-see-through": "", "data-glass": "lens" },
    ]) {
      const page = await open("dark", attributes);
      const tray = await look(page, "codex-strip");
      expect(tray.fill[3], `Codex tray fill alpha, ${attributes["data-glass"]}`).toBeLessThan(0.9);
      expect(tray.backdrop, `Codex tray frost, ${attributes["data-glass"]}`).toContain("blur(");
      await page.close();
    }
  });

  test("Reduce Transparency keeps the Codex look's tray solid with no blur", async () => {
    for (const colorScheme of ["light", "dark"] as const) {
      const page = await open(colorScheme, { "data-reduce-transparency": "" });
      const tray = await look(page, "codex-strip");
      expect(tray.fill[3], `${colorScheme}, the app's Reduce Transparency`).toBe(1);
      expect(tray.backdrop, `${colorScheme}, the app's Reduce Transparency`).toBe("none");
      await page.close();
    }
    const page = await open("light", {});
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-transparency", value: "reduce" }],
    });
    const tray = await look(page, "codex-strip");
    expect(tray.fill[3], "the system's Reduce Transparency").toBe(1);
    expect(tray.backdrop, "the system's Reduce Transparency").toBe("none");
    await page.close();
  });

  // The plain top strip draws the strip as bare text in either look: Codex's tray rule
  // (composerLook.css) loads after the plain strip's and once painted its tray over it, a solid one
  // on an opaque window.
  for (const window of windows)
    test(`${window.name}: the plain top strip in Codex's look is bare text, as in Claude's`, async () => {
      for (const colorScheme of ["light", "dark"] as const) {
        const page = await open(colorScheme, { ...window.attributes, "data-top-strip": "plain" });
        const codex = await page.evaluate(() => {
          const style = getComputedStyle(document.getElementById("codex-strip")!);
          return { fill: style.backgroundColor, edge: style.boxShadow, backdrop: style.backdropFilter };
        });
        expect(parse(codex.fill)[3], `${colorScheme}: Codex plain strip fill`).toBe(0);
        expect(codex.edge, `${colorScheme}: Codex plain strip edge`).toBe("none");
        expect(codex.backdrop, `${colorScheme}: Codex plain strip frost`).toBe("none");
        await page.close();
      }
    });

  test("under Reduce Transparency the plain top strip looks the same in Codex's look as in Claude's", async () => {
    const page = await open("light", { "data-top-strip": "plain", "data-reduce-transparency": "" });
    const [claude, codex] = await page.evaluate(() =>
      ["strip", "codex-strip"].map((id) => {
        const style = getComputedStyle(document.getElementById(id)!);
        return { fill: style.backgroundColor, edge: style.boxShadow, backdrop: style.backdropFilter };
      }),
    );
    expect(codex).toEqual(claude!);
    await page.close();
  });

  test("the plain top strip, bare text with no fill, frosts nothing under it", async () => {
    const page = await open("light", { "data-top-strip": "plain" });
    const strip = await look(page, "strip");
    expect(strip.fill[3], "plain top strip stays unfilled").toBe(0);
    expect(strip.backdrop).toBe("none");
    expect((await look(page, "strip-composer")).backdrop, "the card under it is still glass").toContain("blur(");
    await page.close();
  });

  test("system Reduce Transparency keeps a see-through strip opaque", async () => {
    const page = await open("light", { "data-cmux-see-through": "", "data-glass": "plain" });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-transparency", value: "reduce" }],
    });
    const strip = await look(page, "strip");
    expect(strip.fill[3], "system Reduce Transparency makes the strip solid").toBe(1);
    expect(strip.backdrop).toBe("none");
    await page.close();
  });

  test("Reduce Transparency is the one case the box is opaque", async () => {
    for (const colorScheme of ["light", "dark"] as const) {
      const page = await open(colorScheme, { "data-reduce-transparency": "" });
      for (const [id] of boxes) {
        const { fill, backdrop } = await look(page, id);
        expect(fill[3], `${id} under Reduce Transparency`).toBe(1);
        expect(backdrop, `${id} under Reduce Transparency`).toBe("none");
      }
      await page.close();
    }
  });
});
