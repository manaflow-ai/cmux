// l10n-allow-file: gallery fixture names are test data.
// Every row stacked on the composer stands on the composer's own columns (cmux#56151; the person, on
// the plan bar "4 of 6 · Verify in tagged dev build · 1 subagent done": "the claude icon is not aligned
// come on here.. vertically we should align this stuff"). The hat's leading column took the composer's
// inset plus a 6 px `glyph` offset while its marks already centred themselves in +'s box, so the
// Claude mark sat right of the + and the words right of the placeholder; a harness mark centred by the
// scaled glyph's room drifted again at every density but Default; the `groups` header's first words
// started short of the prompt's; and a queued row's menu sat 5 px right of the mic.
//
// Real Chromium (Playwright) on the gallery's folded hats, at every page density:
//   - the header's first mark centres on the + button, its first words start at the placeholder's;
//   - the panel button centres on Stop's column, the chevron on the mic;
//   - a queued row's last action centres on the mic.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { pageDensities } from "../src/gallery/pageDensityFixtures";

await requireBrowserLane("composer-stack-columns.test.ts", async () => {
  setDefaultTimeout(300_000);
  /** Half a pixel: a centred box's subpixel rounding. */
  const SLACK = 0.5;
  const HATS = [
    { entry: "agent-pane.composer-hat-groups", variant: "one-done" },
    { entry: "agent-pane.composer-hat-groups", variant: "mixed" },
    { entry: "agent-pane.composer-hat-groups", variant: "lone-subagent" },
    { entry: "agent-pane.composer-hat-groups", variant: "lone-command" },
  ] as const;
  const QUEUE = { entry: "agent-pane.composer", variant: "queued-long-open" } as const;
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    for (const entry of new Set([...HATS.map((hat) => hat.entry), QUEUE.entry]))
      await warmGalleryFrame(server, entry, {
        browser,
        params: { variant: [...HATS, QUEUE].find((frame) => frame.entry === entry)!.variant },
      });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (frame: { entry: string; variant: string }, scale: number, ready: string): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({
      viewport: { width: 900, height: 720 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    await installPaintedFrames(page);
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(frame.entry, { variant: frame.variant, width: "normal" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(ready);
    await page.evaluate((value) => {
      const root = document.documentElement;
      for (const name of ["--cmux-density-scale", "--cmux-density-text-scale", "--cmux-row-icon-scale"])
        root.style.setProperty(name, String(value));
      root.style.setProperty("--cmux-sidebar-row-height", `${30 * value}px`);
      window.dispatchEvent(new Event("cmux-ui-scale-change"));
    }, scale);
    await page.evaluate(() => document.fonts.ready);
    // Measure once the composer and the row over it have held still for 20 painted frames.
    await page.evaluate(async (selector) => {
      const at = () =>
        [document.querySelector(".acpmux-composer-box button"), document.querySelector(selector)]
          .map((node) => {
            const rect = node?.getBoundingClientRect();
            return rect ? `${rect.left},${rect.width}` : "";
          })
          .join("|");
      let last = "";
      let still = 0;
      for (let index = 0; index < 240 && still < 20; index += 1) {
        await window.cmuxPaintFrame();
        const now = at();
        still = now === last ? still + 1 : 0;
        last = now;
      }
    }, ready);
    return page;
  };

  /** The composer's columns: +, the placeholder's start, Stop's column and the mic, in CSS px. */
  const composerColumns = (page: Page) =>
    page.evaluate(() => {
      const box = document.querySelector(".acpmux-composer-box")!;
      const middle = box.getBoundingClientRect().left + box.getBoundingClientRect().width / 2;
      const centre = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return rect.left + rect.width / 2;
      };
      const buttons = [...box.querySelectorAll("button")].filter((button) => button.getClientRects().length > 0);
      const plus = box.querySelector(".acpmux-composer-plus button") ?? buttons[0]!;
      const right = buttons.filter((button) => button.getBoundingClientRect().left > middle);
      const mic = right.at(-1)!;
      const gap = Number.parseFloat(getComputedStyle(box).getPropertyValue("--acpmux-composer-action-gap")) || 4;
      const stop = right.length > 1 ? centre(right.at(-2)!) : centre(mic) - mic.getBoundingClientRect().width - gap;
      const placeholder = box.querySelector(".acpmux-md-placeholder");
      return {
        plus: centre(plus),
        prompt: placeholder ? placeholder.getBoundingClientRect().left : null,
        stop,
        mic: centre(mic),
      };
    });

  for (const density of pageDensities) {
    for (const hat of HATS) {
      test(`${density.name}: ${hat.entry} ${hat.variant}: the folded hat stands on the composer's columns`, async () => {
        const page = await open(hat, density.scale, ".acpmux-running-tray__head");
        try {
          const columns = await composerColumns(page);
          const head = await page.evaluate(() => {
            const head = document.querySelector(".acpmux-running-tray__head")!;
            const centre = (node: Element | null) => {
              const rect = node?.getBoundingClientRect();
              return rect ? rect.left + rect.width / 2 : null;
            };
            // The first mark: a harness mark (the stack's, a subagent kind's), else a kind's glyph.
            const marks = [
              ...head.querySelectorAll(
                ".acpmux-running-tray__stack-mark, .acpmux-running-tray__kind > svg, :scope > .acpmux-lineage__icon > svg",
              ),
            ].filter(
              (node) => !node.closest(".acpmux-running-tray__summary-probe") && node.getClientRects().length > 0,
            );
            marks.sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left);
            // The first words' first character.
            const walker = document.createTreeWalker(head, NodeFilter.SHOW_TEXT, {
              acceptNode: (text) =>
                (text.textContent ?? "").trim() &&
                !text.parentElement?.closest(".acpmux-running-tray__summary-probe, .acpmux-running-tray__time")
                  ? NodeFilter.FILTER_ACCEPT
                  : NodeFilter.FILTER_SKIP,
            });
            const text = walker.nextNode();
            let words: number | null = null;
            if (text) {
              const range = document.createRange();
              range.setStart(text, 0);
              range.setEnd(text, 1);
              words = range.getBoundingClientRect().left;
            }
            return {
              mark: centre(marks[0] ?? null),
              words,
              panel: centre(document.querySelector(".acpmux-running-tray__open")),
              chevron: centre(head.querySelector(".acpmux-running-tray__chevron")),
            };
          });
          const off: string[] = [];
          const near = (what: string, a: number | null, b: number | null) => {
            if (a == null || b == null || Math.abs(a - b) > SLACK) off.push(`${what}: ${a} vs ${b}`);
          };
          near("first mark on +", head.mark, columns.plus);
          near("first words at the prompt's", head.words, columns.prompt);
          near("panel button over Stop's column", head.panel, columns.stop);
          near("chevron over the mic", head.chevron, columns.mic);
          expect(off).toEqual([]);
        } finally {
          await page.close();
        }
      });
    }

    test(`${density.name}: a queued row's last action centres on the mic`, async () => {
      const page = await open(QUEUE, density.scale, ".acpmux-composer-queue .acpmux-queued-actions");
      try {
        const columns = await composerColumns(page);
        const actions = await page.evaluate(() =>
          [...document.querySelectorAll(".acpmux-composer-queue .acpmux-queued")].map((row) => {
            const last = [...row.querySelectorAll(".acpmux-queued-action")].at(-1);
            const rect = last?.getBoundingClientRect();
            return rect ? rect.left + rect.width / 2 : null;
          }),
        );
        expect(actions.length).toBeGreaterThan(0);
        for (const at of actions) {
          expect(at).not.toBeNull();
          expect(Math.abs(at! - columns.mic)).toBeLessThanOrEqual(SLACK);
        }
      } finally {
        await page.close();
      }
    });
  }
});
