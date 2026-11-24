// An oversized paste's chip in the composer (composer/PastedTextChip.tsx), in the strip and placed in
// the prompt, at narrow and wide panes. Leo, 2026-11-08, on the old card (its label cut mid-word and
// Keep as .txt drawn over it): "this is really ugly and bad and normally in chatgpt you can just click
// it to expand or smth and maybe in claude you see it in a viewer?".
// - The label is never clipped and nothing covers it: each part it shows is whole and inside the
//   chip, the rest drop out whole (the size first, then the line count), and the point at each shown
//   part's middle is the label's own.
// - No floating tooltip or action sits on the closed chip: no `title`, no Keep as .txt.
// - A click, Return or Space opens the whole text with Keep as .txt and Edit in Prompt inside it;
//   Escape closes it and gives focus back to the chip.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-paste-chip.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-paste-chip: skipping (run `bunx playwright install chromium`)");
    describe.skip("pasted text chip", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  /// Each host of the chip, in the gallery entries that draw it: the strip's and the prompt's.
  const HOSTS = [
    {
      name: "strip",
      entry: "agent-pane.text-attachment-card",
      variant: "page",
      chip: ".acpmux-attachment-pasted:not([data-text-kind])",
    },
    {
      name: "inline",
      entry: "agent-pane.composer",
      variant: "text-pasted-inline",
      chip: '[data-inline-attachment] .acpmux-md-inline-chip[data-preview="text"]',
    },
  ] as const;
  const WIDTHS = [240, 320, 900] as const;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const host of HOSTS) await warmGalleryFrame(vite, host.entry, { browser, params: { variant: host.variant } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function stage(host: (typeof HOSTS)[number], width: number): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: Math.max(width, 480), height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(host.entry, { variant: host.variant, width })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    await page.waitForSelector(`${host.chip} .acpmux-text-card__label`, { timeout: 60_000 });
    // The composer grows to a pasted chip over a few frames (its spring, fieldGrowth.ts), clipping it
    // until then: measure once the chip's label row is out (the chip is under the point at its start
    // and end) and the chip held still since the frame before.
    await page.waitForFunction(
      (selector) => {
        const chip = document.querySelector<HTMLElement>(selector);
        const label = chip?.querySelector<HTMLElement>(".acpmux-text-card__label");
        if (!chip || !label) return false;
        const box = chip.getBoundingClientRect();
        const row = label.getBoundingClientRect();
        const at = `${box.top},${box.left},${box.height},${box.width}`;
        const still = (window as { pasteChipAt?: string }).pasteChipAt === at;
        (window as { pasteChipAt?: string }).pasteChipAt = at;
        const out = [row.left + 2, row.right - 2].every((x) =>
          document.elementsFromPoint(x, row.top + row.height / 2).some((node) => chip.contains(node)),
        );
        return still && out;
      },
      host.chip,
      { timeout: 30_000, polling: "raf" },
    );
    return page;
  }

  for (const host of HOSTS)
    for (const width of WIDTHS)
      test(`${host.name} at ${width}px: the label is never clipped or covered, and no tooltip floats on the chip`, async () => {
        const page = await stage(host, width);
        try {
          const found = await page.evaluate((selector) => {
            const chip = document.querySelector<HTMLElement>(selector)!;
            const label = chip.querySelector<HTMLElement>(".acpmux-text-card__label")!;
            const chipBox = chip.getBoundingClientRect();
            /// The chip's own topmost element at a point: what covers the label there, if anything
            /// of the chip does (the composer's own clip around the chip is not the chip's).
            const top = (x: number, y: number) => document.elementsFromPoint(x, y).find((node) => chip.contains(node));
            const box = label.getBoundingClientRect();
            const parts = [...label.children].map((part) => {
              const rect = part.getBoundingClientRect();
              const shown = rect.top < box.bottom - 0.5 && rect.bottom > box.top + 0.5;
              const whole =
                rect.left >= box.left - 0.5 &&
                rect.right <= box.right + 0.5 &&
                rect.top >= box.top - 0.5 &&
                rect.bottom <= box.bottom + 0.5;
              const hit = top(rect.left + rect.width / 2, rect.top + rect.height / 2);
              return { text: part.textContent ?? "", shown, whole, own: Boolean(hit && label.contains(hit)) };
            });
            const titled = [chip, ...chip.querySelectorAll("*")].filter((node) => node.hasAttribute("title")).length;
            return {
              text: label.textContent ?? "",
              clipped: label.scrollWidth > label.clientWidth + 0.5,
              inChip: box.left >= chipBox.left - 0.5 && box.right <= chipBox.right + 0.5,
              labelHit: (() => {
                const hit = top(box.left + 4, box.top + box.height / 2) ?? top(box.right - 4, box.top + box.height / 2);
                return Boolean(hit && label.contains(hit));
              })(),
              parts,
              titled,
              keepOnChip: chip.querySelectorAll(".acpmux-attachment-keep-file").length,
            };
          }, host.chip);
          expect(found.text.startsWith("Pasted text")).toBe(true);
          expect(found.clipped).toBe(false);
          expect(found.inChip).toBe(true);
          expect(found.labelHit).toBe(true);
          // The label's parts: the name is always shown; every shown part is whole, uncovered, and
          // the parts drop from the end (never a later part shown after an earlier one went).
          expect(found.parts.length).toBeGreaterThan(1);
          expect(found.parts[0]).toMatchObject({ text: "Pasted text", shown: true });
          let dropped = false;
          for (const part of found.parts) {
            if (!part.shown) {
              dropped = true;
              continue;
            }
            expect(dropped).toBe(false);
            expect(part.whole).toBe(true);
            expect(part.own).toBe(true);
          }
          if (width >= 900) expect(found.parts.every((part) => part.shown)).toBe(true);
          expect(found.titled).toBe(0);
          expect(found.keepOnChip).toBe(0);
        } finally {
          await page.close();
        }
      });

  for (const host of HOSTS)
    test(`${host.name}: a click, Return or Space opens the whole text with Keep as .txt in it; Escape closes`, async () => {
      const page = await stage(host, 320);
      const face = page.locator(`${host.chip} button[aria-haspopup="dialog"]`);
      const view = page.locator('[role="dialog"]');
      try {
        await face.click();
        await view.waitFor({ state: "visible" });
        expect(await view.textContent()).toContain("step 39: compiling module 39");
        const keep = view.locator(".acpmux-attachment-keep-file");
        expect(await keep.textContent()).toBe("Keep as .txt");
        expect(await view.locator("button", { hasText: "Edit in Prompt" }).count()).toBe(1);
        // The text reads whole: its scroller holds every line, never a preview cut short.
        const lines = await view
          .locator(".acpmux-paste-view__text")
          .evaluate((node) => node.textContent!.split("\n").length);
        expect(lines).toBeGreaterThan(30);
        await page.keyboard.press("Escape");
        await view.waitFor({ state: "detached" });
        expect(await face.evaluate((node) => node === document.activeElement)).toBe(true);
        for (const key of ["Enter", " "]) {
          await face.focus();
          await page.keyboard.press(key === " " ? "Space" : key);
          await view.waitFor({ state: "visible" });
          await page.keyboard.press("Escape");
          await view.waitFor({ state: "detached" });
        }
      } finally {
        await page.close();
      }
    });
});
