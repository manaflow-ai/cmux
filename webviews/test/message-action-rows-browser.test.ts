// cmux-web-test-timeout: 300
// l10n-allow-file: browser measurements and fixture labels, not shipped UI.
// Every message action row draws one icon button: a prompt's row and a reply footer's take the same
// 24 square around a 16 glyph, and Retry's model chevron the same 12 glyph 4 after Retry's, under one
// hover box with 4 of room at each end (conversation.css --cv-action-*). Leo, 2026-11-08: "the symbols
// for yours and the symbols for mine, the sizes are different. Like mine are a bit bigger than yours"
// and, of the chevron, "on the left side, it's too tucked in, and on the right side, it's too far
// away". A prompt's age changes its words in place when the minute turns, with no remount, no fade
// and no change of box ("Sometimes that one, like, flashes or flickers a bit"). And the time under a
// stretch of a turn the person steered into hovers as every reply's time does ("I wasn't able to
// hover over your timestamp ... Was it because ... I steered it?").
// Real Chromium on the gallery (agent-pane.message-action-rows, agent-pane.superseded-turn-footer).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("message-action-rows-browser.test.ts", async () => {
  const ROWS = "agent-pane.message-action-rows";
  const STEERED = "agent-pane.superseded-turn-footer";
  if (!(await probeEngineOrSkip("message action rows", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, ROWS, { params: { variant: "pointed" } });
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (
    entry: string,
    variant: string,
    { width = 520, height = 260, clock = false }: { width?: number; height?: number; clock?: boolean } = {},
  ): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
    await page.emulateMedia({ reducedMotion: "no-preference" });
    if (clock) await page.clock.install();
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme: "dark", width, height })}`);
    if (clock) await page.clock.runFor(1_000);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    return page;
  };

  describe("one button in every action row", () => {
    test("a prompt's row and a reply footer's draw the same boxes, glyphs and chevron", async () => {
      const page = await open(ROWS, "pointed");
      try {
        const rows = await page.evaluate(() =>
          [".cv-user__actions", ".cv-turn-actions"].map((selector) => {
            const row = document.querySelector(selector)!;
            const box = (el: Element | null | undefined) => {
              const r = el!.getBoundingClientRect();
              return { left: r.left, right: r.right, width: r.width, height: r.height };
            };
            const buttons = [...row.querySelectorAll(".cv-iconbtn:not(.cv-turn-retry-menu)")].map((button) => ({
              button: box(button),
              glyph: box(button.querySelector("svg")),
            }));
            const retry = row.querySelector(":is(.cv-turn-retry, .cv-message-retry)")!;
            const chevron = retry.querySelector(".cv-turn-retry-menu")!;
            return {
              selector,
              buttons,
              chevron: { button: box(chevron), glyph: box(chevron.querySelector("svg")) },
              retryGlyph: box(retry.querySelector(".cv-iconbtn:not(.cv-turn-retry-menu) svg")),
              pill: box(retry),
            };
          }),
        );
        for (const row of rows) {
          expect(row.buttons.length).toBeGreaterThanOrEqual(2);
          for (const { button, glyph } of row.buttons) {
            expect([row.selector, button.width, button.height]).toEqual([row.selector, 24, 24]);
            expect([row.selector, glyph.width, glyph.height]).toEqual([row.selector, 16, 16]);
            // The same room on each side of the glyph.
            expect(glyph.left - button.left).toBe(button.right - glyph.right);
          }
          expect([row.selector, row.chevron.glyph.width, row.chevron.button.width]).toEqual([row.selector, 12, 16]);
          // Retry's glyph, 4, the chevron's; its one hover box with 4 of room at each end.
          expect([row.selector, row.chevron.glyph.left - row.retryGlyph.right]).toEqual([row.selector, 4]);
          expect([row.selector, row.retryGlyph.left - row.pill.left]).toEqual([row.selector, 4]);
          expect([row.selector, row.pill.right - row.chevron.glyph.right]).toEqual([row.selector, 4]);
        }
      } finally {
        await page.close();
      }
    });

    test("Retry under the pointer lights one box over Retry and its chevron", async () => {
      const page = await open(ROWS, "pointed");
      try {
        await page.hover(".cv-user__actions .cv-message-retry > .cv-iconbtn:not(.cv-turn-retry-menu)");
        const lit = await page.evaluate(() => {
          const retry = document.querySelector(".cv-user__actions .cv-message-retry")!;
          return {
            pill: getComputedStyle(retry).backgroundColor,
            button: getComputedStyle(retry.querySelector(".cv-iconbtn")!).backgroundColor,
          };
        });
        expect(lit.pill).not.toBe("rgba(0, 0, 0, 0)");
        expect(lit.button).toBe("rgba(0, 0, 0, 0)");
      } finally {
        await page.close();
      }
    });
  });

  test("a prompt's age ticks in place: the same node, the same box, no fade", async () => {
    const page = await open(ROWS, "just-now", { clock: true });
    try {
      const read = () =>
        page.evaluate(() => {
          const time = document.querySelector<HTMLElement>(".cv-user__actions .cv-user__time")!;
          const box = time.getBoundingClientRect();
          const copy = document.querySelector(".cv-user__actions .cv-iconbtn")!.getBoundingClientRect();
          const tagged = (time as HTMLElement & { tickProbe?: true }).tickProbe === true;
          (time as HTMLElement & { tickProbe?: true }).tickProbe = true;
          const animated = document
            .getAnimations()
            .filter((animation) => {
              const target = (animation.effect as KeyframeEffect | null)?.target;
              return target instanceof Element && (target === time || target.contains(time) || time.contains(target));
            })
            .map((animation) => (animation as CSSTransition).transitionProperty ?? animation.constructor.name);
          return { text: time.textContent, left: box.left, width: box.width, copyLeft: copy.left, tagged, animated };
        });
      const first = await read();
      expect(first.text).toBe("just now");
      expect(first.tagged).toBe(false);
      const seen = [first];
      // Sent 30 s before the gallery's 09:41:00; the age reads the minute-floored clock (clock.ts).
      for (const [step, words] of [
        [61_000, "1 minute ago"],
        [60_000, "2 minutes ago"],
        [57 * 60_000, "59 minutes ago"],
      ] as const) {
        await page.clock.runFor(step);
        await page.waitForFunction(
          (expected) => document.querySelector(".cv-user__actions .cv-user__time")?.textContent === expected,
          words,
          { timeout: 5_000 },
        );
        seen.push(await read());
      }
      const texts = seen.map((each) => each.text);
      // The words changed with the minute...
      expect(new Set(texts).size).toBe(texts.length);
      for (const each of seen.slice(1)) {
        // ...in the same element (no remount), with no fade on it or around it...
        expect(each.tagged).toBe(true);
        expect(each.animated).toEqual([]);
        // ...and nothing moved: its box and Copy stay where they were.
        expect(each.left).toBe(first.left);
        expect(each.width).toBe(first.width);
        expect(each.copyLeft).toBe(first.copyLeft);
      }
    } finally {
      await page.close();
    }
  });

  for (const variant of ["steered-claude", "next-prompt-no-summary"])
    test(`${variant}: every reply time hovers with its detail, the steered stretch's too`, async () => {
      const page = await open(STEERED, variant, { width: 760, height: 560 });
      try {
        const times = await page.evaluate(() =>
          [...document.querySelectorAll(".cv-turn-time")].map((time) => {
            const box = time.getBoundingClientRect();
            const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            return {
              row: time.closest("[data-row-id]")?.getAttribute("data-row-id") ?? "",
              tip: time.getAttribute("title") ?? time.getAttribute("data-tooltip") ?? "",
              detail: time.getAttribute("data-tooltip-detail") ?? "",
              hit: hit === time || time.contains(hit),
            };
          }),
        );
        expect(times.some((time) => time.row.startsWith("superseded"))).toBe(true);
        for (const time of times) {
          expect([time.row, time.hit]).toEqual([time.row, true]);
          expect([time.row, time.tip]).toEqual([time.row, expect.stringMatching(/\S/)]);
        }
        // The stretch the person came in on says how long it worked, as a turn's own footer does.
        const steered = times.find((time) => time.row.startsWith("superseded"))!;
        // (Its tooltip's second line, under the exact time every reply's age hovers with.)
        expect(steered.detail).toMatch(/^Worked for /);
      } finally {
        await page.close();
      }
    });
});
