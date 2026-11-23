// The unread "New" mark over a row with no "Worked for" divider (look B, unread.css), such as a
// "Background task finished" line, lies midway between what the eye sees of the row above and of the
// row under it, and "New" sits on its centre line; no row moves. manaflow-ai/cmux#51747 (user,
// 2026-11-22, on a rule pinned under the action icons with "New" hanging below it: "we need to make
// sure space top and space down is the same"; 2026-11-23, on a line centred between the rows' boxes
// that still read high: "it always must be even the position").
//
// Measured in pixels, not boxes: a row's box ends in empty room that differs by kind (a footer's icons
// sit 8 px above its bottom, a line of words has its font's empty ascent over its capitals), so equal
// box gaps can still look uneven. Real Chromium from Playwright, at 2x, on two stages: the transcript
// itself (`agent-pane.lone-system-rows`, a task line 8 under a turn's footer) and the mark's own
// stage (`agent-pane.since-divider`, a task line under a reply's words).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-since-centered-in-gap.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const STAGE = "agent-pane.since-divider";
  const TRANSCRIPT = "agent-pane.lone-system-rows";
  const url = (entry: string, params: Record<string, string>) =>
    `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}${galleryFrame(entry, params)}`;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, STAGE, { browser, params: { variant: "line-task" } });
    await warmGalleryFrame(vite, TRANSCRIPT, { browser, params: { variant: "background-task-new" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const SCALE = 2;
  type Box = { top: number; bottom: number; left: number; right: number };

  /// The drawn line and "New", in device px: the space from the nearest ink above the line to the
  /// line, from the line to the nearest ink under it, and the centres of the line and of "New".
  async function ink(page: Page) {
    const { rule, tag } = await page.evaluate(() => {
      const box = (node: Element) => {
        const r = node.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
      };
      return {
        rule: box(document.querySelector(".cv-since[data-shown] .cv-since__rule")!),
        tag: box(document.querySelector(".cv-since[data-shown] .cv-since__tag")!),
      };
    });
    const shot = (clip: Box, reach: number) =>
      page
        .screenshot({
          clip: {
            x: clip.left,
            y: clip.top - reach,
            width: clip.right - clip.left,
            height: clip.bottom - clip.top + reach * 2,
          },
        })
        .then((png) => PNG.sync.read(png));
    // Rows of the picture, each as how many of its pixels differ from the page's background (the
    // picture's most common colour).
    const inkRows = (png: PNG) => {
      const counts = new Map<number, number>();
      for (let i = 0; i < png.data.length; i += 4) {
        const key = (png.data[i]! << 16) | (png.data[i + 1]! << 8) | png.data[i + 2]!;
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
      const bg = [...counts].sort((a, b) => b[1] - a[1])[0]![0];
      const rows: number[] = [];
      for (let y = 0; y < png.height; y++) {
        let n = 0;
        for (let x = 0; x < png.width; x++) {
          const i = (y * png.width + x) * 4;
          const d =
            Math.abs(png.data[i]! - ((bg >> 16) & 255)) +
            Math.abs(png.data[i + 1]! - ((bg >> 8) & 255)) +
            Math.abs(png.data[i + 2]! - (bg & 255));
          if (d > 60) n++;
        }
        rows.push(n);
      }
      return rows;
    };
    // The line: the rows most of the picture's width is drawn on; the content: every other drawn row.
    const lines = inkRows(await shot(rule, 40));
    const width = Math.round((rule.right - rule.left) * SCALE);
    const ruled = lines.flatMap((n, y) => (n > width * 0.5 ? [y] : []));
    const first = ruled[0]!;
    const last = ruled.at(-1)!;
    let above = first - 1;
    while (above >= 0 && lines[above] === 0) above--;
    const under = lines.slice(last + 1).findIndex((n) => n > 0);
    // "New": its glyphs' rows within its own box, against the line's centre in the same frame.
    const word = inkRows(await shot(tag, 0)).flatMap((n, y) => (n > 0 ? [y] : []));
    // The line's picture starts 40 px over the line's box; "New"'s at its own box's top.
    const lineCentre = (first + last) / 2 + (rule.top - 40 - tag.top) * SCALE;
    return {
      ruled,
      spaceAbove: above < 0 ? undefined : first - above - 1,
      spaceUnder: under < 0 ? undefined : under,
      tagCentre: (word[0]! + word.at(-1)!) / 2,
      lineCentre,
    };
  }

  function expectEven(shot: Awaited<ReturnType<typeof ink>>) {
    expect(shot.ruled.length).toBeGreaterThan(0);
    expect(shot.spaceAbove).toBeDefined();
    expect(shot.spaceUnder).toBeDefined();
    // Even to a device pixel: an odd space cannot split closer.
    expect(Math.abs(shot.spaceAbove! - shot.spaceUnder!), JSON.stringify(shot)).toBeLessThanOrEqual(1);
    // "New" on the line's centre line, not hanging under it.
    expect(Math.abs(shot.tagCentre - shot.lineCentre), JSON.stringify(shot)).toBeLessThanOrEqual(1);
  }

  const settle = async (page: Page) => {
    await page.waitForSelector(".cv-since[data-shown]");
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() =>
      (document.querySelector(".cv-since") as HTMLElement | null)?.style.getPropertyValue("--cv-since-ink"),
    );
    // The line fades in (unread.css); a capture waits for it to finish.
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".cv-since__line")!).opacity === "1");
    await page.mouse.move(0, 0);
  };

  test("in the transcript: a task line 8 under a turn's footer, the line midway between its icons and the line's words", async () => {
    const page = await browser.newPage({ viewport: { width: 1000, height: 700 }, deviceScaleFactor: SCALE });
    try {
      await page.goto(
        url(TRANSCRIPT, {
          variant: "background-task-new",
          width: "900",
          theme: "Catppuccin Mocha",
          reducedMotion: "true",
          exp: "background-turn-look",
          arm: "line",
        }),
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await settle(page);
      expectEven(await ink(page));
    } finally {
      await page.close();
    }
  });

  test("on the mark's stage: a task line under a reply's words, no row moved", async () => {
    const page = await browser.newPage({
      viewport: { width: 640, height: 400 },
      deviceScaleFactor: SCALE,
      reducedMotion: "reduce",
    });
    try {
      const rows = () =>
        page.evaluate(() =>
          [...document.querySelectorAll("[data-row-id]")].map((row) => {
            const r = row.getBoundingClientRect();
            return [row.getAttribute("data-row-id"), r.top, r.bottom];
          }),
        );
      await page.goto(url(STAGE, { variant: "no-line-task" }));
      await page.locator(".cv-task-line").waitFor();
      const plain = await rows();
      await page.goto(url(STAGE, { variant: "line-task" }));
      await settle(page);
      // No layout shift: the rows sit where they sit with no mark at all.
      expect((await rows()).filter(([id]) => id !== "since")).toEqual(plain.filter(([id]) => id !== "since"));
      // One line, the mark's own.
      expect(await page.locator(".cv-since__rule").count()).toBe(1);
      expectEven(await ink(page));
    } finally {
      await page.close();
    }
  });
});
