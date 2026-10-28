// The New Tab composer box's focus is quiet (Lawrence 10-14, "don't like this focus thing"), and now
// is a hairline (Leo 2026-10-21: "a subtle hairline border that brightens slightly on focus"): a
// focused box keeps its one-device-pixel rim (--cmux-hairline), a step brighter, and still clears
// with appearance.borders none. The composer's
// fill, the New Tab box's and the chat composer's alike, is no longer a gray slab darker than the
// page ("same bg kinda weird"; Leo 10-14): in a light theme it is the page lifted toward white,
// lighter than the page; in a dark theme a small step lighter than the page. Both are solid. Their
// drop shadow is the shared --elevation-1 in a light theme and none in a dark one, where it shows
// nothing (cg-design-judge, 10-14).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rim = { spread: number; rgba: [number, number, number, number] };

await requireBrowserLane("newtab-quiet-focus.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("newtab-quiet-focus: skipping (run `bunx playwright install chromium`)");
    describe.skip("newtab quiet focus", () => test("chromium", () => {}));
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

  // The themes' opaque page colors: a dark gray, and a warm off-white so "lighter" can show.
  const pages = { dark: [30, 30, 30], light: [240, 236, 226] } as const;

  /** The composer-rim harness with a known dark theme and a blue accent, so a ring in the accent shows. */
  async function open(scale: number, theme: "dark" | "light" = "dark"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: scale });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate(
      ({ page, theme }) => {
        const root = document.documentElement.style;
        root.colorScheme = theme;
        document.documentElement.dataset.theme = theme;
        root.setProperty("--cmux-surface-solid", `rgb(${page.join(", ")})`);
        const shell = (document.querySelector(".acpmux-shell") as HTMLElement).style;
        shell.setProperty("--agent-text", theme === "dark" ? "rgb(236, 236, 236)" : "rgb(20, 20, 20)");
        shell.setProperty("--agent-page-bg", "transparent");
        shell.setProperty("--agent-accent", "rgb(0, 122, 255)");
      },
      { page: pages[theme], theme },
    );
    return page;
  }

  /** A box's inset rims: spread in CSS px and color as 0...1 channels. */
  function rims(page: Page, id = "newtab"): Promise<Rim[]> {
    return page.evaluate((id) => {
      const shadow = getComputedStyle(document.getElementById(id)!).boxShadow;
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
      return entries
        .filter((entry) => /\binset\b/.test(entry))
        .map((entry) => {
          const lengths = [...entry.replace(/\([^)]*\)/g, "").matchAll(/(-?[\d.]+)px/g)].map((match) =>
            Number(match[1]),
          );
          const color = entry.match(/(?:rgba?|color)\([^)]*\)/)?.[0] ?? "transparent";
          const numbers = [...color.matchAll(/-?[\d.]+(?:e-?\d+)?/g)].map((match) => Number(match[0]));
          let rgba: [number, number, number, number] = [0, 0, 0, 0];
          if (color.startsWith("color(")) rgba = [numbers[0], numbers[1], numbers[2], numbers[3] ?? 1];
          else if (color.startsWith("rgb"))
            rgba = [numbers[0] / 255, numbers[1] / 255, numbers[2] / 255, numbers[3] ?? 1];
          return { spread: lengths[3] ?? 0, rgba };
        });
    }, id);
  }

  /** A computed color as 0...1 channels (`rgb()` or `color(srgb ...)`); null when unparsed. */
  function parse(color: string): Rim["rgba"] | null {
    const numbers = [...color.matchAll(/-?[\d.]+(?:e-?\d+)?/g)].map((match) => Number(match[0]));
    if (color.startsWith("color(srgb")) return [numbers[0], numbers[1], numbers[2], numbers[3] ?? 1];
    if (color.startsWith("rgb")) return [numbers[0] / 255, numbers[1] / 255, numbers[2] / 255, numbers[3] ?? 1];
    return null;
  }

  /** An element's fill: its computed background color and image. */
  async function fill(page: Page, id: string): Promise<{ rgba: Rim["rgba"] | null; image: string }> {
    const style = await page.evaluate((id) => {
      const computed = getComputedStyle(document.getElementById(id)!);
      return { color: computed.backgroundColor, image: computed.backgroundImage };
    }, id);
    return { rgba: parse(style.color), image: style.image };
  }

  function luminance([r, g, b]: Rim["rgba"] | number[]): number {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  // The New Tab box and the chat composer (Leo 10-14: the chat composer's focus is as quiet).
  const boxes = [
    ["newtab", "newtab-field"],
    ["composer", "composer-field"],
  ] as const;

  for (const [box, field] of boxes)
    for (const theme of ["dark", "light"] as const) {
      for (const scale of [1, 2]) {
        test(`${box}, ${theme} at ${scale}x: focus keeps the one-device-pixel rim, a step brighter`, async () => {
          const page = await open(scale, theme);
          const rest = await rims(page, box);
          expect(rest.length, "the box draws a rim").toBe(1);
          expect(rest[0].spread * scale, "rest rim in device px").toBe(1);
          expect(rest[0].rgba[3], "the rim's color parsed and shows").toBeGreaterThan(0);
          await page.focus(`#${field}`);
          const focused = await rims(page, box);
          // No focus ring: the same one rim at the same width, its tone a step brighter.
          expect(focused.length, "focus draws one rim").toBe(1);
          expect(focused[0].spread, "focus keeps the rim's width").toBe(rest[0].spread);
          expect(focused[0].rgba[3], "focus brightens the rim").toBeGreaterThan(rest[0].rgba[3]);
          expect(focused[0].rgba[3] - rest[0].rgba[3], "only a step").toBeLessThan(0.2);
          await page.close();
        });
      }
    }

  for (const [box, field] of boxes)
    test(`${box}: focused, the rim still clears with appearance.borders none`, async () => {
      const page = await open(2);
      await page.evaluate(() => document.documentElement.setAttribute("data-borders", "none"));
      await page.focus(`#${field}`);
      for (const { rgba } of await rims(page, box))
        expect(rgba[3], `${box} focused rim alpha with borders none`).toBe(0);
      await page.close();
    });

  for (const [box, field] of boxes)
    test(`${box}: under Increase Contrast focus takes the shared, wider focus ring`, async () => {
      const page = await open(2);
      await page.emulateMedia({ contrast: "more" });
      const rest = await rims(page, box);
      await page.focus(`#${field}`);
      const focused = await rims(page, box);
      const width = await page.evaluate(() =>
        parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--cmux-focus-ring-width")),
      );
      expect(
        focused.map(({ spread }) => spread),
        `${box} focus ring`,
      ).toEqual([width]);
      expect(width, "wider than the rim").toBeGreaterThan(rest[0]?.spread ?? 0);
      await page.close();
    });

  // The card's one rim goes round the location strip on its top edge (composerLocation.css): the
  // card's rim layer reaches up over the strip, which draws no rim of its own, so card and strip stay
  // one outline, in one tone: the resting one, or the focused one when the card has focus.
  const tone = (shadow: string) => shadow.match(/(?:rgba?|color)\([^)]*\)/)![0];
  for (const theme of ["dark", "light"] as const)
    test(`${theme}: the card's rim round the location strip takes the focused tone`, async () => {
      const page = await open(2, theme);
      const edge = () =>
        page.evaluate(() => {
          const strip = document.getElementById("strip")!;
          const card = document.getElementById("strip-composer")!;
          const rim = getComputedStyle(card, "::before");
          return {
            shadow: rim.boxShadow,
            // Where the rim layer starts, against the strip's top: 0 when it goes round the strip.
            top: card.getBoundingClientRect().top + parseFloat(rim.top) - strip.getBoundingClientRect().top,
            stripRim: getComputedStyle(strip).boxShadow,
          };
        });
      const rest = await edge();
      await page.focus("#strip-composer-field");
      const focused = await edge();
      expect(Math.abs(focused.top), "the card's rim goes round the strip").toBeLessThan(0.5);
      expect(focused.stripRim, "the strip draws no second rim").toBe("none");
      expect(tone(focused.shadow), "the strip's edge takes the focused tone").not.toBe(tone(rest.shadow));
      await page.close();
    });

  // Queued prompts sit on the card's top edge as part of its outline: their sides and the card's rim
  // (its rim layer) draw one tone, the focused one while the card has focus.
  for (const theme of ["dark", "light"] as const)
    test(`${theme}: queued prompts' edge takes the card's focused tone`, async () => {
      const page = await open(2, theme);
      const edges = () =>
        page.evaluate(() => ({
          queue: getComputedStyle(document.getElementById("queue")!).boxShadow,
          card: getComputedStyle(document.getElementById("queue-composer")!, "::before").boxShadow,
        }));
      const rest = await edges();
      await page.focus("#queue-composer-field");
      const focused = await edges();
      expect(tone(focused.queue), "the queue's edge takes the focused tone").not.toBe(tone(rest.queue));
      expect(tone(focused.queue), "the queue and the card draw one tone").toBe(tone(focused.card));
      await page.close();
    });

  // A footer chip has no bezel: keyboard focus lays the hover wash and draws no ring (Leo
  // 2026-10-21: no focus ring; agent-pane-hairline-focus.test.ts). A pointer click draws nothing, and
  // Increase Contrast keeps the shared ring at its offset.
  test("a footer chip under keyboard focus: hover wash, no ring", async () => {
    const page = await open(2, "light");
    await installPaintedFrames(page);
    await page.focus("#composer-field");
    await page.keyboard.press("Tab");
    // The wash's hover fade settles: a frame paints the focus, then its transitions run out.
    await page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await Promise.all(
        document
          .getElementById("composer-chip")!
          .getAnimations()
          .map((animation) => animation.finished.catch(() => undefined)),
      );
    });
    const chip = () =>
      page.evaluate(() => {
        const element = document.getElementById("composer-chip")!;
        const style = getComputedStyle(element);
        // The row's own hover wash (composerLocation.css), resolved in the chip's ink: the same
        // color :hover paints, so focus and hover can't drift apart.
        const probe = document.createElement("div");
        probe.style.color = style.color;
        probe.style.background = "var(--acpmux-row-hover)";
        element.parentElement!.append(probe);
        const wash = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return {
          focused: document.activeElement === element,
          background: style.backgroundColor,
          wash,
          outline: style.outlineStyle,
          offset: style.outlineOffset,
          color: style.color,
          text: getComputedStyle(element.closest(".acpmux-shell")!).getPropertyValue("--agent-text").trim(),
        };
      });
    const keyboard = await chip();
    expect(keyboard.focused, "Tab reaches the chip").toBe(true);
    expect(keyboard.wash, "the row's hover wash resolves").not.toBe("rgba(0, 0, 0, 0)");
    // The hover's soft pill, no stronger step (Leo 2026-10-19: the Claude app's chips).
    expect(keyboard.background, "the focused chip takes the hover's wash").toBe(keyboard.wash);
    expect(keyboard.outline, "no ring, the wash alone").toBe("none");
    expect(keyboard.color, "the chip's ink steps up as on hover").toBe(keyboard.text);
    await page.emulateMedia({ contrast: "more" });
    const contrast = await chip();
    expect(contrast.outline, "Increase Contrast keeps the shared ring").toBe("solid");
    expect(contrast.offset, "Increase Contrast keeps the shared offset").toBe("2px");
    await page.emulateMedia({ contrast: "no-preference" });
    await page.mouse.click(5, 5);
    await page.click("#composer-chip");
    const pointer = await chip();
    expect(pointer.outline, "a click draws no ring").toBe("none");
    await page.close();
  });

  // Every pane popup is liquid glass (ui/popupSurface.css): frosted glass under the lens and under
  // plain glass alike (Leo: glass, never opaque); only Reduce Transparency makes it solid.
  test("the New Tab suggestions popover is glass, as every pane popup", async () => {
    const page = await open(2, "light");
    await page.evaluate(() => document.documentElement.style.setProperty("--cmux-popup-surface", "rgb(201, 202, 203)"));
    const glass = await fill(page, "popover");
    expect(glass.image, "no composer tint over it").toBe("none");
    expect(glass.rgba?.[3], "the lens's popup is glass, never opaque").toBeLessThan(1);
    await page.evaluate(() => document.documentElement.setAttribute("data-glass", "plain"));
    const { rgba, image } = await fill(page, "popover");
    expect(image, "no composer tint over it").toBe("none");
    expect(rgba?.[3], "plain glass is glass too, never opaque").toBeLessThan(1);
    await page.close();
  });

  for (const theme of ["dark", "light"] as const) {
    test(`${theme}: the New Tab box and the chat composer are a solid surface lighter than the page`, async () => {
      const page = await open(2, theme);
      const ground = pages[theme].map((channel) => channel / 255);
      for (const id of ["newtab", "composer"]) {
        const { rgba, image } = await fill(page, id);
        // At rest any layer over the surface (the New Tab box's hover lift) is clear.
        const layers = [...image.matchAll(/(?:rgba?|color)\([^)]*\)/g)].map((match) => parse(match[0]));
        for (const layer of layers) expect(layer?.[3], `${id} paints one flat color at rest`).toBe(0);
        expect(rgba, `${id} fill parsed`).not.toBeNull();
        expect(rgba![3], `${id} is solid over a wallpaper`).toBe(1);
        const step = luminance(rgba!) - luminance(ground);
        if (theme === "light") {
          // The page lifted toward white: lighter than the page, near white, keeping the page's hue.
          expect(step, `${id} is lighter than the page`).toBeGreaterThan(0.03);
          expect(luminance(rgba!), `${id} is near white`).toBeGreaterThan(0.95);
          expect(rgba![2], `${id} keeps the page's warmth`).toBeLessThan(rgba![0]);
        } else {
          // One small step lighter than the page.
          expect(step, `${id} is a step lighter than the page`).toBeGreaterThan(0.02);
          expect(step, `${id} is only a small step`).toBeLessThan(0.12);
        }
      }
      await page.close();
    });
  }
  for (const theme of ["dark", "light"] as const) {
    test(`${theme}: the composers cast ${theme === "light" ? "--elevation-1" : "no shadow"}`, async () => {
      const page = await open(2, theme);
      const result = await page.evaluate(() => {
        // The drop layers of a computed box-shadow (inset rims left out), and --elevation-1's own.
        const drops = (shadow: string) => {
          const entries: string[] = [];
          let depth = 0;
          let start = 0;
          for (let index = 0; index < shadow.length; index++) {
            const char = shadow[index];
            if (char === "(") depth++;
            else if (char === ")") depth--;
            else if (char === "," && depth === 0) {
              entries.push(shadow.slice(start, index).trim());
              start = index + 1;
            }
          }
          entries.push(shadow.slice(start).trim());
          return entries.filter((entry) => entry !== "none" && !/\binset\b/.test(entry));
        };
        const probe = document.createElement("div");
        probe.style.boxShadow = "var(--elevation-1)";
        document.body.append(probe);
        const elevation = drops(getComputedStyle(probe).boxShadow);
        probe.remove();
        const of = (id: string) => drops(getComputedStyle(document.getElementById(id)!).boxShadow);
        return { elevation, newtab: of("newtab"), composer: of("composer") };
      });
      expect(result.elevation.length, "--elevation-1 resolves").toBe(1);
      for (const id of ["newtab", "composer"] as const) {
        if (theme === "light") expect(result[id], `${id} casts --elevation-1`).toEqual(result.elevation);
        else
          for (const layer of result[id])
            expect(layer, `${id} casts no visible shadow`).toMatch(/^(?:rgba\(0, 0, 0, 0\)|transparent)|0px 0px 0px/);
      }
      await page.close();
    });
  }
});
