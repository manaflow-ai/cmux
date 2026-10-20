// The composer's and the New Tab box's rims stay continuous at their rounded corners. macOS WebKit
// snaps an inset box-shadow's inner edge to whole device pixels but not its rounded outer clip, so
// a rim thinner than one device pixel (the 0.5px rim on a 1x display, a 1px ring at 125% zoom)
// loses whole edges and the arcs next to them. Linux engines draw such a rim fine, so this checks
// the geometry contract instead: at each device scale, every inset ring on these boxes is a whole
// number of device pixels (the rim one, the focus ring one at 1x and 2x), and the composer's rim
// clears with `appearance.borders` none, as the New Tab box's does.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Inset = { spread: number; alpha: number };

await requireBrowserLane("composer-rim-hairline.test.ts", async () => {
  /** The composer edge's alpha over this page's transparent background, and its quiet focus step: 22% text over the edge
   * (Leo 2026-10-19, a subtler focus; still well past the 8% step an eye could not see). */
  const EDGE = 0.18;
  const FOCUS = 0.22 + 0.78 * EDGE;
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
          return { spread: lengths[3] ?? 0, alpha };
        });
    }, id);
  }

  /** Spread in device pixels must be a whole, non-zero number. */
  function devicePixels(spread: number, scale: number): number {
    return Math.round(spread * scale * 1000) / 1000;
  }

  for (const scale of [1, 1.25, 2]) {
    test(`at ${scale}x the rims are one device pixel and the focus rings whole device pixels`, async () => {
      const page = await open(scale);
      for (const id of ["composer", "newtab"]) {
        const rest = await insets(page, id);
        expect(rest.length, `${id} draws a rim`).toBeGreaterThan(0);
        for (const { spread } of rest) expect(devicePixels(spread, scale), `${id} rim at ${scale}x`).toBe(1);
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
        await page.focus(`#${field}`);
        const ring = await insets(page, id);
        expect(ring.length, `${id} draws a focus ring`).toBeGreaterThan(0);
        if (id === "composer") expect(ring[0]?.alpha, "composer focus rim alpha").toBeCloseTo(FOCUS, 2);
        for (const { spread } of ring) {
          const pixels = devicePixels(spread, scale);
          expect(Number.isInteger(pixels) && pixels >= 1, `${id} focus ring at ${scale}x is ${pixels} device px`).toBe(
            true,
          );
          // The ring keeps its 1px look: one CSS pixel wherever a CSS pixel is whole device pixels.
          // The New Tab box and the chat composer keep their one-device-pixel rim on focus
          // (newtab-quiet-focus.test.ts); the shell's mode ring stays one CSS pixel.
          if (id !== "shell") expect(pixels, `${id} focus rim at ${scale}x`).toBe(1);
          else if (Number.isInteger(scale)) expect(spread, `${id} focus ring at ${scale}x`).toBe(1);
        }
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

  // Over art (data-cmux-see-through) the glass card adds a top-lit rim. Under a strip or a queue the
  // card's ring is drawn once, by the ::before layer round strip and card together
  // (composerLocation.css), so the card itself must not draw the ring a second time.
  test("over art a card under a strip or a queue draws the rim but not a second ring", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
    const ring = (id: string) => insets(page, id).then((all) => all.filter(({ spread }) => spread > 0));
    const shadow = (id: string, pseudo?: string) =>
      page.evaluate(([id, pseudo]) => getComputedStyle(document.getElementById(id!)!, pseudo).boxShadow, [id, pseudo]);
    expect((await ring("composer")).length, "a card on its own keeps its ring").toBe(1);
    for (const id of ["strip-composer", "queue-composer"]) {
      expect(await ring(id), `${id} draws no ring of its own`).toEqual([]);
      expect(await shadow(id), `${id} keeps the glass rim`).toContain("0px 1px 0px 0px inset");
      expect(await shadow(id, "::before"), `${id}'s ring layer`).toMatch(/inset/);
    }
    await page.close();
  });

  // Over art the focused glass card catches more light on its top edge (the glass rim, #21786), in
  // place of a heavier ring: the ring keeps its one-device-pixel quiet step.
  test("over art keyboard focus brightens the glass card's top-lit rim", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
    const topRim = async () => (await insets(page, "composer")).find(({ spread }) => spread === 0)?.alpha ?? 0;
    const rest = await topRim();
    expect(rest, "the glass card draws its top-lit rim").toBeGreaterThan(0);
    await page.focus("#composer-field");
    expect(await topRim(), "focus brightens the top-lit rim").toBeGreaterThan(rest);
    const ring = (await insets(page, "composer")).filter(({ spread }) => spread > 0);
    expect(ring.length, "one ring").toBe(1);
    expect(ring[0]?.alpha, "the ring keeps the quiet focus step").toBeCloseTo(FOCUS, 2);
    await page.close();
  });

  test("pointer focus leaves the composer rim quiet while keyboard traversal raises it", async () => {
    const page = await open(2);
    const rest = await insets(page, "composer");
    const chip = page.locator("#composer-chip");
    await chip.click();
    // A mouse press may focus the chip, but it is not keyboard focus and must not change the card.
    expect(await insets(page, "composer")).toEqual(rest);

    // Move from the chip to the prompt with a real reverse-Tab. The prompt is then :focus-visible,
    // so the card keeps its quiet one-device-pixel focus step for keyboard users.
    await chip.focus();
    await page.keyboard.press("Shift+Tab");
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("composer-field");
    const keyboard = await insets(page, "composer");
    expect(keyboard[0]?.alpha ?? 0).toBeGreaterThan(rest[0]?.alpha ?? 0);
    await page.close();
  });
});
