// An inspector pick's chip (composer/UIPickChip.tsx) in a real browser, in the strip, placed in the
// prompt and in a sent message, at narrow and wide panes (gallery agent-pane.attachment-chip). Leo,
// 2026-11-08: "clicking it should be able to show the raw/full thing... idk how possible it'd be to
// also be able to have a well-designed button to click to re-collapse it too."
// - Its two label rows are never clipped or covered: each shown part is whole and inside the chip,
//   the rest drop out whole from the end, the element's name always shows.
// - A click opens the whole report in place under the face, in a bounded scroller; the chip grows,
//   its face does not move; Collapse folds it back to its closed height; Escape folds it too.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("ui-pick-chip.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ui-pick-chip: skipping (run `bunx playwright install chromium`)");
    describe.skip("inspector pick chip", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.attachment-chip";
  const VARIANT = "label-element-snippet";
  const HOSTS = {
    strip: '.acpmux-attachments [data-chip-kind="ui"]',
    inline: '.acpmux-md-inline [data-chip-kind="ui"]',
    sent: '.cv-user [data-chip-kind="ui"]',
  } as const;
  const WIDTHS = [240, 320, 900] as const;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function stage(width: number): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: Math.max(width, 480), height: 900 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    for (const selector of Object.values(HOSTS)) await page.waitForSelector(selector, { timeout: 60_000 });
    return page;
  }

  for (const width of WIDTHS)
    test(`at ${width}px: the pick's label rows are never clipped or covered, in every host`, async () => {
      const page = await stage(width);
      try {
        for (const [name, selector] of Object.entries(HOSTS)) {
          const found = await page.evaluate((selector) => {
            const chip = document.querySelector<HTMLElement>(selector)!;
            const chipBox = chip.getBoundingClientRect();
            const top = (x: number, y: number) => document.elementsFromPoint(x, y).find((node) => chip.contains(node));
            const rows = [".acpmux-paste-chip__title", ".acpmux-paste-chip__label"].map((rowSelector) => {
              const row = chip.querySelector<HTMLElement>(rowSelector)!;
              const box = row.getBoundingClientRect();
              return {
                clipped: row.scrollWidth > row.clientWidth + 0.5,
                inChip: box.left >= chipBox.left - 0.5 && box.right <= chipBox.right + 0.5,
                parts: [...row.children].map((part) => {
                  const rect = part.getBoundingClientRect();
                  const hit = top(rect.left + rect.width / 2, rect.top + rect.height / 2);
                  return {
                    text: part.textContent ?? "",
                    shown: rect.top < box.bottom - 0.5 && rect.bottom > box.top + 0.5,
                    whole:
                      rect.left >= box.left - 0.5 &&
                      rect.right <= box.right + 0.5 &&
                      rect.top >= box.top - 0.5 &&
                      rect.bottom <= box.bottom + 0.5,
                    own: Boolean(hit && row.contains(hit)),
                  };
                }),
              };
            });
            return { rows };
          }, selector);
          const [title, caption] = found.rows;
          expect(title!.parts[0]).toMatchObject({ text: "span", shown: true });
          expect(caption!.parts[0]).toMatchObject({ text: "UI element", shown: true });
          for (const row of found.rows) {
            expect({ name, clipped: row.clipped, inChip: row.inChip }).toEqual({ name, clipped: false, inChip: true });
            let dropped = false;
            for (const part of row.parts) {
              if (!part.shown) {
                dropped = true;
                continue;
              }
              expect({ name, text: part.text, dropped }).toEqual({ name, text: part.text, dropped: false });
              expect({ name, text: part.text, whole: part.whole, own: part.own }).toEqual({
                name,
                text: part.text,
                whole: true,
                own: true,
              });
            }
          }
          if (width >= 900) expect(title!.parts.every((part) => part.shown)).toBe(true);
        }
      } finally {
        await page.close();
      }
    });

  for (const [name, selector] of Object.entries(HOSTS))
    test(`${name}: a click opens the report in place; Collapse and Escape fold it back`, async () => {
      const page = await stage(320);
      const chip = page.locator(selector);
      const face = chip.locator("button[aria-expanded]");
      /// The chip's box and its face's top, once both held still since the frame before.
      const settled = () =>
        page.waitForFunction(
          (selector) => {
            const chip = document.querySelector<HTMLElement>(selector)!;
            const box = chip.getBoundingClientRect();
            const at = `${box.top},${box.height},${box.width}`;
            const was = (window as { chipAt?: string }).chipAt;
            (window as { chipAt?: string }).chipAt = at;
            return was === at && document.getAnimations().every((animation) => animation.playState !== "running");
          },
          selector,
          { timeout: 30_000, polling: "raf" },
        );
      const box = () =>
        chip.evaluate((node) => {
          const face = node.querySelector("button[aria-expanded]")!.getBoundingClientRect();
          return { height: node.getBoundingClientRect().height, faceTop: face.top, faceHeight: face.height };
        });
      try {
        await settled();
        const closed = await box();
        await face.click();
        await settled();
        const opened = await box();
        expect(await face.getAttribute("aria-expanded")).toBe("true");
        expect(await page.locator('[role="dialog"]').count()).toBe(0);
        const report = chip.locator('[role="document"]');
        expect(await report.textContent()).toContain("DOM: <span class=");
        // Bounded: the report scrolls inside the chip, never taller than its cap.
        expect(await report.evaluate((node) => node.getBoundingClientRect().height)).toBeLessThanOrEqual(200.5);
        expect(opened.height).toBeGreaterThan(closed.height + 40);
        expect(opened.faceTop).toBeCloseTo(closed.faceTop, 0);
        expect(opened.faceHeight).toBeCloseTo(closed.faceHeight, 0);
        const collapse = chip.getByRole("button", { name: "Collapse" });
        expect(await collapse.isVisible()).toBe(true);
        await collapse.click();
        await settled();
        expect(await face.getAttribute("aria-expanded")).toBe("false");
        expect((await box()).height).toBeCloseTo(closed.height, 0);
        expect(await face.evaluate((node) => node === document.activeElement)).toBe(true);
        for (const key of ["Enter", "Space"]) {
          await face.focus();
          await page.keyboard.press(key);
          await settled();
          expect(await face.getAttribute("aria-expanded")).toBe("true");
          await report.focus();
          await page.keyboard.press("Escape");
          await settled();
          expect(await face.getAttribute("aria-expanded")).toBe("false");
          expect(await face.evaluate((node) => node === document.activeElement)).toBe(true);
        }
      } finally {
        await page.close();
      }
    });
});
