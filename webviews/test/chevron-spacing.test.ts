// Every chevron pager, drawn in Chromium, against design/chevrons.md (Leo, 2026-11-27: "these chevrons are
// too close dont we have any guidelines for these yet?"): each chevron's glyph box stands at least 8 px
// from the count beside it, and each step is at least a 24 px target. The composer hat's pager
// (agent-pane.hat-questions) drew its chevrons 4 px from "1 of 3" on 20 px steps; `pager-before` keeps
// that look so this file shows the check still catches it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { chevronPagerFaults, type PagerMeasure } from "../src/ui/chevronSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chevron-spacing.test.ts", async () => {
  /** Each pager: its gallery entry, a variant that shows it, and the pager's selector. */
  const PAGERS = [
    { entry: "agent-pane.hat-questions", variant: "three", pager: ".acpmux-hat-questions__pager" },
    { entry: "agent-pane.question-card", variant: "pending-paging-uneven", pager: ".acpmux-question-navigation" },
    { entry: "agent-pane.fork-switcher", variant: "b-pill", pager: '.cv-user__versions[data-version-slot="footer"]' },
  ] as const;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch (error) {
    console.warn(`chevron-spacing.test.ts: skipping, chromium did not launch (${String(error).split("\n")[0]})`);
    describe.skip("chevron spacing", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const { entry, variant } of PAGERS) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = async (entry: string, variant: string, pager: string): Promise<PagerMeasure> => {
    const address = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 760, height: 700 } });
    try {
      await page.goto(`http://127.0.0.1:${address.port}${galleryFrame(entry, { variant })}`, { waitUntil: "load" });
      await page.waitForSelector(`${pager} button svg`);
      await page.evaluate(() => document.fonts.ready.then(() => undefined));
      // Measured once the pager holds still over 10 frames (fonts and any entrance motion done).
      await page.waitForFunction(
        (selector) => {
          const w = window as unknown as { csLast?: string; csStill?: number };
          const box = document.querySelector(selector)?.getBoundingClientRect();
          const now = box ? `${box.left},${box.width}` : "";
          w.csStill = now && now === w.csLast ? (w.csStill ?? 0) + 1 : 0;
          w.csLast = now;
          return w.csStill >= 10;
        },
        pager,
        { polling: "raf" },
      );
      return await page.evaluate((selector) => {
        const root = document.querySelector(selector)!;
        const steps = [...root.querySelectorAll("button")];
        const glyphs = steps.map((step) => step.querySelector("svg")!.getBoundingClientRect());
        // The count: the pager's own text outside its buttons, as drawn (a Range's box is the glyphs').
        const words: DOMRect[] = [];
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || node.parentElement?.closest("button")) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          words.push(range.getBoundingClientRect());
        }
        const left = Math.min(...words.map((box) => box.left));
        const right = Math.max(...words.map((box) => box.right));
        const round = (n: number) => Math.round(n * 10) / 10;
        return {
          targets: steps.map((step) => {
            const box = step.getBoundingClientRect();
            return { width: round(box.width), height: round(box.height) };
          }),
          gaps: [round(left - glyphs[0]!.right), round(glyphs[glyphs.length - 1]!.left - right)],
        };
      }, pager);
    } finally {
      await page.close();
    }
  };

  describe("chevron pagers keep design/chevrons.md", () => {
    for (const { entry, variant, pager } of PAGERS) {
      test(`${entry} ${variant}`, async () => {
        const drawn = await measure(entry, variant, pager);
        expect({ drawn, faults: chevronPagerFaults(drawn) }).toEqual({ drawn, faults: [] });
      });
    }
    test("the composer hat's old look still fails it (the check bites)", async () => {
      const drawn = await measure("agent-pane.hat-questions", "pager-before", ".acpmux-hat-questions__pager");
      expect(drawn.gaps).toEqual([4, 4]);
      expect(chevronPagerFaults(drawn).length).toBe(4);
    });
  });
});
