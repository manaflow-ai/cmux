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
    // The page as wide as the pane: a wider viewport gives the stage room the pane lacks.
    const page = await browser!.newPage({ viewport: { width, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    for (const selector of Object.values(HOSTS)) await page.waitForSelector(selector, { timeout: 60_000 });
    return page;
  }

  /// Each label part of the chip as the person sees it: `whole` (all of it inside every box that
  /// clips it, the row's hidden second line included, its own text not overflowing, and nothing of
  /// the page over it), `dropped` (none of it shows), `ellipsis` (whole box, its text ending in the
  /// row's ellipsis), else `cut`: some of it shows, the rest clipped mid-word.
  const partsSeen = (page: Page, selector: string) =>
    page.evaluate((selector) => {
      const chip = document.querySelector<HTMLElement>(selector)!;
      const see = (part: Element) => {
        const rect = part.getBoundingClientRect();
        let left = rect.left;
        let right = rect.right;
        let top = rect.top;
        let bottom = rect.bottom;
        for (let box = part.parentElement; box; box = box.parentElement) {
          const style = getComputedStyle(box);
          if (style.overflowX === "visible" && style.overflowY === "visible") continue;
          const clip = box.getBoundingClientRect();
          left = Math.max(left, clip.left);
          right = Math.min(right, clip.right);
          top = Math.max(top, clip.top);
          bottom = Math.min(bottom, clip.bottom);
        }
        if (right - left < 0.5 || bottom - top < 0.5) return "dropped";
        const boxWhole =
          left <= rect.left + 0.5 && right >= rect.right - 0.5 && top <= rect.top + 0.5 && bottom >= rect.bottom - 0.5;
        if (!boxWhole) return "cut";
        const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
        if (!hit || !part.contains(hit)) return "covered";
        const element = part as HTMLElement;
        if (element.scrollWidth > element.clientWidth + 0.5)
          return getComputedStyle(element).textOverflow === "ellipsis" ? "ellipsis" : "cut";
        return "whole";
      };
      return [".acpmux-paste-chip__title", ".acpmux-paste-chip__label"].map((rowSelector) =>
        [...chip.querySelector(rowSelector)!.children].map((part) => ({
          text: part.textContent ?? "",
          seen: see(part),
        })),
      );
    }, selector);

  for (const width of WIDTHS)
    test(`at ${width}px: each label part shows whole or drops whole, in every host`, async () => {
      const page = await stage(width);
      try {
        for (const [name, selector] of Object.entries(HOSTS)) {
          const [title, caption] = await partsSeen(page, selector);
          // The first part always shows; only a pane too narrow for it alone ends it in an ellipsis.
          const first = width >= 320 ? ["whole"] : ["whole", "ellipsis"];
          expect({ name, text: title![0]!.text, first: first.includes(title![0]!.seen) }).toEqual({
            name,
            text: "span",
            first: true,
          });
          expect({ name, text: caption![0]!.text, first: first.includes(caption![0]!.seen) }).toEqual({
            name,
            text: "UI element",
            first: true,
          });
          for (const row of [title!, caption!]) {
            let dropped = false;
            for (const [index, part] of row.entries()) {
              if (index === 0) continue;
              // Never cut mid-word, and none shows after one that dropped.
              expect({ name, text: part.text, seen: part.seen }).toEqual({
                name,
                text: part.text,
                seen: dropped ? "dropped" : part.seen === "whole" ? "whole" : "dropped",
              });
              if (part.seen === "dropped") dropped = true;
            }
          }
          if (width >= 900) expect([...title!, ...caption!].every((part) => part.seen === "whole")).toBe(true);
          // The selector the reviewer saw cut at 320px: whole or gone, never part of it.
          if (width === 320)
            expect(["whole", "dropped"]).toContain(caption!.find((part) => part.text.includes(".cv-li__text"))!.seen);
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
