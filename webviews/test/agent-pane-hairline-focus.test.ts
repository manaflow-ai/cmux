// Focus in the agent pane and on New Tab is a hairline, never a ring (Leo 2026-10-21: "I HATE THE
// APPEARANCE OF THIS FOCUS RING, THE STYLE IS SHIT"; a thick light or blue ring on the composer, a
// white rounded ring round the queued prompt being edited, and a blue ring that kept appearing).
//
// - The composer box and the New Tab box: at rest one device pixel in the composer edge (18% text);
//   focused, the same one device pixel a step brighter (28% text). No wider line, no extra shadow,
//   no outline. A page that is not the key one keeps the resting edge.
// - The queued prompt's editor: no outline, the same focused hairline.
// - A button reached from the keyboard: no outline (neither the shared accent ring nor WebKit's
//   system-blue `outline: auto`); the soft pill marks it. Increase Contrast keeps the shared ring.
//
// Real Chromium from Playwright on the composer-rim harness (the pane's stylesheets in its entry's
// order); CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Inset = { spread: number; alpha: number };

await requireBrowserLane("agent-pane-hairline-focus.test.ts", async () => {
  /** The composer edge's alpha over the harness's transparent page, at rest and focused. */
  const REST = 0.18;
  const FOCUSED = 0.28;
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-hairline-focus: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent pane hairline focus", () => test("chromium", () => {}));
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
    const page = await browser!.newPage({
      viewport: { width: 420, height: 640 },
      deviceScaleFactor: scale,
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/composer-rim.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    return page;
  }

  /** Every entry of an element's computed box-shadow, inset or not: spread in CSS px and alpha. */
  function shadows(page: Page, id: string): Promise<(Inset & { inset: boolean })[]> {
    return page.evaluate((id) => {
      const shadow = getComputedStyle(document.getElementById(id)!).boxShadow;
      if (shadow === "none") return [];
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
      return entries.map((entry) => {
        const lengths = [...entry.replace(/\([^)]*\)/g, "").matchAll(/(-?[\d.]+)px/g)].map(
          (match) => Number(match[1]),
        );
        const color = entry.match(/(?:rgba?|color)\([^)]*\)/)?.[0] ?? "";
        const alphaMatch = color.match(/\/\s*([\d.]+)\)|rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/);
        const alpha =
          color === "" || color.includes("transparent")
            ? 0
            : alphaMatch
              ? Number(alphaMatch[1] ?? alphaMatch[2])
              : 1;
        return { inset: /\binset\b/.test(entry), spread: lengths[3] ?? 0, alpha };
      });
    }, id);
  }
  const rims = async (page: Page, id: string) =>
    (await shadows(page, id)).filter(({ inset }) => inset);
  const outline = (page: Page, id: string) =>
    page.evaluate((id) => getComputedStyle(document.getElementById(id)!).outlineStyle, id);

  for (const scale of [1, 2])
    for (const [box, field] of [
      ["composer", "composer-field"],
      ["newtab", "newtab-field"],
    ] as const)
      test(`${box} at ${scale}x: focus is the resting hairline a step brighter, no ring`, async () => {
        const page = await open(scale);
        const rest = await shadows(page, box);
        const restRims = rest.filter(({ inset }) => inset);
        expect(restRims.length, `${box} draws one rim`).toBe(1);
        expect(restRims[0].spread * scale, `${box} rim in device px`).toBe(1);
        expect(restRims[0].alpha, `${box} rim at rest`).toBeCloseTo(REST, 2);

        await page.focus(`#${field}`);
        const focused = await shadows(page, box);
        // The same layers: no ring or glow added, the drop shadow unchanged.
        expect(focused.length, `${box} focused adds no shadow`).toBe(rest.length);
        expect(
          focused.filter(({ inset }) => !inset),
          `${box} drop shadow`,
        ).toEqual(rest.filter(({ inset }) => !inset));
        const rim = focused.filter(({ inset }) => inset);
        expect(rim.length, `${box} focused draws one rim`).toBe(1);
        expect(rim[0].spread, `${box} focused rim keeps its width`).toBe(restRims[0].spread);
        expect(rim[0].alpha, `${box} focused rim brightens a step`).toBeCloseTo(FOCUSED, 2);
        expect(await outline(page, box), `${box} draws no outline`).toBe("none");
        expect(await outline(page, field), `${field} draws no outline`).toBe("none");
        await page.close();
      });

  test("a page that is not the key one keeps the resting hairline on its focused box", async () => {
    const page = await open(2);
    await page.evaluate(() => document.documentElement.setAttribute("data-page-inactive", ""));
    for (const [box, field] of [
      ["composer", "composer-field"],
      ["newtab", "newtab-field"],
    ]) {
      const rest = await rims(page, box);
      await page.focus(`#${field}`);
      expect(await rims(page, box), `${box} focused in an inactive page`).toEqual(rest);
    }
    await page.close();
  });

  test("the queued prompt's editor draws the focused hairline, never a ring", async () => {
    const page = await open(2);
    await page.focus("#queue-edit");
    expect(await outline(page, "queue-edit"), "no outline").toBe("none");
    const rim = await rims(page, "queue-edit");
    expect(rim.length, "one hairline").toBe(1);
    expect(rim[0].spread * 2, "one device pixel").toBe(1);
    expect(rim[0].alpha, "the composer's focused edge").toBeCloseTo(FOCUSED, 2);
    await page.close();
  });

  test("a button reached from the keyboard draws no ring; the soft pill marks it", async () => {
    const page = await open(2);
    await page.focus("#composer-field");
    // Tab to the model chip, then Send: both keyboard focus (:focus-visible).
    for (const id of ["composer-chip", "composer-send"]) {
      await page.keyboard.press("Tab");
      expect(await page.evaluate(() => document.activeElement?.id)).toBe(id);
      const style = await page.evaluate((id) => {
        const element = document.getElementById(id)!;
        const computed = getComputedStyle(element);
        return {
          visible: element.matches(":focus-visible"),
          outline: computed.outlineStyle,
          image: computed.backgroundImage,
          color: computed.backgroundColor,
        };
      }, id);
      expect(style.visible, `${id} has keyboard focus`).toBe(true);
      expect(style.outline, `${id} draws no outline`).toBe("none");
      // A pill: the chip's own hover wash, or the pane's pill laid over Send's fill.
      const pill =
        style.image.includes("gradient") &&
        !/gradient\((?:rgba\(0, 0, 0, 0\)(?:,\s*)?)+\)/.test(style.image);
      expect(pill || style.color !== "rgba(0, 0, 0, 0)", `${id} shows the pill`).toBe(true);
    }
    // Increase Contrast keeps the shared ring.
    await page.emulateMedia({ contrast: "more" });
    expect(await outline(page, "composer-send"), "Increase Contrast keeps the ring").toBe("solid");
    await page.close();
  });

  test("any other keyboard focus is one hairline in the text color, never the accent", async () => {
    const page = await open(2);
    // A blue accent and focus token, so a ring in either shows.
    await page.evaluate(() => {
      const root = document.documentElement.style;
      root.setProperty("--cmux-app-focus-ring", "rgb(0, 122, 255)");
      root.setProperty("--cmux-accent", "rgb(0, 122, 255)");
      root.setProperty("--agent-text", "rgb(236, 236, 236)");
    });
    await page.focus("#newtab-field");
    await page.keyboard.press("Tab");
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("check");
    const ring = await page.evaluate(() => {
      const style = getComputedStyle(document.getElementById("check")!);
      return {
        style: style.outlineStyle,
        width: parseFloat(style.outlineWidth),
        color: style.outlineColor,
      };
    });
    expect(ring.style, "a ring still marks it").toBe("solid");
    expect(ring.width, "one hairline").toBeLessThanOrEqual(1);
    const channels = [...ring.color.matchAll(/[\d.]+/g)].map((match) => Number(match[0]));
    const [r, g, b] = ring.color.startsWith("color(")
      ? channels.map((value) => value * 255)
      : channels;
    expect(Math.abs(r - b), `the text color, not the blue accent (${ring.color})`).toBeLessThan(8);
    expect(Math.abs(g - b), `the text color, not the blue accent (${ring.color})`).toBeLessThan(8);
    await page.close();
  });
});
