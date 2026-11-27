// l10n-allow-file: gallery fixture names are test data.
// The one-line composer hat keeps its words, its subagent marks and its "+N more" on one centre line,
// and pointing at a mark changes nothing in the words. Leo, 2026-11-27, on "10 subagents working"
// with its row of marks and "+2 more": "why is this misaligned let's prevent misalignment", and on
// the hover that swapped the words for one subagent's title and latest step: "tdont think we should
// have this hover anymore it's really bad".
//
// Real Chromium (Playwright), the gallery's `agent-pane.composer-hat-line-deck`, at 360px and 900px,
// in every arm: each mark, the "+N more" and the hide tab centre on the words' glyphs within 0.5px.
// The words are read by their glyph box (a Range over the text: the font's ascent to descent), not by
// their line box, so a line-height or font-size that differs from the row's shows here as it does on
// screen. Then the pointer runs along the marks and the words stay as they were. With
// CMUX_TEST_ARTIFACTS set, each case leaves a screenshot of the hat there.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-line-align.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.composer-hat-line-deck";
  const TOLERANCE = 0.5;
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
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "trail-eight" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (variant: string, width: number, widthName: string): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width, height: 420 }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: widthName })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(".acpmux-running-tray__head .acpmux-running-tray__title");
    // The words settle (trayMotion.tsx `Tick` slides a change in): read them at rest.
    await page.waitForTimeout(400);
    return page;
  };

  /** Each part's vertical centre less the words' glyph centre, and the words as drawn. */
  const offsets = (page: Page) =>
    page.evaluate(() => {
      const head = document.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      const glyphMiddle = (node: Element) => {
        const range = document.createRange();
        range.selectNodeContents(node);
        const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
        if (rects.length === 0) return undefined;
        const top = Math.min(...rects.map((rect) => rect.top));
        const bottom = Math.max(...rects.map((rect) => rect.bottom));
        return (top + bottom) / 2;
      };
      const boxMiddle = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return rect.height > 0 ? rect.top + rect.height / 2 : undefined;
      };
      const title = head.querySelector(".acpmux-running-tray__title")!;
      const line = glyphMiddle(title)!;
      const parts: [string, number | undefined][] = [];
      head
        .querySelectorAll(".acpmux-hat-deck__mark:not([data-blank]) .acpmux-hat-deck__face")
        .forEach((face, index) => parts.push([`mark ${index}`, boxMiddle(face.querySelector("svg, img") ?? face)]));
      const rest = head.querySelector(".acpmux-hat-deck__rest");
      if (rest) parts.push(["+N more", glyphMiddle(rest)]);
      const latest = head.querySelector(".acpmux-running-tray__latest");
      if (latest) parts.push(["latest", glyphMiddle(latest)]);
      return {
        text: title.textContent ?? "",
        latest: latest?.textContent ?? "",
        off: Object.fromEntries(
          parts.flatMap(([name, middle]) => (middle === undefined ? [] : [[name, middle - line]])),
        ) as Record<string, number>,
      };
    });

  const shoot = async (page: Page, name: string) => {
    const dir = process.env.CMUX_TEST_ARTIFACTS;
    if (!dir) return;
    const hat = page.locator(".acpmux-running-tray").first();
    const box = await hat.boundingBox();
    if (!box) return;
    await page.screenshot({
      path: path.join(dir, `composer-hat-line-${name}.png`),
      clip: { x: 0, y: Math.max(0, box.y - 12), width: page.viewportSize()!.width, height: box.height + 24 },
    });
  };

  const cases: [string, number, string, boolean][] = [];
  for (const variant of ["trail-eight", "trail-three", "lead-eight", "cards-eight", "words-eight"])
    for (const [width, widthName] of [
      [360, "narrow"],
      [900, "wide"],
    ] as const)
      cases.push([variant, width, widthName, !variant.startsWith("words")]);

  for (const [variant, width, widthName, marks] of cases)
    test(`${variant} at ${width}px: words, marks and +N more on one centre line; hovering a mark keeps the words`, async () => {
      const page = await open(variant, width, widthName);
      try {
        const rest = await offsets(page);
        await shoot(page, `${variant}-${width}`);
        const report = `${variant} ${width}px: ${JSON.stringify(rest)}`;
        console.log(report);
        if (marks)
          expect(
            Object.keys(rest.off).some((name) => name.startsWith("mark")),
            report,
          ).toBe(true);
        for (const [name, off] of Object.entries(rest.off))
          expect(Math.abs(off), `${name} off the words' centre by ${off.toFixed(2)}px; ${report}`).toBeLessThanOrEqual(
            TOLERANCE,
          );
        if (!marks) return;
        // The pointer runs along the marks: the words never change, and no latest step joins them.
        const count = await page.locator(".acpmux-hat-deck__mark:not([data-blank])").count();
        for (let index = 0; index < count; index += 1) {
          await page.locator(".acpmux-hat-deck__mark:not([data-blank])").nth(index).hover({ force: true });
          await page.waitForTimeout(60);
          const now = await offsets(page);
          expect({ mark: index, text: now.text, latest: now.latest }).toEqual({
            mark: index,
            text: rest.text,
            latest: rest.latest,
          });
          expect(
            await page.locator(".acpmux-hat-deck[data-peeking], .acpmux-hat-deck__mark[data-peeked]").count(),
          ).toBe(0);
        }
        await shoot(page, `${variant}-${width}-hover`);
      } finally {
        await page.close();
      }
    });

  // Leo, 2026-11-27: "it shows all the way, and when you hover it pushes to the left".
  test("a cut title scrolls left to its end while the pointer rests on the header, and back when it leaves", async () => {
    const page = await open("trail-three", 900, "wide");
    try {
      const title = page.locator(".acpmux-running-tray__head > .acpmux-running-tray__title").first();
      // A header too short for the whole title: the title is held to 60px, as a narrow pane cuts it.
      await title.evaluate((node) => {
        (node as HTMLElement).style.maxWidth = "60px";
      });
      const words = title.locator(":scope > span:last-child");
      expect(await words.evaluate((node) => node.scrollWidth - node.clientWidth)).toBeGreaterThan(2);
      await title.hover({ force: true });
      // The tabs' clock (ui/titleFade.ts MOTION_MARQUEE): 0.6s at rest, then 40px/s.
      await page.waitForTimeout(1100);
      const read = () =>
        words.evaluate((node) => ({
          marquee: (node as HTMLElement).dataset.marquee !== undefined,
          indent: Number.parseFloat(getComputedStyle(node).textIndent) || 0,
          ellipsis: getComputedStyle(node).textOverflow,
        }));
      const moving = await read();
      await shoot(page, "title-marquee");
      expect(moving.marquee).toBe(true);
      expect(moving.indent).toBeLessThan(-2);
      expect(moving.ellipsis).toBe("clip");
      // Off the hat: 30px above or below its header.
      const head = (await page.locator(".acpmux-running-tray__head").first().boundingBox())!;
      await page.mouse.move(2, head.y > 40 ? head.y - 30 : head.y + head.height + 30);
      await page.waitForTimeout(900);
      expect(await read()).toEqual({ marquee: false, indent: 0, ellipsis: "ellipsis" });
    } finally {
      await page.close();
    }
  });
});
