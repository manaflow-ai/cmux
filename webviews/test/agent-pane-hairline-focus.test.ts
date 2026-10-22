// Focus in the agent pane and on New Tab is a hairline, never a ring (Leo 2026-10-21: "I HATE THE
// APPEARANCE OF THIS FOCUS RING, THE STYLE IS SHIT"; a thick light or blue ring on the composer, a
// white rounded ring round the queued prompt being edited, and a blue ring that kept appearing).
//
// - The composer box and the New Tab box: at rest one device pixel in the composer edge (18% text);
//   focused, the same one device pixel a step brighter (28% text). No wider line, no extra shadow,
//   no outline. A page that is not the key one keeps the resting edge.
// - The queued prompt's editor: no outline, the same focused hairline.
// - A button reached from the keyboard: no outline (neither the shared accent ring nor WebKit's
//   system-blue `outline: auto`); the soft pill marks it, and a solid-fill one (a ready Send, Stop, the prompt editor's Send)
//   takes its hover step, so keyboard focus always changes what it paints. Increase Contrast keeps the
//   shared ring.
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
        const lengths = [...entry.replace(/\([^)]*\)/g, "").matchAll(/(-?[\d.]+)px/g)].map((match) => Number(match[1]));
        const color = entry.match(/(?:rgba?|color)\([^)]*\)/)?.[0] ?? "";
        const alphaMatch = color.match(/\/\s*([\d.]+)\)|rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/);
        const alpha =
          color === "" || color.includes("transparent") ? 0 : alphaMatch ? Number(alphaMatch[1] ?? alphaMatch[2]) : 1;
        return { inset: /\binset\b/.test(entry), spread: lengths[3] ?? 0, alpha };
      });
    }, id);
  }
  const rims = async (page: Page, id: string) => (await shadows(page, id)).filter(({ inset }) => inset);
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

  test("under Increase Contrast a focused edge keeps the resting edge, never a dimmer one", async () => {
    const page = await open(2);
    await page.emulateMedia({ contrast: "more" });
    // The chat composer at rest draws the resting edge; the focused queued editor must match it.
    const rest = await rims(page, "composer");
    expect(rest.length, "the composer draws one rim").toBe(1);
    await page.focus("#queue-edit");
    const focused = await rims(page, "queue-edit");
    expect(focused.length, "one hairline").toBe(1);
    expect(focused[0].alpha, "the resting edge's strength").toBeCloseTo(rest[0].alpha, 2);
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

  /** What an element's background paints over a dark backdrop: its color with every gradient's
   *  color laid on top, composited on a 1x1 canvas, as [r, g, b]. */
  function paint(page: Page, id: string): Promise<number[]> {
    return page.evaluate((id) => {
      const computed = getComputedStyle(document.getElementById(id)!);
      const layers = [computed.backgroundColor];
      for (const [, args] of computed.backgroundImage.matchAll(/gradient\(((?:[^()]|\([^()]*\))*)\)/g)) {
        // A flat pill is a gradient of one color: its first stop.
        let depth = 0;
        let end = args.length;
        for (let index = 0; index < args.length; index++) {
          if (args[index] === "(") depth++;
          else if (args[index] === ")") depth--;
          else if (args[index] === "," && depth === 0) {
            end = index;
            break;
          }
        }
        layers.push(args.slice(0, end).trim());
      }
      const context = Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d")!;
      context.fillStyle = "rgb(24, 24, 24)";
      context.fillRect(0, 0, 1, 1);
      for (const layer of layers) {
        context.fillStyle = layer;
        context.fillRect(0, 0, 1, 1);
      }
      return Array.from(context.getImageData(0, 0, 1, 1).data.slice(0, 3));
    }, id);
  }
  const distance = (a: number[], b: number[]) => Math.max(...a.map((value, index) => Math.abs(value - b[index])));

  test("a button reached from the keyboard draws no ring; the soft pill marks it", async () => {
    const page = await open(2);
    // Read end states, never a hover or focus transition's first frame.
    await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
    const rest = {
      "composer-chip": await paint(page, "composer-chip"),
      "composer-send": await paint(page, "composer-send"),
    };
    await page.focus("#composer-field");
    // Tab to the model chip, then Send: both keyboard focus (:focus-visible).
    for (const id of ["composer-chip", "composer-send"] as const) {
      await page.keyboard.press("Tab");
      expect(await page.evaluate(() => document.activeElement?.id)).toBe(id);
      const style = await page.evaluate((id) => {
        const element = document.getElementById(id)!;
        const computed = getComputedStyle(element);
        return {
          visible: element.matches(":focus-visible"),
          outline: computed.outlineStyle,
        };
      }, id);
      expect(style.visible, `${id} has keyboard focus`).toBe(true);
      expect(style.outline, `${id} draws no outline`).toBe("none");
      expect(distance(await paint(page, id), rest[id]), `${id} shows the pill`).toBeGreaterThanOrEqual(8);
    }
    // Increase Contrast keeps the shared ring.
    await page.emulateMedia({ contrast: "more" });
    expect(await outline(page, "composer-send"), "Increase Contrast keeps the ring").toBe("solid");
    await page.close();
  });

  test("keyboard focus changes what a solid Send, Stop, the prompt editor's Send and a plain button paint; solid ones take the hover step", async () => {
    const page = await open(2);
    // Read end states, never a hover or focus transition's first frame.
    await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
    const ids = ["send-ready", "stop", "edit-send", "plain"];
    const rest: Record<string, number[]> = {};
    for (const id of ids) rest[id] = await paint(page, id);
    await page.hover("#stop");
    const hover = { stop: await paint(page, "stop") };
    await page.mouse.move(0, 0);
    // The base color, Stop's ink.
    const base = await page.evaluate(() => {
      const context = Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d")!;
      context.fillStyle = getComputedStyle(document.getElementById("stop")!).color;
      context.fillRect(0, 0, 1, 1);
      return Array.from(context.getImageData(0, 0, 1, 1).data.slice(0, 3));
    });
    // Tab from the checkbox: each control in turn under keyboard focus.
    await page.focus("#check");
    for (const id of ids) {
      await page.keyboard.press("Tab");
      expect(await page.evaluate(() => document.activeElement?.id)).toBe(id);
      expect(await page.evaluate((id) => document.getElementById(id)!.matches(":focus-visible"), id)).toBe(true);
      expect(await outline(page, id), `${id} draws no outline`).toBe("none");
      const focused = await paint(page, id);
      expect(
        distance(focused, rest[id]),
        `${id} focused paints visibly different (rest ${rest[id].join(",")}, focused ${focused.join(",")})`,
      ).toBeGreaterThanOrEqual(8);
      if (id === "plain") continue;
      // The solid ones take the hover step: the base 12% over the fill.
      const step = rest[id].map((value, index) => value * 0.88 + base[index] * 0.12);
      expect(
        distance(focused, step),
        `${id} focused takes the hover step (step ${step.join(",")}, focused ${focused.join(",")})`,
      ).toBeLessThanOrEqual(3);
      // Stop's hover paints that step too. (A ready Send's hover in the composer bar does not:
      // composerLocation.css's fill rule outranks composerStates.css's hover rule.)
      if (id === "stop")
        expect(
          distance(focused, hover.stop),
          `${id} focused matches its hover (${hover.stop.join(",")})`,
        ).toBeLessThanOrEqual(3);
    }
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
    const [r, g, b] = ring.color.startsWith("color(") ? channels.map((value) => value * 255) : channels;
    expect(Math.abs(r - b), `the text color, not the blue accent (${ring.color})`).toBeLessThan(8);
    expect(Math.abs(g - b), `the text color, not the blue accent (${ring.color})`).toBeLessThan(8);
    await page.close();
  });
});
