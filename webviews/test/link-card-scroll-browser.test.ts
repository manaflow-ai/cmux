// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
// A link's hover card during a wheel or touchpad scroll (Leo, 2026-11-10: "just tried this touchpad
// scrolling the github preview is kinda bad"). While he scrolled with the pointer still, the pull
// request card kept opening for whichever chip slid under the pointer. Now a scroll puts an open card
// away at once (as a macOS hover card goes on scroll), a chip sliding under a still pointer opens
// nothing, and a real pointer move after the scroll opens a chip's card as before.
//
// Real Chromium and WebKit (the app's engine) from Playwright, on the gallery's
// agent-pane.transcript github-references-scroll variant.
// Locally: CMUX_BROWSER_TESTS=1 bun test ./test/link-card-scroll-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("link-card-scroll-browser.test.ts", async () => {
  const ENTRY = "agent-pane.transcript";
  const VARIANT = "github-references-scroll";
  const CARD = ".cv-link-preview.acpmux-pr-card";
  const CHIP = "a.cv-chip.is-ref";
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`link-card-scroll: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("link card scroll", () => test("browsers", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: browsers.values().next().value!, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** The open pull request cards, each by the number its card names. */
  const openCards = (page: Page) =>
    page.evaluate((card) => {
      return [...document.querySelectorAll<HTMLElement>(card)]
        .filter((element) => {
          const box = element.getBoundingClientRect();
          const popup = element.closest<HTMLElement>(".ui-tooltip") ?? element;
          return (
            box.width > 0 &&
            box.height > 0 &&
            !popup.hasAttribute("data-closed") &&
            !popup.hasAttribute("data-ending-style") &&
            getComputedStyle(popup).visibility !== "hidden"
          );
        })
        .map((element) => element.textContent?.match(/#(\d+)/)?.[1] ?? "?");
    }, CARD);

  /** The center of the chip nearest the scroller's middle, and the chip's href. */
  const middleChip = (page: Page) =>
    page.evaluate((chip) => {
      const chips = [...document.querySelectorAll<HTMLAnchorElement>(chip)];
      const middle = innerHeight / 2;
      const best = chips
        .map((element) => ({ element, box: element.getBoundingClientRect() }))
        .filter(({ box }) => box.width > 0 && box.top > 80 && box.bottom < innerHeight - 160)
        .sort((a, b) => Math.abs(a.box.top - middle) - Math.abs(b.box.top - middle))[0];
      if (!best) return undefined;
      return {
        x: best.box.left + best.box.width / 2,
        y: best.box.top + best.box.height / 2,
        href: best.element.href,
      };
    }, CHIP);

  /** Waits `count` painted frames: a scroll's hover update and React's commit land by then. */
  const frames = async (page: Page, count: number) => {
    for (let frame = 0; frame < count; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };

  /** The chip under `point`, if any. */
  const chipAt = (page: Page, point: { x: number; y: number }) =>
    page.evaluate(([x, y, chip]) => document.elementFromPoint(x, y)?.closest<HTMLAnchorElement>(chip)?.href ?? null, [
      point.x,
      point.y,
      CHIP,
    ] as const);

  for (const [name] of engines)
    test(`${name}: a scroll puts a link card away and a chip sliding under a still pointer opens nothing`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 760, height: 720 } });
      await installPaintedFrames(page);
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame(ENTRY, { variant: VARIANT, colorScheme: "dark", width: 760, height: 720 }));
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
        await page.waitForSelector(CHIP);
        // Start from the top of the reply, so there is room to scroll down past many chips.
        await page.evaluate((chip) => {
          const first = document.querySelector<HTMLElement>(chip)!;
          let scroller: HTMLElement | null = first.parentElement;
          while (
            scroller &&
            !(
              scroller.scrollHeight > scroller.clientHeight + 4 &&
              /auto|scroll/.test(getComputedStyle(scroller).overflowY)
            )
          )
            scroller = scroller.parentElement;
          if (!scroller) throw new Error("no transcript scroller");
          scroller.scrollTop = 0;
        }, CHIP);
        await frames(page, 3);

        // 1. A real hover on a chip opens its card.
        const first = await middleChip(page);
        expect(first).toBeDefined();
        await page.mouse.move(first!.x - 40, first!.y + 30);
        await page.mouse.move(first!.x, first!.y, { steps: 6 });
        await page.waitForFunction((card) => document.querySelector(card) !== null, CARD, { timeout: 5_000 });
        expect((await openCards(page)).length).toBe(1);

        // 2. Wheel events with no pointer move: the card goes at once.
        await page.mouse.wheel(0, 24);
        await frames(page, 4);
        const afterFirstWheel = await openCards(page);

        // 3. Keep scrolling (momentum-like small steps) with the pointer still; links pass under it.
        const passed = new Set<string>();
        const opened = new Set<string>();
        for (let step = 0; step < 30; step++) {
          await page.mouse.wheel(0, 18);
          await frames(page, 2);
          const under = await chipAt(page, first!);
          if (under) passed.add(under);
          for (const number of await openCards(page)) opened.add(number);
        }
        // End the scroll with a chip under the still pointer and let it rest past the card dwell.
        for (let step = 0; step < 40 && !(await chipAt(page, first!)); step++) {
          await page.mouse.wheel(0, 6);
          await frames(page, 2);
        }
        const restingOn = await chipAt(page, first!);
        // fixed-wait: the behavior is that no card opens past the 1 s card dwell; there is no event to wait for.
        await page.waitForTimeout(1_600);
        for (const number of await openCards(page)) opened.add(number);

        expect(afterFirstWheel).toEqual([]);
        expect(passed.size).toBeGreaterThan(0);
        expect(restingOn).not.toBeNull();
        expect([...opened]).toEqual([]);

        // 4. The pointer moves within the chip the scroll left under it, never leaving it: that real
        // move is hover intent, and the chip's own card opens (review of #40035, F1).
        const within = await page.evaluate(
          ([x, y, chip]) => {
            const element = document.elementFromPoint(x, y)?.closest<HTMLAnchorElement>(chip);
            if (!element) return undefined;
            (window as unknown as { leftChip: boolean }).leftChip = false;
            element.addEventListener("pointerleave", () => {
              (window as unknown as { leftChip: boolean }).leftChip = true;
            });
            const box = element.getBoundingClientRect();
            const center = { x: box.left + box.width / 2, y: box.top + box.height / 2 };
            // From a point inside a box to its center the path stays inside it.
            const to = Math.abs(center.x - x) >= 2 ? center : { x: Math.min(x + 3, box.right - 1), y: center.y };
            return { ...to, number: element.href.match(/(\d+)$/)?.[1] };
          },
          [first!.x, first!.y, CHIP] as const,
        );
        expect(within).toBeDefined();
        await page.mouse.move(within!.x, within!.y, { steps: 4 });
        await page
          .waitForFunction((card) => document.querySelector(card) !== null, CARD, { timeout: 5_000 })
          .catch(() => {});
        expect(await page.evaluate(() => (window as unknown as { leftChip: boolean }).leftChip)).toBe(false);
        expect(await openCards(page)).toEqual([within!.number!]);

        // 5. After the scroll, a real pointer move over another chip opens its card as before.
        const next = await middleChip(page);
        expect(next).toBeDefined();
        await page.mouse.move(next!.x - 30, next!.y + 24, { steps: 4 });
        await page.mouse.move(next!.x, next!.y, { steps: 6 });
        await page.waitForFunction((card) => document.querySelector(card) !== null, CARD, { timeout: 5_000 });
        expect((await openCards(page)).length).toBe(1);
      } finally {
        await page.close();
      }
    });
});
