// l10n-allow-file: public gallery fixture and geometry assertions.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-continuation-spacing.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const entry = "agent-pane.continuation-spacing";
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, entry, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  async function open(variant = "shipped"): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 800 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
    await page.waitForSelector('[data-row-id="continuation-footer-d"] .cv-turn-actions');
    await page.waitForFunction(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-row")].every(
        (node, index, nodes) =>
          index === 0 || node.getBoundingClientRect().top >= nodes[index - 1]!.getBoundingClientRect().bottom - 0.5,
      ),
    );
    return page;
  }
  const measure = (page: Page) =>
    page.evaluate(() => {
      const node = (id: string) => document.querySelector<HTMLElement>(`[data-row-id="continuation-${id}"]`)!;
      const gap = (id: string, next: string) =>
        node(next).getBoundingClientRect().top -
        node(id).querySelector(".cv-turn-actions")!.getBoundingClientRect().bottom;
      return {
        same: gap("footer-a", "b"),
        peer: gap("footer-b", "peer"),
        user: gap("footer-c", "user"),
        paddings: ["footer-a", "footer-b", "footer-c", "footer-d"].map((id) =>
          parseFloat(getComputedStyle(node(id)).paddingBottom),
        ),
      };
    });
  test("same assistant uses the half-gap token; user and different-agent boundaries keep the full token", async () => {
    const page = await open();
    await page.waitForFunction(
      () => document.querySelector('[data-row-id="continuation-b"]')!.getBoundingClientRect().top > 0,
    );
    const actual = await measure(page);
    // A footer's line moves down inside its row (--cv-footer-drop: 2px over the same agent, else
    // 4px) to sit centred between the reply and the next row; the drop comes off the bottom padding.
    // The footer that ends the chat (footer-d) has no next row and keeps the full turn gap.
    expect(actual.same).toBeCloseTo(6, 1);
    expect(actual.peer).toBeCloseTo(12, 1);
    expect(actual.user).toBeCloseTo(12, 1);
    expect(actual.paddings).toEqual([6, 12, 12, 16]);
    await page.evaluate(() => {
      const root = document.documentElement;
      root.style.setProperty("--ds-space-2", "10px");
      root.style.setProperty("--ds-space-4", "20px");
    });
    await page.waitForFunction(
      () => getComputedStyle(document.querySelector('[data-row-id="continuation-footer-a"]')!).paddingBottom === "8px",
    );
    expect((await measure(page)).paddings).toEqual([8, 16, 16, 20]);
    await page.close();
  });
  test("public gallery before/after capture", async () => {
    const output = process.env.CMUX_SPACING_CAPTURE;
    if (!output) return;
    await mkdir(output, { recursive: true });
    for (const variant of ["shipped", "two-thirds", "half-tucked"]) {
      const page = await open(variant);
      await page.screenshot({ path: path.join(output, `${variant}.png`) });
      await page.close();
    }
  });
});
