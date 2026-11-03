// An opened "Received N messages" row's messages sit on its own columns, with no indent (Leo,
// 2026-11-02, on the opened row's messages about 24px in, each a mark, a sender chip and its first
// line: "why bother indenting here"): every message's mark centres on the head's icon centre, and
// its sender starts where the head's words do, as an opened tool group's steps do. Measured in the
// page from the real transcript (gallery entry agent-pane.received-messages, variant level-1).
// design/chat-transcript.md "One icon column".
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("received-messages-columns-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.received-messages";
  /** How far apart two centres or edges may be, in CSS px. */
  const TOLERANCE = 0.5;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("received messages columns", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "collapsed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string) => {
    const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(0, 0);
    return page;
  };

  test('the turn draws one "Received 7 messages" row, with no session names at rest', async () => {
    const page = await open("collapsed");
    try {
      const heads = await page
        .locator(".cv-lane-batch[data-kind='inbox'] .cv-lane-batch__toggle")
        .evaluateAll((all) => all.map((head) => head.textContent?.trim()));
      expect(heads).toEqual(["Received 7 messages"]);
      expect(await page.locator(".cv-received").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("an opened row's messages share its icon and text columns", async () => {
    const page = await open("level-1");
    try {
      await page.locator(".cv-lane-batch__body .cv-received").first().waitFor();
      const measured = await page.evaluate(() => {
        const visible = (element: Element) => {
          const box = element.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && getComputedStyle(element).visibility !== "hidden";
        };
        const glyphCentre = (slot: Element) => {
          const glyph =
            [...slot.querySelectorAll<Element>("svg, img")].find(visible) ??
            [...slot.querySelectorAll<Element>("span")].find(visible) ??
            slot;
          const box = glyph.getBoundingClientRect();
          return (box.left + box.right) / 2;
        };
        const firstTextLeft = (row: Element, skip: Element) => {
          const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (skip.contains(node) || !node.textContent?.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            const first = [...range.getClientRects()].find((rect) => rect.width > 0);
            if (first) return first.left;
          }
          return Number.NaN;
        };
        const head = document.querySelector(".cv-lane-batch[data-kind='inbox'] .cv-lane-batch__toggle")!;
        const icon = head.querySelector(":scope > .cv-tool__icon")!;
        const lines = [...document.querySelectorAll(".cv-lane-batch__body .cv-received > .cv-disclosure__line")].filter(
          visible,
        );
        return {
          head: { icon: glyphCentre(icon), text: firstTextLeft(head, icon) },
          lines: lines.map((line) => {
            const mark = line.querySelector(".cv-received__mark")!;
            return {
              label: line.textContent?.trim().slice(0, 40) ?? "",
              mark: glyphCentre(mark),
              text: firstTextLeft(line, mark),
            };
          }),
        };
      });
      console.log(JSON.stringify(measured, null, 2));
      expect(measured.lines).toHaveLength(7);
      const off: string[] = [];
      for (const line of measured.lines) {
        if (Math.abs(line.mark - measured.head.icon) > TOLERANCE)
          off.push(`"${line.label}" mark centres at x ${line.mark}, the head's icon at ${measured.head.icon}`);
        if (Math.abs(line.text - measured.head.text) > TOLERANCE)
          off.push(`"${line.label}" sender starts at x ${line.text}, the head's words at ${measured.head.text}`);
      }
      expect(off).toEqual([]);
    } finally {
      await page.close();
    }
  });

  test("an opened message shows its whole text", async () => {
    const page = await open("level-2");
    try {
      const text = page.locator(".cv-lane-batch__body .cv-received__text").first();
      await text.waitFor();
      expect(await text.textContent()).toContain("I left the revert PR open for its owner.");
    } finally {
      await page.close();
    }
  });
});
