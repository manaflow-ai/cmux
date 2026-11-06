// Tool-call rows read one way across the transcript (Leo, 2026-11-03: "i think we ought to audit the
// whole tool call/notice/send and recieve message styling"; design/chat-transcript.md "One row
// grammar" and "Grouped steps"). Measured in Chromium over gallery scenes, light and dark:
// - a failed call whose label runs past the line keeps its failure word whole after the cut label
//   (agent-pane.tool-errors#long-label; cmux#24339 put the word inside the ellipsis);
// - a failed Read step and a failed command step both read "Failed", capitalised alike
//   (agent-pane.tool-errors#failed-step-mixed; cmux#33759 capitalised only the command's);
// - an opened lead thought reads "Thought for 6s" with its chevron right after the words
//   (agent-pane.claude-desktop-organization#shared; cmux#27896 parked it at the row's far edge);
// - an inner step under the pointer shows its chevron and keeps its words' tone
//   (agent-pane.claude-desktop-organization#step-hover);
// - a sub-session line still working draws no spinner, shimmers its title, and its harness mark is
//   the received rows' 12px (agent-pane.long-report#lead-finished-working; cmux#32927).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-tool-row-consistency.test.ts", async () => {
  setDefaultTimeout(240_000);
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript tool row consistency", () => test("browser", () => {}));
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
    for (const [entry, variant] of [
      ["agent-pane.tool-errors", "long-label"],
      ["agent-pane.claude-desktop-organization", "shared"],
      ["agent-pane.long-report", "lead-finished-working"],
    ] as const)
      await warmGalleryFrame(vite, entry, { browser, params: { variant }, timeoutMs: 200_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, theme: string, width = 420): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: width + 40, height: 1100 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, theme, reducedMotion: "true" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  for (const theme of THEMES) {
    test(`a cut label keeps its failure word whole after it (${theme.file})`, async () => {
      const page = await open("agent-pane.tool-errors", "long-label", theme.name);
      try {
        const rows = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>(".cv-tool > .cv-tool__failed")].map((word) => {
            const row = word.parentElement!;
            const text = row.querySelector<HTMLElement>(".cv-tool__text")!;
            const box = word.getBoundingClientRect();
            return {
              word: word.textContent!.trim(),
              cut: text.scrollWidth > text.clientWidth,
              whole: word.scrollWidth <= Math.ceil(box.width) && box.width > 0,
              inside: box.right <= row.getBoundingClientRect().right + 0.5,
              after: box.left >= text.getBoundingClientRect().right - 0.5,
              color: getComputedStyle(word).color,
              rowColor: getComputedStyle(row).color,
            };
          }),
        );
        expect(rows.length).toBeGreaterThanOrEqual(3);
        for (const row of rows) {
          expect(row.cut).toBe(true);
          expect(row.whole).toBe(true);
          expect(row.inside).toBe(true);
          expect(row.after).toBe(true);
          expect(row.color).not.toBe(row.rowColor);
        }
      } finally {
        await page.close();
      }
    });

    test(`a failed Read step and a failed command step both read "Failed" (${theme.file})`, async () => {
      const page = await open("agent-pane.tool-errors", "failed-step-mixed", theme.name, 760);
      try {
        const tags = await page.evaluate(() =>
          [
            ...document.querySelectorAll<HTMLElement>(
              ".cv-steps .cv-tool > .cv-tool__failed, .cv-steps .cv-command > .cv-command__failed",
            ),
          ].map((tag) => ({
            text: tag.textContent!.trim(),
            transform: getComputedStyle(tag, "::first-letter").textTransform,
            whiteSpace: getComputedStyle(tag).whiteSpace,
          })),
        );
        expect(tags.length).toBe(2);
        for (const tag of tags) {
          expect(tag.text.toLowerCase()).toBe("failed");
          expect(tag.transform).toBe("uppercase");
          expect(tag.whiteSpace).toBe("nowrap");
        }
      } finally {
        await page.close();
      }
    });

    test(`an opened lead thought reads its label with the chevron right after it (${theme.file})`, async () => {
      const page = await open("agent-pane.claude-desktop-organization", "shared", theme.name, 760);
      try {
        const lead = await page.evaluate(() => {
          const button = document.querySelector<HTMLElement>(".cv-step.is-lead .cv-step-thought")!;
          const label = button.querySelector<HTMLElement>(".cv-tool__text")!;
          const range = document.createRange();
          range.selectNodeContents(label);
          const words = range.getBoundingClientRect();
          const glyph = button.querySelector(".cv-tool__chevron path")!.getBoundingClientRect();
          const body = document.querySelector<HTMLElement>(".cv-step.is-lead .cv-step-thought__body")!;
          return {
            expanded: button.getAttribute("aria-expanded"),
            text: label.textContent!.trim(),
            gap: glyph.left - words.right,
            float: getComputedStyle(button).float,
            above: glyph.bottom <= body.getBoundingClientRect().top + 0.5,
            edge: button.closest(".acpmux-row")!.getBoundingClientRect().right - glyph.right,
          };
        });
        expect(lead.expanded).toBe("true");
        expect(lead.text).toMatch(/^Thought/);
        expect(lead.gap).toBeGreaterThanOrEqual(0);
        expect(lead.gap).toBeLessThanOrEqual(8);
        expect(lead.float).toBe("none");
        expect(lead.above).toBe(true);
        expect(lead.edge).toBeGreaterThan(40);
      } finally {
        await page.close();
      }
    });

    test(`a working sub-session line has no spinner, a 12px mark and a shimmer (${theme.file})`, async () => {
      const page = await open("agent-pane.long-report", "lead-finished-working", theme.name);
      try {
        const line = await page.evaluate(() => {
          const row = document.querySelector<HTMLElement>(".cv-task-line")!;
          const mark = row.querySelector<HTMLElement>(".cv-tool__icon svg, .cv-tool__icon img")!;
          return {
            state: row.getAttribute("data-task-line"),
            live: row.classList.contains("is-live"),
            spinners: row.querySelectorAll(".cv-spinner").length,
            shimmer: row.querySelectorAll(".cv-row-shimmer").length,
            mark: mark.getBoundingClientRect().width,
          };
        });
        expect(line.state).toBe("working");
        expect(line.live).toBe(true);
        expect(line.spinners).toBe(0);
        expect(line.shimmer).toBe(1);
        expect(line.mark).toBe(12);
      } finally {
        await page.close();
      }
    });
  }
});
