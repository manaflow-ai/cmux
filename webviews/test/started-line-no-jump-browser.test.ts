// l10n-allow-file: test fixtures.
// Leo, 2026-11-24, on a "started working" line that read "Unfuck sideba…" in a lit, outlined chip,
// then "Unfuck sidebar group lo… and Analyze Lucas's Claude bottlene…" a moment later: "this is
// pretty weird? it was collasped then expanded? idk". A name already on the line keeps its width when
// a second subagent joins it, a lone name is not cut while the row has room, the later names give way
// first when it runs short, and a chip drawn under a resting pointer is not lit. Real Chromium on the
// pane's CSS (browser/started-line-no-jump.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("started-line-no-jump-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/started-line-no-jump.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 900, height: 300 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/started-line-no-jump.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const chips = (count: number, width: number) =>
    page.evaluate(
      ([count, width]) => {
        (window as unknown as { show(count: number, width: number): void }).show(count, width);
        return [...document.querySelectorAll<HTMLElement>(".cv-subagent-started__name")].map((chip) => {
          const label = chip.querySelector<HTMLElement>(".cv-agent-tag__label")!;
          return {
            left: Math.round(chip.getBoundingClientRect().left),
            width: Math.round(chip.getBoundingClientRect().width),
            cut: label.scrollWidth > label.clientWidth,
            em: parseFloat(getComputedStyle(chip).fontSize),
          };
        });
      },
      [count, width] as const,
    );

  describe("a subagent start line", () => {
    test("a name keeps its place and width when a second subagent joins the line", async () => {
      const lone = await chips(1, 640);
      const pair = await chips(2, 640);
      expect(pair).toHaveLength(2);
      expect(pair[0]!.left).toBe(lone[0]!.left);
      expect(pair[0]!.width).toBe(lone[0]!.width);
      // Cut at its own cap (16em), never at a share of its own words.
      expect(lone[0]!.width).toBeGreaterThanOrEqual(Math.floor(15.5 * lone[0]!.em));
    });

    test("a short row cuts the later name first", async () => {
      // Room for the first name whole and a few words of the second.
      const lone = await chips(1, 520);
      const pair = await chips(2, 520);
      expect(pair[0]!.width).toBe(lone[0]!.width);
      expect(pair[1]!.cut).toBe(true);
      // Too short for both: each keeps its few words, the later no wider than the first.
      const tight = await chips(2, 360);
      expect(tight[1]!.width).toBeLessThanOrEqual(tight[0]!.width);
      const row = await page.getByTestId("row").evaluate((node) => {
        const sentence = node.querySelector<HTMLElement>(".cv-agent-activity__sentence")!;
        return { right: sentence.getBoundingClientRect().right, edge: node.getBoundingClientRect().right };
      });
      expect(row.right).toBeLessThanOrEqual(row.edge + 0.5);
    });

    test("a chip drawn under a resting pointer is not lit until the pointer moves on it", async () => {
      await chips(1, 640);
      const box = (await page.locator(".cv-subagent-started__name").first().boundingBox())!;
      await chips(0, 640);
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await chips(1, 640);
      const chip = page.locator(".cv-subagent-started__name").first();
      await expect(chip.evaluate((node) => getComputedStyle(node).boxShadow)).resolves.toBe("none");
      await page.mouse.move(box.x + box.width / 2 + 3, box.y + box.height / 2);
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".cv-subagent-started__name")!).boxShadow !== "none",
        undefined,
        { timeout: 2_000 },
      );
    });
  });
});
