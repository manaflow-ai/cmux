// The composer's top strip variants (Debug toggle agentPane.debug.topStripStyle, which the app sets
// on <html> as data-top-strip; composerLocation.css). The "top strip" is whatever stands on the
// card's top edge: the location strip of a new chat (chat composer and New Tab) or the queued
// prompts of a started chat. For each value:
//   - default (no attribute): today's tab, flush on the card, in the card's fill, its rim open at
//     the bottom, and the card's rim masked under the strip;
//   - bump: a few px above the card, the card's fill, one closed hairline ring, the card's rim whole;
//   - plain: a few px above the card, no fill and no rim, its first ink on the card's content edge
//     (where the prompt's text starts), the card's rim whole.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-top-strip-variants.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-top-strip-variants: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer top strip variants", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 720, height: 400 } });
    await warm.goto(stageURL("agent-pane.composer-strip", "project"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Runs in the page: the top strip against the card under it. */
  function measure(card: string) {
    const box = document.querySelector(card)!;
    const top = (document.querySelector(".acpmux-composer-queue") ?? document.querySelector(".acpmux-composer-strip"))!;
    const style = getComputedStyle(top);
    const field = box.querySelector(".ProseMirror, textarea, [contenteditable]")!;
    // A location icon's ink starts 1.5 px inside its box (ui/ghost.css); a queue's number at its box.
    const icon = top.querySelector(".acpmux-location-icon");
    const mark = top.querySelector(".acpmux-queued-mark");
    const ink = icon ? icon.getBoundingClientRect().left + 1.5 : mark!.getBoundingClientRect().left;
    const shadows = style.boxShadow === "none" ? [] : style.boxShadow.split(/,(?![^(]*\))/);
    const cardBox = box.getBoundingClientRect();
    return {
      kind: top.classList.contains("acpmux-composer-queue") ? "queue" : "strip",
      gap: cardBox.top - top.getBoundingClientRect().bottom,
      filled: style.backgroundColor !== "rgba(0, 0, 0, 0)",
      shadows,
      cardMasked: getComputedStyle(box, "::before").content !== "none",
      contentEdge: field.getBoundingClientRect().left - cardBox.left,
      inkFromCard: ink - cardBox.left,
    };
  }

  const surfaces = [
    {
      name: "new chat strip",
      entry: "agent-pane.composer-strip",
      variant: "project",
      card: ".acpmux-composer-box",
      kind: "strip",
    },
    {
      name: "mid-chat queue",
      entry: "agent-pane.composer-strip",
      variant: "queued",
      card: ".acpmux-composer-box",
      kind: "queue",
    },
    { name: "New Tab strip", entry: "agent-pane.new-tab", variant: "empty", card: ".nt-box", kind: "strip" },
  ];
  const ring = /0px 0px 0px (0\.5|1)px inset/;

  for (const surface of surfaces)
    for (const style of ["default", "bump", "plain"] as const)
      for (const width of [760, 400])
        test(`${surface.name}, ${style}, ${width} px`, async () => {
          const page = await browser!.newPage({ viewport: { width, height: 560 } });
          await page.goto(stageURL(surface.entry, surface.variant));
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.evaluate(async (value) => {
            if (value !== "default") document.documentElement.setAttribute("data-top-strip", value);
            await document.fonts.ready;
          }, style);
          const drawn = await page.evaluate(measure, surface.card);
          await page.close();
          expect(drawn.kind).toBe(surface.kind);
          if (style === "default") {
            // Today's tab: flush, filled, the hairline on its top and sides only.
            expect(Math.abs(drawn.gap)).toBeLessThanOrEqual(0.5);
            expect(drawn.filled).toBe(true);
            expect(drawn.shadows.length).toBe(3);
            expect(drawn.cardMasked).toBe(surface.kind === "strip");
            return;
          }
          expect(drawn.gap).toBeGreaterThanOrEqual(2);
          expect(drawn.gap).toBeLessThanOrEqual(6);
          expect(drawn.cardMasked).toBe(false);
          if (style === "bump") {
            expect(drawn.filled).toBe(true);
            expect(drawn.shadows.length).toBe(1);
            expect(drawn.shadows[0]).toMatch(ring);
          } else {
            expect(drawn.filled).toBe(false);
            expect(drawn.shadows).toEqual([]);
            expect(Math.abs(drawn.inkFromCard - drawn.contentEdge)).toBeLessThanOrEqual(1);
          }
        });
});
