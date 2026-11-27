// Every border in the composer stack is one color (user, 2026-11-20: "ensure all border colors are
// the same", on the Goal banner over the composer). The banner's edge, the seam between it and the
// card, the card's own edge, the running tray, the queued prompts, an attachment tile and the pane's
// menus all draw --acpmux-composer-edge, in light and dark, on an opaque window, over art and under
// Reduce Transparency, resting and focused: a focused composer lifts the whole stack's edge at once,
// never the card alone. The glass's light stays inside the edge (the band under the top and the sheen)
// and never paints a line on it, and where a hat joins the card only the hat is lit from above.
//
// Before: the card's specular top line sat on the seam under the banner (165 gray in the user's shot,
// where the banner's edge was 103), its return line brightened the card's bottom, a focused card lifted
// its own edge but not the banner's, and the pane's menus drew a 12% edge of their own.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-one-edge.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { focusByKey } from "./support/focusByKey";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-one-edge.test.ts", async () => {
  const HARNESS = "/test/browser/composer-one-edge.html";
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-one-edge: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer one edge", () => test("chromium", () => {}));
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
    await warmViteServer(vite, HARNESS);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(colorScheme: "light" | "dark", attributes: Record<string, string>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 440, height: 640 }, deviceScaleFactor: 2, colorScheme });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${HARNESS}`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    // shared/styles.css sets `color-scheme: dark` on the root: pin the case's own scheme.
    await page.evaluate(
      ({ attributes, colorScheme }) => {
        for (const [name, value] of Object.entries(attributes)) document.documentElement.setAttribute(name, value);
        document.documentElement.style.colorScheme = colorScheme;
      },
      { attributes, colorScheme },
    );
    return page;
  }

  type Edges = { id: string; edges: string[]; lights: string[] };

  /**
   * The colors each part draws on its edge line: its borders, and every box-shadow layer that is a
   * crisp line at most a pixel thick on the edge (a ring, or one side's line), on the part and on its
   * ::before (the card under queued prompts draws its ring there). `lights` holds the soft layers
   * (blurred, inside the edge) by their geometry.
   */
  const edgesOf = (page: Page, ids: string[]): Promise<Edges[]> =>
    page.evaluate((ids) => {
      function layers(shadow: string): string[] {
        if (!shadow || shadow === "none") return [];
        const out: string[] = [];
        let depth = 0;
        let start = 0;
        for (let i = 0; i < shadow.length; i++) {
          const c = shadow[i];
          if (c === "(") depth++;
          else if (c === ")") depth--;
          else if (c === "," && depth === 0) {
            out.push(shadow.slice(start, i).trim());
            start = i + 1;
          }
        }
        out.push(shadow.slice(start).trim());
        return out;
      }
      return ids.map((id) => {
        const element = document.getElementById(id)!;
        const edges: string[] = [];
        const lights: string[] = [];
        const before = getComputedStyle(element, "::before");
        // A ::before with no content draws nothing.
        const drawn = before.content === "none" || before.content === "normal" ? [] : [before];
        for (const style of [getComputedStyle(element), ...drawn]) {
          for (const side of ["Top", "Right", "Bottom", "Left"] as const) {
            const width = parseFloat(style.getPropertyValue(`border-${side.toLowerCase()}-width`));
            const kind = style.getPropertyValue(`border-${side.toLowerCase()}-style`);
            if (width > 0 && kind !== "none" && kind !== "hidden")
              edges.push(style.getPropertyValue(`border-${side.toLowerCase()}-color`));
          }
          for (const layer of layers(style.boxShadow)) {
            const color = layer.match(/(?:color|rgba?|oklab|oklch|lab|lch)\([^)]*\)/)?.[0] ?? "";
            const rest = layer.replace(color, "");
            const lengths = [...rest.matchAll(/(-?[\d.]+)px/g)].map((m) => Number(m[1]));
            const [x = 0, y = 0, blur = 0, spread = 0] = lengths;
            if (!rest.includes("inset")) continue;
            const ring = x === 0 && y === 0 && blur === 0 && spread > 0 && spread <= 1;
            const line =
              blur === 0 &&
              spread === 0 &&
              ((x === 0 && y !== 0 && Math.abs(y) <= 1) || (y === 0 && x !== 0 && Math.abs(x) <= 1));
            if (ring || line) edges.push(color);
            else lights.push(`${x}px ${y}px ${blur}px ${spread}px`);
          }
        }
        return { id, edges, lights };
      });
    }, ids);

  const STACK = ["goal", "goal-card", "tray", "tray-card", "queue", "bare-card", "attachment", "menu"];
  const windows: { name: string; attributes: Record<string, string> }[] = [
    { name: "an opaque window", attributes: {} },
    { name: "art under Plain glass", attributes: { "data-cmux-see-through": "", "data-glass": "plain" } },
    { name: "Reduce Transparency", attributes: { "data-cmux-see-through": "", "data-reduce-transparency": "" } },
  ];

  /** The one color every part draws on its edge, or a message naming the parts that differ. */
  function oneColor(parts: Edges[]): { color: string; drift: string[] } {
    const color = parts.find((part) => part.id.endsWith("card"))!.edges[0]!;
    const drift: string[] = [];
    for (const part of parts) {
      if (part.edges.length === 0) drift.push(`${part.id}: no edge`);
      for (const edge of part.edges) if (edge !== color) drift.push(`${part.id}: ${edge}`);
    }
    return { color, drift };
  }

  for (const colorScheme of ["light", "dark"] as const)
    for (const window of windows)
      test(`${colorScheme}, ${window.name}: every edge in the stack is one color`, async () => {
        const page = await open(colorScheme, { ...window.attributes, "data-theme": colorScheme });
        const resting = oneColor(await edgesOf(page, STACK));
        expect(resting.drift, `resting edge ${resting.color}`).toEqual([]);

        // Focus lifts the whole stack's edge, the banner's too, not the card's alone.
        // A key moved focus: code focus shows no :focus-visible (support/focusByKey.ts).
        await focusByKey(page, "#goal-field");
        const focused = oneColor(await edgesOf(page, ["goal", "goal-card", "attachment"]));
        expect(focused.drift, `focused edge ${focused.color}`).toEqual([]);
        expect(focused.color, "focus lifts the edge a step").not.toBe(resting.color);
        // The other stacks rest.
        const others = oneColor(await edgesOf(page, ["tray", "tray-card", "queue", "bare-card"]));
        expect(others.drift).toEqual([]);
        expect(others.color).toBe(resting.color);
        await page.close();
      });

  for (const colorScheme of ["light", "dark"] as const)
    test(`${colorScheme}: under the Goal banner the card gives up its top light to the banner`, async () => {
      const page = await open(colorScheme, { "data-theme": colorScheme });
      const [goal, card, bare] = await edgesOf(page, ["goal", "goal-card", "bare-card"]);
      const SPECULAR_BAND = "1px 1.5px 1px -1px";
      const SHEEN = "0px 16px 20px -16px";
      expect(bare!.lights, "a bare card is lit from above").toContain(SPECULAR_BAND);
      expect(goal!.lights, "the banner takes the card's light").toContain(SPECULAR_BAND);
      expect(goal!.lights).toContain(SHEEN);
      expect(card!.lights, "no light across the seam").not.toContain(SPECULAR_BAND);
      expect(card!.lights).not.toContain(SHEEN);
      await page.close();
    });
});
