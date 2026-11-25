// A finished subagent keeps its name in the row's available room, without a chevron. Failed
// lines retain their reason-first truncation and trailing navigation mark. Gallery measurements
// cover wide and narrow panes, truncation, the single-line height and horizontal overflow.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-done-chip-width.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.subagent-done";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("subagent done chip width", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "long-title" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Line = {
    grid: boolean;
    row: { left: number; right: number; height: number; overflow: number };
    chip: { width: number; right: number; cut: boolean; ellipsis: string; words: number };
    suffix: { cut: boolean; right: number } | null;
    sentence: number;
    chevron: number | null;
    chevronRight: number | null;
    time: number;
  };

  const lines = async (variant: string, width: number): Promise<Line[]> => {
    const page = await browser.newPage({ viewport: { width: width + 40, height: 600 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, reducedMotion: "true" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      return await page.evaluate(() =>
        [...document.querySelectorAll(".cv-subagent-done-row")].map((row) => {
          const box = row.getBoundingClientRect();
          const grid = row.getAttribute("data-look") === "grid";
          const chip = row.querySelector(grid ? ".cv-subagent-failed__title" : ".cv-agent-tag")!;
          const chipBox = chip.getBoundingClientRect();
          const glyph = row.querySelector(".cv-subagent-done__chevron svg path")?.getBoundingClientRect();
          const time = row.querySelector(".cv-subagent-done__time")!.getBoundingClientRect();
          return {
            grid,
            row: { left: box.left, right: box.right, height: box.height, overflow: row.scrollWidth - row.clientWidth },
            chip: {
              width: chipBox.width,
              right: chipBox.right,
              cut: chip.scrollWidth > chip.clientWidth + 1,
              ellipsis: getComputedStyle(chip).textOverflow,
              words: chip.scrollWidth,
            },
            suffix: (() => {
              const suffix = row.querySelector(grid ? ".cv-subagent-failed__reason" : ".cv-subagent-done__suffix");
              return suffix
                ? { cut: suffix.scrollWidth > suffix.clientWidth + 1, right: suffix.getBoundingClientRect().right }
                : null;
            })(),
            sentence: row
              .querySelector(grid ? ".cv-subagent-failed__text" : ".cv-agent-activity__sentence")!
              .getBoundingClientRect().width,
            chevron: glyph?.left ?? null,
            chevronRight: glyph?.right ?? null,
            time: time.left,
          };
        }),
      );
    } finally {
      await page.close();
    }
  };

  test("a long name in a wide pane: the chip is wider than the old 40% cap, cut with an ellipsis", async () => {
    const [line] = await lines("long-title", 900);
    expect(line).toBeDefined();
    expect(line!.chip.width).toBeGreaterThan(line!.sentence * 0.4 + 1);
    // The name reaches the duration with no decorative chevron or reserved chevron slot.
    expect(line!.chevron).toBeNull();
    expect(line!.time - line!.chip.right).toBeLessThan(80);
    expect(line!.chip.cut).toBe(true);
    expect(line!.chip.ellipsis).toBe("ellipsis");
  });

  test("a failure with a long error: on the grid, the reason is cut and the title keeps its whole name", async () => {
    // At 900px the name fits beside the line's other parts and only the error overflows; at 420px
    // the name alone does not fit, so both are cut.
    const [line] = await lines("failed-long-error", 900);
    expect(line?.grid).toBe(true);
    expect(line?.suffix?.cut).toBe(true);
    expect(line!.chip.cut).toBe(false);
  });

  for (const [variant, width] of [
    ["long-title", 900],
    ["short-title", 900],
    ["narrow", 420],
    ["long-title", 420],
    ["failed-long-error", 420],
    ["failed-long-error", 900],
  ] as const)
    test(`${variant} at ${width}px: one 22px line, no overflow, completed status has no chevron`, async () => {
      const all = await lines(variant, width);
      expect(all.length).toBeGreaterThan(0);
      for (const line of all) {
        expect(line.row.overflow).toBeLessThanOrEqual(0);
        expect(Math.round(line.row.height)).toBe(22);
        if (line.grid) {
          // A failed line's grid: the words, then Retry and the time in fixed columns, the chevron last.
          expect(line.time).toBeGreaterThan(line.suffix?.right ?? line.chip.right);
          expect(line.chevron!).toBeGreaterThan(line.time);
          continue;
        }
        expect(line.chevron).toBeNull();
        expect(line.chevronRight).toBeNull();
        expect(line.time).toBeGreaterThan(line.suffix?.right ?? line.chip.right);
        expect(line.row.overflow).toBeLessThanOrEqual(0);
        expect(Math.round(line.row.height)).toBe(22);
      }
    });
});
