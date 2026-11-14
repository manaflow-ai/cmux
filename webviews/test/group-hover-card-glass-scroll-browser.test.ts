// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// A "Received N messages" row's hover card (MessageGroupHover.tsx in a ui/Tooltip card) is the one
// hover card glass and scrolls in itself (Leo, 2026-11-14, on that card over his chat: "this has no
// transparency at all + is not scrollable"). In a see-through Chromium page a floating glass that
// does not blur what it covers lays the theme surface under its tint (glass.css "CHROMIUM OVER THE
// WINDOW GLASS": 78% tint over a 70% underlay reads 93% solid). A Tooltip card now takes the hover
// card material a link's card has (ui/glass/hoverCardGlass.ts): the chat under it blurs in place and
// it draws no underlay. Its height stops at the window's and its content scrolls with the wheel and
// Page Down, while the transcript under it stays where it was.
// Locally (Linux lane only): cmux-ci test --setup webviews -- bun test test/group-hover-card-glass-scroll-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("group-hover-card-glass-scroll-browser.test.ts", async () => {
  const ENTRY = "agent-pane.received-messages";
  const VARIANT = "hover-long";
  const POPUP = ".cv-group-hover__popup";
  const HEAD = ".cv-message-group__head";
  const WIDTH = 760;
  const HEIGHT = 560;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT, background: "dark" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = (page: Page) =>
    page.waitForFunction(
      (selector) => {
        const popup = document.querySelector<HTMLElement>(selector);
        return !!popup && !popup.hasAttribute("data-starting-style") && popup.getBoundingClientRect().height > 0;
      },
      POPUP,
      { timeout: 10_000 },
    );

  /** Two painted frames: a scroll the wheel or a key started has landed. */
  const frames = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );

  /** Every scroller on the page but the card, with where it sits. */
  const scrollers = (page: Page) =>
    page.evaluate((selector) => {
      const card = document.querySelector(selector);
      return [...document.querySelectorAll<HTMLElement>("*")]
        .filter((node) => node !== card && !card?.contains(node) && node.scrollHeight > node.clientHeight + 1)
        .filter((node) => /auto|scroll/.test(getComputedStyle(node).overflowY) || node === document.scrollingElement)
        .map((node) => ({ name: `${node.tagName}.${node.className}`, top: node.scrollTop }));
    }, POPUP);

  for (const colorScheme of ["dark", "light"] as const)
    test(`a received group's hover card is the hover card glass and scrolls on its own (${colorScheme})`, async () => {
      const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, colorScheme });
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(
          base +
            galleryFrame(ENTRY, { variant: VARIANT, colorScheme, width: WIDTH, height: HEIGHT, background: "dark" }),
        );
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
        // The play hovered the row; put the real pointer on its words too (the card, open, may lie
        // beside them: no actionability wait).
        await page.locator(`${HEAD} .cv-tool__text`).first().hover({ force: true });
        await open(page);
        // The card sits beside the row's words, never over them.
        const placed = await page.evaluate(
          ({ popup, head }) => {
            const card = document.querySelector<HTMLElement>(popup)!;
            const words = document.querySelector<HTMLElement>(`${head} .cv-tool__text`)!.getBoundingClientRect();
            const rect = card.getBoundingClientRect();
            return {
              card: rect.toJSON(),
              words: words.toJSON(),
              available: getComputedStyle(card).getPropertyValue("--available-height"),
              maxHeight: getComputedStyle(card).maxHeight,
              side: card.parentElement?.getAttribute("data-side"),
              overlap:
                rect.top < words.bottom - 1 &&
                rect.bottom > words.top + 1 &&
                rect.left < words.right - 1 &&
                rect.right > words.left + 1,
            };
          },
          { popup: POPUP, head: HEAD },
        );
        expect(placed.overlap, JSON.stringify(placed)).toBe(false);
        // Above or below its row, as every hover card opens, never flipped beside it.
        expect(["top", "bottom"], JSON.stringify(placed)).toContain(placed.side ?? "");
        // The in-place blur attaches once the card is placed.
        await page
          .waitForFunction((selector) => document.querySelector(selector)?.hasAttribute("data-glass-over"), POPUP, {
            timeout: 5_000,
          })
          .catch(() => {});

        // 1. Translucent, in the shared material.
        const glass = await page.evaluate((selector) => {
          const popup = document.querySelector<HTMLElement>(selector)!;
          const style = getComputedStyle(popup);
          const alphaOf = (color: string) => {
            const rgba = /rgba?\(([^)]+)\)/.exec(color);
            if (rgba) {
              const parts = rgba[1]!.split(/[\s,/]+/).filter(Boolean);
              return parts.length >= 4 ? Number.parseFloat(parts[3]!) : 1;
            }
            const modern = /color\([^)]*\/\s*([\d.]+)\)/.exec(color);
            if (modern) return Number.parseFloat(modern[1]!);
            if (/color\(/.test(color)) return 1;
            return color === "transparent" ? 0 : 1;
          };
          // The tint is the gradient's color (see-through Chromium) or the background color itself.
          const gradient = /gradient\((.*)\)/.exec(style.backgroundImage)?.[1] ?? "";
          const tintColor = /(rgba?\([^)]*\)|color\([^)]*\))/.exec(gradient)?.[1];
          const layers = [alphaOf(style.backgroundColor), ...(tintColor ? [alphaOf(tintColor)] : [])];
          const alpha = 1 - layers.reduce((clear, layer) => clear * (1 - layer), 1);
          // A link's hover card (AnchoredCard) draws the same tint: the one hover card material.
          const probe = document.createElement("div");
          probe.className = "ui-tooltip ui-card ui-glass";
          popup.parentElement!.append(probe);
          const shared = getComputedStyle(probe).getPropertyValue("--glass-tint").trim();
          probe.remove();
          return {
            seeThrough: document.documentElement.hasAttribute("data-cmux-see-through"),
            alpha,
            backgroundColor: style.backgroundColor,
            backgroundImage: style.backgroundImage,
            backdrop: style.backdropFilter,
            over: popup.hasAttribute("data-glass-over"),
            keepsUnderlay: popup.hasAttribute("data-glass-keeps-underlay"),
            rect: popup.getBoundingClientRect().toJSON(),
            hostGlass: popup.getAttribute("data-host-glass"),
            tint: style.getPropertyValue("--glass-tint").trim(),
            shared,
            blurred: [...document.querySelectorAll<HTMLElement>('[data-glass-under~="hover-card"]')].filter((node) =>
              getComputedStyle(node).filter.includes("url("),
            ).length,
          };
        }, POPUP);
        const info = JSON.stringify(glass);
        expect(glass.seeThrough, info).toBe(true);
        // The tint alone (78%), never the tint over the theme surface's underlay (93%).
        expect(glass.alpha, info).toBeLessThan(0.9);
        expect(glass.over, info).toBe(true);
        expect(glass.hostGlass, info).toBe("popover");
        expect(glass.tint, info).toBe(glass.shared);
        expect(glass.blurred, info).toBeGreaterThan(0);

        // 2. Taller than the window allows: its height stops inside the window and it scrolls.
        const size = await page.evaluate((selector) => {
          const popup = document.querySelector<HTMLElement>(selector)!;
          const rect = popup.getBoundingClientRect();
          return {
            scrollHeight: popup.scrollHeight,
            clientHeight: popup.clientHeight,
            top: rect.top,
            bottom: rect.bottom,
            threads: popup.querySelectorAll(".cv-group-hover__thread").length,
          };
        }, POPUP);
        expect(size.threads, JSON.stringify(size)).toBe(2);
        expect(size.scrollHeight, JSON.stringify(size)).toBeGreaterThan(size.clientHeight);
        expect(size.top, JSON.stringify(size)).toBeGreaterThanOrEqual(0);
        expect(size.bottom, JSON.stringify(size)).toBeLessThanOrEqual(HEIGHT);

        // 3. The wheel over the card scrolls the card, to its end, and nothing under it.
        const before = await scrollers(page);
        const box = (await page.locator(POPUP).boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 4 });
        await page.mouse.wheel(0, 240);
        await page.waitForFunction((selector) => document.querySelector(selector)!.scrollTop > 0, POPUP, {
          timeout: 5_000,
        });
        await page.mouse.wheel(0, 20_000);
        await page.waitForFunction(
          (selector) => {
            const popup = document.querySelector<HTMLElement>(selector);
            return !popup || popup.scrollTop >= popup.scrollHeight - popup.clientHeight - 2;
          },
          POPUP,
          { timeout: 5_000 },
        );
        await frames(page);
        const scrolled = await page.evaluate((selector) => {
          const popup = document.querySelector<HTMLElement>(selector);
          return popup
            ? {
                top: popup.scrollTop,
                end: popup.scrollHeight - popup.clientHeight,
                second: (() => {
                  const second = popup.querySelectorAll(".cv-group-hover__thread")[1]?.getBoundingClientRect();
                  const card = popup.getBoundingClientRect();
                  return !!second && second.bottom > card.top + 1 && second.top < card.bottom - 1;
                })(),
              }
            : null;
        }, POPUP);
        expect(scrolled, "the card stays open under the pointer").not.toBeNull();
        expect(scrolled!.top).toBeGreaterThan(0);
        expect(Math.abs(scrolled!.end - scrolled!.top)).toBeLessThanOrEqual(2);
        expect(scrolled!.second).toBe(true);
        expect(await scrollers(page)).toEqual(before);

        // 4. From the keyboard: its row focused, Page Up scrolls the card back, not the transcript.
        await page.locator(HEAD).first().focus();
        await page.keyboard.press("PageUp");
        await page
          .waitForFunction(
            ({ selector, top }) => (document.querySelector<HTMLElement>(selector)?.scrollTop ?? top) < top,
            { selector: POPUP, top: scrolled!.top },
            { timeout: 5_000 },
          )
          .catch(() => {});
        await frames(page);
        const keyed = await page.evaluate(
          (selector) => document.querySelector<HTMLElement>(selector)?.scrollTop,
          POPUP,
        );
        expect(keyed).toBeLessThan(scrolled!.top);
        expect(await scrollers(page)).toEqual(before);
      } finally {
        await page.close();
      }
    });
});
