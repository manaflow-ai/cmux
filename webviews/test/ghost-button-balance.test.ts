// Icon+label ghost buttons look even and sit close (cx-s6zvc, Leo's polish note): New Tab's tools
// and the composer footer's folder button had a larger inset before the icon than after the label,
// so the hover pill looked left-heavy, a 9 px icon gap, and loose rows. They now share one
// primitive (ui/ghost.css). This measures the real gallery stages in Chromium: the ink before the
// icon matches the inset after the label (a 14 px stroke icon's ink starts about 2 px inside its
// box), the icon sits 6 px from its label, a row is tighter than a button's own inset, and labels
// are medium weight. New Tab's tools row is gone from the calm default (Leo 2026-10-11), so the
// composer footer's folder button is what is measured here.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("ghost-button-balance.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ghost-button-balance: skipping (run `bunx playwright install chromium`)");
    describe.skip("ghost button balance", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  async function ready(page: Page) {
    for (;;) {
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        return;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-context", { browser, params: { variant: "closed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Each visible button's insets: before its first icon, between icon and label, after its label. */
  async function measure(entry: string, variant: string, selector: string) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.goto(url(entry, variant));
    await ready(page);
    await page.locator(selector).first().waitFor();
    const buttons = await page.evaluate((sel) => {
      const all = [...document.querySelectorAll<HTMLElement>(sel)].filter((b) => b.offsetWidth > 0);
      return all.map((b, index) => {
        const box = b.getBoundingClientRect();
        const icons = [...b.querySelectorAll("svg")].map((svg) => svg.getBoundingClientRect());
        const walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
        let text: DOMRect | undefined;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          text = range.getBoundingClientRect();
          break;
        }
        const next = all[index + 1]?.getBoundingClientRect();
        return {
          before: icons[0] ? icons[0].left - box.left : undefined,
          gap: icons[0] && text ? text.left - icons[0].right : undefined,
          after: text && icons.length < 2 ? box.right - text.right : undefined,
          afterChevron: icons.length > 1 ? box.right - icons[icons.length - 1]!.right : undefined,
          rowGap: next && Math.abs(next.top - box.top) < 2 ? next.left - box.right : undefined,
          weight: Number(getComputedStyle(b).fontWeight),
        };
      });
    }, selector);
    await page.close();
    return buttons;
  }

  test("the composer footer's folder button: the folder's ink and the chevron's sit evenly", async () => {
    const [folder] = await measure("agent-pane.composer-context", "closed", ".acpmux-location-button");
    // Folder ink 1.5 px inside its box, chevron ink 4 px inside its box.
    expect(Math.abs(folder!.before! + 1.5 - (folder!.afterChevron! + 4))).toBeLessThanOrEqual(0.6);
    expect(Math.abs(folder!.gap! - 4)).toBeLessThanOrEqual(0.6);
  });
});
