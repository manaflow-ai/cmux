// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// A hover card over the transcript blurs what it covers, in place, in Chromium (Leo, 2026-11-05: "this
// awkward wannabe glass but kind of just opaque thing"). Chromium draws a backdrop-filter's blurred copy
// over the page's own pixels, so the transcript's text read crisp through the card's tint; the card now
// makes the stage's blocks under it blur themselves (ui/glass/seeThroughBlur.ts, chatUnderGlass.ts
// hoverCardGlass). The gallery's play opens a pull request's card over a chat; this runs it, both schemes.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/hover-card-blur-browser.test.ts
// CMUX_HOVER_CARD_CAPTURE_DIR=<dir> keeps stills of the card per scheme, the last moved over the reply's text.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-card-blur-browser.test.ts", async () => {
  const ENTRY = "agent-pane.transcript";
  const VARIANT = "github-references-other-repo";
  setDefaultTimeout(240_000);
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["dark", "light"] as const)
    test(`a pull request's hover card blurs the transcript under it (${colorScheme})`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 720 }, colorScheme, deviceScaleFactor: 2 });
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame(ENTRY, { variant: VARIANT, colorScheme, width: 760, height: 720 }));
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        // The blur attaches once the card is placed; the play only waits for the card.
        await page
          .waitForFunction(() => document.querySelector('[data-glass-under~="hover-card"]'), undefined, {
            timeout: 5_000,
          })
          .catch(() => {});
        const seen = await page.evaluate(() => {
          const card = document.querySelector<HTMLElement>(".cv-link-preview.acpmux-pr-card");
          const under = [...document.querySelectorAll<HTMLElement>('[data-glass-under~="hover-card"]')];
          return {
            ready: document.documentElement.dataset.galleryReady,
            card: !!card,
            over: card?.hasAttribute("data-glass-over") ?? false,
            under: under.map((node) => ({ name: node.className, filter: getComputedStyle(node).filter })),
          };
        });
        const captures = process.env.CMUX_HOVER_CARD_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
        if (captures && seen.card) {
          await mkdir(captures, { recursive: true });
          await page
            .locator(".cv-link-preview.acpmux-pr-card")
            .screenshot({ path: path.join(captures, `hover-card-blur-${colorScheme}.png`) });
          await page.screenshot({ path: path.join(captures, `hover-card-blur-page-${colorScheme}.png`) });
        }
        // Base UI places the card by its positioner's inline style, and writes it again on a scroll: moved
        // up over the reply's text that way, the card's hole follows it there.
        const followed = await page.evaluate(async () => {
          const popup = document.querySelector<HTMLElement>("[data-glass-over]");
          const positioner = popup?.parentElement;
          if (!popup || !positioner) return { holes: [] as number[], tops: [] as number[] };
          positioner.style.setProperty("translate", "0 -64px");
          for (let index = 0; index < 3; index++) await new Promise(requestAnimationFrame);
          const top = popup.getBoundingClientRect().top;
          const blocks = [...document.querySelectorAll<HTMLElement>('[data-glass-under~="hover-card"]')];
          return {
            holes: [...document.querySelectorAll("filter feGaussianBlur")].map((blur) =>
              Number(blur.getAttribute("y")),
            ),
            tops: blocks.map((block) => top - block.getBoundingClientRect().top),
          };
        });
        if (captures && seen.card)
          await page.screenshot({ path: path.join(captures, `hover-card-blur-over-text-${colorScheme}.png`) });
        expect(seen.ready).toBe("1");
        expect(seen.card).toBe(true);
        expect(seen.over).toBe(true);
        expect(seen.under.length).toBeGreaterThan(0);
        expect(seen.under.filter((block) => !block.filter.includes("url("))).toEqual([]);
        expect(followed.tops.some((top) => followed.holes.some((hole) => Math.abs(hole - top) <= 2))).toBe(true);
      } finally {
        await page.close();
      }
    });
});
