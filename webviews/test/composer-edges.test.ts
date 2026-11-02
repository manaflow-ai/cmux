// The composer card and the permission cards draw one quiet hairline and no glass (hq#1957, the
// border hunt). #20303 gave the card an inset text-color rim that ignored appearance.borders = none,
// and the permission cards a .5px border:
//   - each keeps one thin Liquid Glass-like rim (Leo: don't strip it to zero): the composer card's
//     resting edge is the --acpmux-composer-edge hairline (one inset layer), a permission card's a
//     .5px border (no inset layer);
//   - under appearance.borders = none (`data-borders="none"` on the root) neither surface draws
//     a visible edge at rest: every inset layer and border is clear.
// Their drop shadows are the shared elevation scale's, which subtle-elevation.test.ts owns; this
// file reads only the edges (inset layers and borders).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Edge = {
  shadows: { inset: boolean; alpha: number; ring: boolean }[];
  border: { width: number; alpha: number };
};

await requireBrowserLane("composer-edges.test.ts", async () => {
  /** Runs in the page: the edges `selector` draws. */
  function edges(selector: string): Edge {
    const element = document.querySelector(selector)!;
    const style = getComputedStyle(element);
    const alpha = (color: string) => {
      // A `color(srgb r g b / a)` (Chromium's form for a color-mix) carries its alpha after the slash.
      const srgb = /color\([^)]*\/\s*([\d.e-]+)\)/.exec(color);
      if (srgb) return parseFloat(srgb[1]!);
      if (/color\(/.test(color)) return 1;
      const match = /rgba?\(([^)]*)\)/.exec(color);
      if (!match) return color === "transparent" ? 0 : 1;
      const parts = match[1]!.split(/[ ,/]+/).filter(Boolean);
      return parts.length > 3 ? parseFloat(parts[3]!) : 1;
    };
    const layers: string[] = [];
    let depth = 0;
    let current = "";
    // Under a location strip the card draws its rim on ::before, leaving out the strip's seam.
    const before = getComputedStyle(element, "::before");
    const shadows = [style.boxShadow, before.content !== "none" ? before.boxShadow : "none"]
      .filter((value) => value !== "none")
      .join(", ");
    for (const char of shadows) {
      if (char === "(") depth++;
      if (char === ")") depth--;
      if (char === "," && depth === 0) {
        layers.push(current);
        current = "";
      } else current += char;
    }
    if (current.trim()) layers.push(current);
    return {
      shadows: layers.map((layer) => {
        const lengths = [...layer.replace(/\([^)]*\)/g, "").matchAll(/(-?[\d.]+)px/g)].map((match) => Number(match[1]));
        return { inset: /\binset\b/.test(layer), alpha: alpha(layer), ring: (lengths[3] ?? 0) !== 0 };
      }),
      border: { width: parseFloat(style.borderTopWidth) || 0, alpha: alpha(style.borderTopColor) },
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-edges: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer edges", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  const open = async (entry: string, variant: string, ready: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 720, height: 420 } });
    for (;;) {
      try {
        await page.goto(url(entry, variant));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.locator(ready).first().waitFor();
    return page;
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer-row", "agent-pane.permission-panel"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const surfaces = [
    {
      name: "composer card",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      selector: ".acpmux-composer-box",
    },
    {
      name: "permission card",
      entry: "agent-pane.permission-panel",
      variant: "pending",
      selector: ".acpmux-permission-surface",
    },
  ];

  for (const surface of surfaces) {
    test(`${surface.name}: appearance.borders = none draws no edge`, async () => {
      const page = await open(surface.entry, surface.variant, surface.selector);
      await page.evaluate(() => {
        document.documentElement.dataset.borders = "none";
        (document.activeElement as HTMLElement | null)?.blur();
      });
      const measured = await page.evaluate(edges, surface.selector);
      await page.close();
      expect(measured.shadows.filter((layer) => layer.inset && layer.alpha > 0)).toEqual([]);
      expect(measured.border.width === 0 || measured.border.alpha === 0).toBe(true);
    });
  }

  test("composer card: one hairline edge by default", async () => {
    const page = await open("agent-pane.composer-row", "claude-auto", ".acpmux-composer-box");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    const measured = await page.evaluate(edges, ".acpmux-composer-box");
    await page.close();
    // The ring is the inset layer with a spread. The glass's light rim (#24593, composerStates.css
    // --acpmux-composer-rim) adds a top and a bottom line with no spread: lighting, not an edge.
    const rims = measured.shadows.filter((layer) => layer.inset && layer.ring);
    expect(rims).toHaveLength(1);
    expect(rims[0]!.alpha).toBeGreaterThan(0);
  });

  test("permission card: one .5px hairline by default", async () => {
    const page = await open("agent-pane.permission-panel", "pending", ".acpmux-permission-surface");
    const measured = await page.evaluate(edges, ".acpmux-permission-surface");
    await page.close();
    expect(measured.border.width).toBeGreaterThan(0);
    expect(measured.border.width).toBeLessThanOrEqual(1);
    expect(measured.border.alpha).toBeGreaterThan(0);
    expect(measured.shadows.filter((layer) => layer.inset)).toEqual([]);
  });
});
