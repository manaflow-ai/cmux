// The New Tab composer box's focus is quiet (Lawrence 10-14, "don't like this focus thing"): focus
// keeps the box's one-device-pixel rim (--cmux-hairline) at its own width, takes at most a slight
// step in tone, never the accent, and still clears with appearance.borders none. Its fill is the
// theme's elevated surface (--cmux-elevated-background, the theme surface one small step toward
// the text, as the shared page cards use), not the composer tint's gray slab ("same bg kinda weird").
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const elevated = "rgb(40, 41, 42)";
  const elevatedLight = "rgb(250, 250, 250)";

  /** The composer-rim harness with a known dark theme and a blue accent, so a ring in the accent shows. */
  async function open(scale: number, theme: "dark" | "light" = "dark"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: scale });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate(
      ({ elevated, elevatedLight, theme }) => {
        const root = document.documentElement.style;
        root.setProperty("--cmux-elevated-background", theme === "dark" ? elevated : elevatedLight);
        root.setProperty("--cmux-surface-solid", theme === "dark" ? "rgb(30, 30, 30)" : "rgb(255, 255, 255)");
        const shell = (document.querySelector(".acpmux-shell") as HTMLElement).style;
        shell.setProperty("--agent-text", theme === "dark" ? "rgb(236, 236, 236)" : "rgb(20, 20, 20)");
        shell.setProperty("--agent-page-bg", "transparent");
        shell.setProperty("--agent-accent", "rgb(0, 122, 255)");
      },
      { elevated, elevatedLight, theme },
    );
    return page;
  }

  /** The box's inset rims: spread in CSS px and color as 0...1 channels. */
  function rims(page: Page): Promise<Rim[]> {
    return page.evaluate(() => {
      const shadow = getComputedStyle(document.getElementById("newtab")!).boxShadow;
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
    });
  }

  /** A rim as it shows: its color over the box's fill (the elevated surface the harness sets). */
  function ink([r, g, b, a]: Rim["rgba"], theme: "dark" | "light"): number[] {
    const ground = theme === "dark" ? [40 / 255, 41 / 255, 42 / 255] : [250 / 255, 250 / 255, 250 / 255];
    return [r, g, b].map((channel, index) => channel * a + ground[index] * (1 - a));
  }

  for (const theme of ["dark", "light"] as const) {
    for (const scale of [1, 2]) {
      test(`${theme} at ${scale}x: focus keeps the one-device-pixel rim, a slight step in tone, no accent`, async () => {
        const page = await open(scale, theme);
        const rest = await rims(page);
        expect(rest.length, "the box draws a rim").toBe(1);
        expect(rest[0].spread * scale, "rest rim in device px").toBe(1);
        expect(rest[0].rgba[3], "the rim's color parsed and shows").toBeGreaterThan(0);
        await page.focus("#newtab-field");
        const focused = await rims(page);
        expect(focused.length, "focus draws one rim, no extra ring").toBe(1);
        expect(focused[0].spread, "focus keeps the rim's width").toBe(rest[0].spread);
        const [r, g, b] = ink(focused[0].rgba, theme);
        expect(Math.max(Math.abs(r - g), Math.abs(g - b)), "the focused rim is neutral, not the accent").toBeLessThan(
          0.02,
        );
        const lift = Math.max(
          ...ink(focused[0].rgba, theme).map((value, index) => Math.abs(value - ink(rest[0].rgba, theme)[index])),
        );
        expect(lift, "focus lifts the rim's tone at most slightly").toBeLessThan(0.08);
        await page.close();
      });
    }
  }

  test("focused, the rim still clears with appearance.borders none", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-borders", "none"));
    await page.focus("#newtab-field");
    for (const { rgba } of await rims(page)) expect(rgba[3], "focused rim alpha with borders none").toBe(0);
    await page.close();
  });

  test("the box's fill is the theme's elevated surface, one flat color, not the composer tint", async () => {
    const page = await open(2);
    const fill = await page.evaluate(() => {
      const style = getComputedStyle(document.getElementById("newtab")!);
      return { color: style.backgroundColor, image: style.backgroundImage };
    });
    expect(fill.image).toBe("none");
    expect(fill.color).toBe(elevated);
    await page.close();
  });
});
