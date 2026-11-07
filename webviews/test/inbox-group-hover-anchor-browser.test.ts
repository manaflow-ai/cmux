// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// A "Received N messages" row's hover (the senders' short names, MessageGroupHead.tsx) shows at the
// row's words, not centered under the whole transcript-wide row (Leo, 2026-11-03: "this hover
// preview is in the wrong place!"). The row is a tool row (`.cv-tool`, width 100%), so its box runs
// to the pane's right edge; the tooltip (ui/titleTooltips.ts) anchors to its words instead. A
// sender's name inside the opened group shows its own tooltip at the name. Each tooltip sits within
// a few px of its anchor's rect, above or below it per `tooltipPosition`, and overlaps it
// horizontally.
// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("inbox-group-hover-anchor-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const entry = "agent-pane.incoming-message-disclosure";
  const variant = "a-shipped";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  const box = (locator: Locator) =>
    locator.evaluate((element) => {
      const r = element.getBoundingClientRect();
      return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    });

  /** Hovers `hovered` and returns the shown tooltip's box and text. */
  async function tooltipFor(page: Page, hovered: Locator) {
    await page.mouse.move(2, 2);
    await page.waitForFunction(() => document.querySelector<HTMLElement>(".ui-title-tooltip")?.hidden !== false);
    await hovered.hover();
    await page.waitForFunction(() => {
      const tip = document.querySelector<HTMLElement>(".ui-title-tooltip");
      return !!tip && !tip.hidden && !tip.hasAttribute("data-ending-style") && tip.textContent !== "";
    });
    const tip = page.locator(".ui-title-tooltip");
    return { rect: await box(tip), text: await tip.textContent() };
  }

  /** The tooltip sits just above or just below `anchor` (the compact 4px gap) and overlaps it horizontally. */
  function expectAt(tip: Box, anchor: Box, what: string) {
    const gap = Math.min(Math.abs(tip.top - anchor.bottom), Math.abs(anchor.top - tip.bottom));
    const overlap = Math.min(tip.right, anchor.right) - Math.max(tip.left, anchor.left);
    const info = `${what}: tooltip ${JSON.stringify(tip)}, anchor ${JSON.stringify(anchor)}`;
    expect(gap, info).toBeLessThanOrEqual(10);
    expect(overlap, info).toBeGreaterThan(0);
    // Centered on the anchor (or pushed in by the window's edge), never off at the row's far end.
    const tipCenter = (tip.left + tip.right) / 2;
    const anchorCenter = (anchor.left + anchor.right) / 2;
    expect(Math.abs(tipCenter - anchorCenter), info).toBeLessThanOrEqual(Math.max(8, (tip.right - tip.left) / 2));
  }

  test("the Received N messages row and a sender's name show their hover at themselves", async () => {
    const width = 900;
    const page = await browser.newPage({ viewport: { width, height: 640 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height: 640 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const head = page.locator('.cv-lane-batch[data-kind="inbox"] .cv-message-group__head').first();
      await head.waitFor();
      const words = head.locator(".cv-message-group__count");
      // The row runs far past its words: the case Leo hit.
      expect((await box(head)).right - (await box(words)).right).toBeGreaterThan(200);

      const onWords = await tooltipFor(page, words);
      expect(onWords.text).toBeTruthy();
      expectAt(onWords.rect, await box(head.locator(".cv-tool__text")), "group row, pointer on its words");

      // The pointer on the row's mark shows the same tooltip at the same place (within the fade-in's rise).
      const onMark = await tooltipFor(page, head.locator(".cv-tool__icon"));
      expect(onMark.text).toBe(onWords.text);
      expect(Math.abs(onMark.rect.left - onWords.rect.left)).toBeLessThanOrEqual(3);
      expect(Math.abs(onMark.rect.top - onWords.rect.top)).toBeLessThanOrEqual(3);

      // Opened, a sender's name shows its own tooltip at the name.
      await head.click();
      const name = page.locator('.cv-lane-batch[data-kind="inbox"] .cv-lane-batch__body .cv-received__from').first();
      await name.waitFor();
      if (await name.evaluate((element) => element.closest("[title], [data-tooltip]") !== null)) {
        const onName = await tooltipFor(page, name);
        expectAt(onName.rect, await box(name), "sender name in the opened group");
      }
    } finally {
      await page.close();
    }
  });
});
