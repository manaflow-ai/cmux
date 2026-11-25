// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The detector for one class of row bug (cmuxterm-hq docs/handbook/patterns/hover-controls-reserve-width.md):
// a row whose controls show only under the pointer (or only in some states) kept a column, margin or
// padding for them at rest, so its words cut early next to empty space. Leo, 2026-11-24, on a failed
// subagent line cut at "API e..." to leave room for a hidden Retry: "this is the same kind of
// problem. you're early ellipsis-ing because of a button that doesnt even always show"; and earlier:
// "if the buttons show on hover, then we should show the whole line before ellipsis-ing. and when the
// area is hovered over, there's that whatever some amount of good fading that makes it all feel like
// one motion".
//
// In real Chromium on the gallery frames, at 360 and 760px, for a queued prompt (ComposerQueue) and
// for a failed and a stopped subagent's end line (SubagentDoneLine, Retry and Resume):
// - at rest, the words' box runs under the hidden controls (no room is kept for them): its end lies
//   past the controls' start, where a kept column or margin would end it before them;
// - under the pointer, the controls show, the words' box does not move or change width (no reflow),
//   and only the mask covers their end (`--ui-reveal-cover` grows to the controls' width over them).
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-controls-reserve-width-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const HEIGHT = 420;
  const WIDTHS = [360, 760];
  type Case = {
    name: string;
    entry: string;
    variant: string;
    /** The row (the reveal's host), its words and its hover controls. */
    row: string;
    text: string;
    controls: string;
    /** Words that end before the controls when they fit (a line whose time follows its words): the
     *  fixture is long enough to be cut at every width, so they reach the controls. */
    flows?: boolean;
  };
  const CASES: Case[] = [
    {
      name: "queued prompt",
      entry: "agent-pane.queue-system-notes",
      variant: "band",
      row: ".acpmux-queued[data-reveal-host]",
      text: ".acpmux-queued-clamp",
      controls: ".acpmux-queued-actions",
    },
    {
      name: "failed subagent line (Retry)",
      entry: "agent-pane.subagent-row-reveal",
      variant: "pick",
      row: '.cv-subagent-done-row[data-state="failed"]',
      text: ".ui-reveal-text",
      controls: ".cv-subagent-done__controls",
    },
    {
      name: "stopped subagent line (Resume)",
      entry: "agent-pane.subagent-row-reveal",
      variant: "pick",
      row: '.cv-subagent-done-row[data-state="cancelled"]',
      text: ".ui-reveal-text",
      controls: ".cv-subagent-done__controls",
      flows: true,
    },
  ];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const entry of new Set(CASES.map((c) => c.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: CASES.find((c) => c.entry === entry)!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The row's boxes, the controls' opacity and the words' cover, read in the page.
  const measure = (page: Page, c: Case) =>
    page.evaluate(({ row, text, controls }) => {
      const host = document.querySelector(row)!;
      const words = host.querySelector(text)!;
      const strip = host.querySelector(controls)!;
      const box = (el: Element) => {
        const r = el.getBoundingClientRect();
        return { left: r.left, right: r.right, width: r.width, top: r.top };
      };
      return {
        text: box(words),
        controls: box(strip),
        opacity: Number(getComputedStyle(strip).opacity),
        cover: parseFloat(getComputedStyle(words).getPropertyValue("--ui-reveal-cover")) || 0,
        cut: words.scrollWidth > words.clientWidth + 1,
      };
    }, c);

  describe("hover-only controls keep no room at rest", () => {
    for (const c of CASES)
      for (const width of WIDTHS)
        test(`${c.name} at ${width}px: the words run under the hidden controls; hover only masks them`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(c.entry, { variant: c.variant, width, height: HEIGHT }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            await page.locator(c.row).first().waitFor();
            // The pointer away from every row.
            await page.mouse.move(0, HEIGHT - 1);
            await page.waitForFunction(
              ({ row, controls }) =>
                Number(getComputedStyle(document.querySelector(row)!.querySelector(controls)!).opacity) === 0,
              c,
            );
            const rest = await measure(page, c);
            // Long fixture words: cut at this width, so they meet the controls' place.
            if (c.flows) expect(rest.cut).toBe(true);
            // No room kept: the words' box runs past where the controls start (a kept column or
            // margin ends it at or before them), and nothing covers them at rest.
            expect(rest.text.right).toBeGreaterThan(rest.controls.left + 4);
            expect(rest.cover).toBe(0);

            await page.locator(c.row).first().hover();
            await page.waitForFunction(
              ({ row, controls }) =>
                Number(getComputedStyle(document.querySelector(row)!.querySelector(controls)!).opacity) > 0.99,
              c,
              { timeout: 5_000 },
            );
            await page.waitForFunction(
              ({ row, text, controls }) => {
                const host = document.querySelector(row)!;
                const strip = host.querySelector(controls)!.getBoundingClientRect();
                const cover = parseFloat(
                  getComputedStyle(host.querySelector(text)!).getPropertyValue("--ui-reveal-cover"),
                );
                return cover > 0 && cover >= Math.min(strip.width, 8) - 0.5;
              },
              c,
              { timeout: 5_000 },
            );
            const hover = await measure(page, c);
            // The words' box is where it was: the controls lie over it, nothing reflows.
            expect(Math.abs(hover.text.left - rest.text.left)).toBeLessThanOrEqual(0.5);
            expect(Math.abs(hover.text.width - rest.text.width)).toBeLessThanOrEqual(0.5);
            expect(Math.abs(hover.text.top - rest.text.top)).toBeLessThanOrEqual(0.5);
            // The mask covers no more than the controls are wide.
            expect(hover.cover).toBeLessThanOrEqual(hover.controls.width + 0.5);
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
