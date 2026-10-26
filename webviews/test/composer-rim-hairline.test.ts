// The composer's and the New Tab box's rims stay continuous at their rounded corners. macOS WebKit
// snaps an inset box-shadow's inner edge to whole device pixels but not its rounded outer clip, so
// a rim thinner than one device pixel (the 0.5px rim on a 1x display, a 1px ring at 125% zoom)
// loses whole edges and the arcs next to them. Linux engines draw such a rim fine, so this checks
// the geometry contract instead: at each device scale, every inset ring on these boxes is a whole
// number of device pixels (the rim one at 1x and 2x), and the composer's rim clears with
// `appearance.borders` none, as the New Tab box's does. Focus draws no ring and no glass rim: a
// focused box keeps its one rim at the same width, a step brighter (Leo 2026-10-21: "a subtle
// hairline border that brightens slightly on focus"; agent-pane-hairline-focus.test.ts).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Inset = { offsetY: number; spread: number; alpha: number };

await requireBrowserLane("composer-rim-hairline.test.ts", async () => {
  /** The composer edge's alpha over this page's transparent background, focused or not. */
  const EDGE = 0.18;
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-rim-hairline: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer rim hairline", () => test("chromium", () => {}));
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

  async function open(scale: number): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 420, height: 480 }, deviceScaleFactor: scale });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    return page;
  }

  /** The inset entries of an element's computed box-shadow: spread in CSS px and the color's alpha. */
  function insets(page: Page, id: string): Promise<Inset[]> {
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
          const color = entry.match(/(?:rgba?|color)\([^)]*\)/)?.[0] ?? "";
          const alphaMatch = color.match(/\/\s*([\d.]+)\)|rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/);
          const alpha =
            color === "" || color.includes("transparent") ? 0 : alphaMatch ? Number(alphaMatch[1] ?? alphaMatch[2]) : 1;
          return { offsetY: lengths[1] ?? 0, spread: lengths[3] ?? 0, alpha };
        });
    }, id);
  }

  /** Spread in device pixels must be a whole, non-zero number. */
  function devicePixels(spread: number, scale: number): number {
    return Math.round(spread * scale * 1000) / 1000;
  }

  for (const scale of [1, 1.25, 2]) {
    test(`at ${scale}x the rims are one device pixel, and focus leaves them as they rest`, async () => {
      const page = await open(scale);
      for (const id of ["composer", "newtab"]) {
        const rest = await insets(page, id);
        expect(rest.length, `${id} draws a rim`).toBeGreaterThan(0);
        // A ring's spread, or a glass rim line's offset (the composer's top-lit and bottom lines,
        // which have no spread), is one device pixel.
        for (const { offsetY, spread } of rest)
          expect(devicePixels(Math.abs(spread || offsetY), scale), `${id} rim at ${scale}x`).toBe(1);
      }
      // The rims keep their colors: only the width changed.
      // The rim is the composer edge hairline (--acpmux-composer-edge: 18% text, hq#1957).
      expect((await insets(page, "composer"))[0]?.alpha, "composer rim alpha").toBeCloseTo(EDGE, 2);
      const shell = await insets(page, "shell");
      expect(shell.length, "shell draws a rim").toBeGreaterThan(0);
      for (const { spread } of shell)
        expect(Number.isInteger(devicePixels(spread, scale)), `shell rim at ${scale}x`).toBe(true);
      for (const [id, field] of [
        ["composer", "composer-field"],
        ["shell", "shell-field"],
        ["newtab", "newtab-field"],
      ]) {
        const rest = await insets(page, id);
        await page.focus(`#${field}`);
        // No focus ring: the focused box keeps its resting rim's width (the shell its tone too).
        const focused = await insets(page, id);
        expect(
          focused.map(({ spread }) => spread),
          `${id} focused keeps its rim's width`,
        ).toEqual(rest.map(({ spread }) => spread));
        if (id === "shell") expect(focused, "the shell's accent rim stays as it rests").toEqual(rest);
      }
      await page.close();
    });
  }

  test("the composer's rim clears with appearance.borders none, as the New Tab box's does", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-borders", "none"));
    for (const id of ["composer", "newtab"]) {
      const rim = await insets(page, id);
      for (const { alpha } of rim) expect(alpha, `${id} rim with borders none`).toBe(0);
    }
    await page.close();
  });

  // The glass card adds a top-lit rim, one device pixel (--cmux-hairline): over art under Lens the
  // liquid glass's specular line, under Plain glass the composer's light rim (composerStates.css).
  // Under a strip or a queue the card's ring is drawn once, by the ::before layer round strip and
  // card together (composerLocation.css), so the card itself must not draw the ring a second time.
  for (const [mode, rim] of [
    ["lens", "0px 0.5px 0px 0px inset"],
    ["plain", "0px 0.5px 0px 0px inset"],
  ] as const) {
    test(`over art a card under a strip or a queue draws the ${mode} rim but not a second ring`, async () => {
      const page = await open(2);
      await page.evaluate((mode) => {
        document.documentElement.setAttribute("data-cmux-see-through", "");
        document.documentElement.setAttribute("data-glass", mode);
      }, mode);
      const ring = (id: string) => insets(page, id).then((all) => all.filter(({ spread }) => spread > 0));
      const shadow = (id: string, pseudo?: string) =>
        page.evaluate(
          ([id, pseudo]) => getComputedStyle(document.getElementById(id!)!, pseudo).boxShadow,
          [id, pseudo],
        );
      expect((await ring("composer")).length, "a card on its own keeps its ring").toBe(1);
      for (const id of ["strip-composer", "queue-composer"]) {
        expect(await ring(id), `${id} draws no ring of its own`).toEqual([]);
        expect(await shadow(id), `${id} keeps the glass rim`).toContain(rim);
        expect(await shadow(id, "::before"), `${id}'s ring layer`).toMatch(/inset/);
      }
      await page.close();
    });
  }

  // Over art the glass card keeps its top-lit rim (#21786) as it rests: focus never brightens it
  // (#22114's glass focus rim flashed, Leo 2026-10-19); only the hairline ring takes its focused step.
  test("over art focus leaves the glass card's top-lit rim as it rests and adds no ring", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
    const topRim = async () => (await insets(page, "composer")).find(({ spread }) => spread === 0)?.alpha ?? 0;
    const rest = await insets(page, "composer");
    const restTop = await topRim();
    expect(restTop, "the glass card draws its top-lit rim").toBeGreaterThan(0);
    await page.focus("#composer-field");
    expect(await topRim(), "focus leaves the top-lit rim").toBe(restTop);
    expect(
      (await insets(page, "composer")).map(({ spread }) => spread),
      "focus adds no ring and widens none",
    ).toEqual(rest.map(({ spread }) => spread));
    await page.close();
  });

  test("pointer focus on a chip leaves the composer rim; the prompt's focus brightens it a step", async () => {
    const page = await open(2);
    const rest = await insets(page, "composer");
    const chip = page.locator("#composer-chip");
    await chip.click();
    // A mouse press may focus the chip, but it is not keyboard focus and must not change the card.
    expect(await insets(page, "composer")).toEqual(rest);

    // Move from the chip to the prompt with a real reverse-Tab. The prompt is then :focus-visible,
    // and the card draws its one rim, the same width, a step brighter.
    await chip.focus();
    await page.keyboard.press("Shift+Tab");
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("composer-field");
    const focused = await insets(page, "composer");
    expect(focused.map(({ spread }) => spread)).toEqual(rest.map(({ spread }) => spread));
    expect(focused[0].alpha, "a step brighter").toBeGreaterThan(rest[0].alpha);
    await page.close();
  });
});
