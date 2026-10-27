// cmux-web-test-timeout: 300
// The composer's top strip variants (Debug toggle agentPane.debug.topStripStyle, which the app sets
// on <html> as data-top-strip; composerLocation.css). The "top strip" is whatever stands on the
// card's top edge: the location strip of a new chat (chat composer and New Tab) or the queued
// prompts of a started chat. For each value:
//   - default (no attribute): in a chat, the card's full-width head, flush on the card, in the
//     card's fill, the card's top corners square under it; one rim goes round the head and the card
//     (#20391): the location strip draws none of its own and the card's rim layer reaches up around
//     it, while a queue keeps its own top and side hairlines and the card's rim layer gives way to
//     them; on the New Tab, plain text a few px over the card (Cursor's home, #21133), no fill and
//     no rim, the card's rim whole;
//   - bump: a few px above the card, the card's fill, one closed hairline ring, the card's rim whole;
//   - plain: a few px above the card, no fill and no rim, its first ink on the card's content edge
//     (where the prompt's text starts), the card's rim whole;
//   - tray: a filled tray tucked under the card's top edge, one inset for the location strip and
//     the queue, its first ink on the card's content edge, a lighter fill than the card's in a light
//     theme, the card's rim whole and drawn over the tray.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
  const stageURL = (entry: string, variant: string, theme?: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-strip", { browser, params: { variant: "project" } });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser });
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
    const lead = box.querySelector(".acpmux-composer-inner .acpmux-composer-plus .acpmux-icon");
    // A location icon's ink starts 1.5 px inside its box (ui/ghost.css); a queued prompt's text at its box.
    const icon = top.querySelector(".acpmux-location-icon");
    const mark = top.querySelector(".acpmux-queued-clamp");
    const ink = icon ? icon.getBoundingClientRect().left + 1.5 : mark!.getBoundingClientRect().left;
    const shadows = style.boxShadow === "none" ? [] : style.boxShadow.split(/,(?![^(]*\))/);
    const cardBox = box.getBoundingClientRect();
    return {
      kind: top.classList.contains("acpmux-composer-queue") ? "queue" : "strip",
      gap: cardBox.top - top.getBoundingClientRect().bottom,
      filled: style.backgroundColor !== "rgba(0, 0, 0, 0)",
      shadows,
      cardMasked: getComputedStyle(box, "::before").content !== "none",
      cardTopRadius:
        parseFloat(getComputedStyle(box).borderTopLeftRadius) + parseFloat(getComputedStyle(box).borderTopRightRadius),
      // The prompt's text column, or the + glyph's 16 px box where + stands beside the prompt
      // (the Claude desktop box, composerLocation.css).
      contentEdge: (lead ?? field).getBoundingClientRect().left - cardBox.left,
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
    // The strip over the New Tab card is the top-of-page templates' (Threads here): the default
    // Cards draws it in a row under its pill field, and Default's stage layout in the footer under
    // the box (new-tab-stage-layout, new-tab-cards-template).
    {
      name: "New Tab strip",
      entry: "agent-pane.new-tab",
      variant: "template-threads",
      card: ".nt-box",
      kind: "strip",
    },
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
          if (style === "default" && surface.kind === "strip") {
            // A new chat's strip, the chat's as the New Tab's (#21133; Leo 2026-10-25): plain text a
            // few px over the card, nothing drawn, the card's rim whole.
            expect(drawn.gap).toBeGreaterThanOrEqual(2);
            expect(drawn.gap).toBeLessThanOrEqual(8);
            expect(drawn.filled).toBe(false);
            expect(drawn.shadows).toEqual([]);
            expect(drawn.cardMasked).toBe(false);
            return;
          }
          if (style === "default") {
            // A started chat's queue is the card's head (#20391): flush, filled, the card's top
            // corners square under it, and the card's rim layer drawn. The queue draws its own
            // hairline on its top and sides.
            expect(Math.abs(drawn.gap)).toBeLessThanOrEqual(0.5);
            expect(drawn.filled).toBe(true);
            expect(drawn.shadows.length).toBe(3);
            expect(drawn.cardMasked).toBe(true);
            expect(drawn.cardTopRadius).toBe(0);
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

  /**
   * Runs in the page: every box that paints in the plain strip's gap above the card. The strip and
   * the queue, their pseudo-elements and the card's ::before each count when they draw a border, a
   * shadow or a fill and reach into the gap (from just above the top strip's bottom to the card's
   * top edge), so the card's own rim never does.
   */
  function strayInGap(card: string) {
    const box = document.querySelector(card)!;
    const cardTop = box.getBoundingClientRect().top;
    const tops = [...document.querySelectorAll(".acpmux-composer-queue, .acpmux-composer-strip")];
    const gapTop = Math.max(...tops.map((top) => top.getBoundingClientRect().bottom)) - 3;
    const paints = (style: CSSStyleDeclaration) =>
      style.boxShadow !== "none" ||
      style.backgroundColor !== "rgba(0, 0, 0, 0)" ||
      style.backgroundImage !== "none" ||
      ["top", "right", "bottom", "left"].some(
        (side) =>
          parseFloat(style.getPropertyValue(`border-${side}-width`)) > 0 &&
          style.getPropertyValue(`border-${side}-style`) !== "none",
      );
    const found: string[] = [];
    for (const element of [...tops, box])
      for (const pseudo of [null, "::before", "::after"] as const) {
        if (element === box && pseudo !== "::before") continue;
        const style = getComputedStyle(element, pseudo);
        if (pseudo && style.content === "none") continue;
        if (!paints(style)) continue;
        const rect = element.getBoundingClientRect();
        // An ::after that hangs below its host (top: 100%) spans its own height under it.
        const below = pseudo === "::after" && style.top !== "auto";
        const from = below ? rect.bottom : rect.top;
        const to = below ? rect.bottom + (parseFloat(style.height) || 0) : rect.bottom;
        if (to > gapTop + 0.01 && from < cardTop - 0.01)
          found.push(`${element.className}${pseudo ?? ""}: ${style.boxShadow} / ${style.backgroundColor}`);
      }
    return found;
  }

  // plain draws nothing but its text: no side hairline or foot left over from the default tab stands
  // in the gap above the card's top corners (light themes showed it; cg-design-judge 2026-10-15).
  for (const surface of surfaces)
    for (const theme of ["Catppuccin Latte", "Apple System Colors Light", "Catppuccin Mocha"])
      test(`${surface.name}, plain, ${theme}: nothing drawn in the gap above the card`, async () => {
        const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
        await page.goto(stageURL(surface.entry, surface.variant, theme));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.evaluate(async () => {
          document.documentElement.setAttribute("data-top-strip", "plain");
          await document.fonts.ready;
        });
        const stray = await page.evaluate(strayInGap, surface.card);
        await page.close();
        expect(stray).toEqual([]);
      });

  /** Runs in the page: the tray against the card it tucks under. */
  function measureTray(card: string) {
    const box = document.querySelector(card)!;
    const cardBox = box.getBoundingClientRect();
    const top = (document.querySelector(".acpmux-composer-queue") ?? document.querySelector(".acpmux-composer-strip"))!;
    const topBox = top.getBoundingClientRect();
    const field = box.querySelector(".ProseMirror, textarea, [contenteditable]")!;
    const lead = box.querySelector(".acpmux-composer-inner .acpmux-composer-plus .acpmux-icon");
    // The folder icon's ink is its ghost bearing (1.5 px, ui/ghost.css) inside its box; a queued
    // prompt's ink is its text, left-aligned.
    const icon = top.querySelector(".acpmux-location-icon");
    const mark = top.querySelector(".acpmux-queued-clamp");
    let ink: number;
    if (icon) ink = icon.getBoundingClientRect().left + 1.5;
    else {
      const range = document.createRange();
      range.selectNodeContents(mark!);
      ink = range.getBoundingClientRect().left;
    }
    // A point inside the tuck (below the card's top edge, inside its rounded corner) hits the card.
    const probe = document.elementFromPoint(cardBox.left + cardBox.width / 2, cardBox.top + 4);
    return {
      kind: top.classList.contains("acpmux-composer-queue") ? "queue" : "strip",
      insetLeft: topBox.left - cardBox.left,
      insetRight: cardBox.right - topBox.right,
      tucked: topBox.bottom - cardBox.top,
      cardOnTop: !!probe && box.contains(probe),
      fill: getComputedStyle(top).backgroundColor,
      cardFill: getComputedStyle(box).backgroundColor,
      cardMasked: getComputedStyle(box, "::before").content !== "none",
      // The prompt's text column, or the + glyph's 16 px box where + stands beside the prompt
      // (the Claude desktop box, composerLocation.css).
      contentEdge: (lead ?? field).getBoundingClientRect().left - cardBox.left,
      inkFromCard: ink - cardBox.left,
    };
  }

  const trayThemes = [
    { slug: "Catppuccin Latte", light: true },
    { slug: "Apple System Colors Light", light: true },
    { slug: "Catppuccin Mocha", light: false },
  ];
  async function drawTray(surface: (typeof surfaces)[number], width: number, theme: string) {
    const page = await browser!.newPage({ viewport: { width, height: 560 } });
    await page.goto(stageURL(surface.entry, surface.variant, theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(async () => {
      document.documentElement.setAttribute("data-top-strip", "tray");
      await document.fonts.ready;
    });
    const drawn = await page.evaluate(measureTray, surface.card);
    await page.close();
    return drawn;
  }

  for (const surface of surfaces)
    for (const width of [760, 400])
      for (const theme of trayThemes)
        test(`${surface.name}, tray, ${width} px, ${theme.slug}`, async () => {
          const drawn = await drawTray(surface, width, theme.slug);
          expect(drawn.kind).toBe(surface.kind);
          // Tucked under the card's top edge, the card's whole rim drawn over it.
          expect(drawn.tucked).toBeGreaterThanOrEqual(8);
          expect(drawn.cardOnTop).toBe(true);
          expect(drawn.cardMasked).toBe(false);
          // The first ink (folder icon, queue number) on the prompt's text column.
          expect(Math.abs(drawn.inkFromCard - drawn.contentEdge)).toBeLessThanOrEqual(0.5);
          // Filled; in a light theme a tone of its own, not the card's.
          expect(drawn.fill).not.toBe("rgba(0, 0, 0, 0)");
          if (theme.light) expect(drawn.fill).not.toBe(drawn.cardFill);
          expect(Math.abs(drawn.insetLeft - drawn.insetRight)).toBeLessThanOrEqual(0.5);
        });

  // One inset: the new chat's strip and a started chat's queue stand the same distance in from the
  // card's sides, at both widths.
  for (const width of [760, 400])
    test(`tray, ${width} px: the location strip and the queue share one inset`, async () => {
      const strip = await drawTray(surfaces[0]!, width, "Catppuccin Latte");
      const queue = await drawTray(surfaces[1]!, width, "Catppuccin Latte");
      expect(Math.abs(strip.insetLeft - queue.insetLeft)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(strip.tucked - queue.tucked)).toBeLessThanOrEqual(0.5);
    });
});
