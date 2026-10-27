// l10n-allow-file: browser fixture prompts, replies and failure details.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("minimap-card-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a two-line prompt, recorded failure and Markdown reply fit without overlapping details or bookmark", async () => {
    const page = await browser.newPage({ viewport: { width: 880, height: 640 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
      await page.waitForFunction(() => "__showRows" in window);
      await page.evaluate(() => {
        const row = (id: string, kind: string, text?: string, extra = {}) => ({
          id,
          kind,
          text,
          at: 1_700_000_000_000,
          version: 1,
          ...extra,
        });
        const rows = Array.from({ length: 4 }, (_, index) => [
          row(
            `user-${index + 1}`,
            "user",
            "Summarize the current rollout and compare it with the previous release while retaining the useful failure details",
          ),
          row(
            `reply-${index}`,
            "assistant",
            "**Ready to ship** `0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef`\n\n- Canary first, then the complete staged rollout across every workspace.\n- Then the fleet\n\nSee https://github.com/manaflow-ai/cmux/pull/25794",
          ),
          row(`summary-${index}`, "turnSummary", undefined, {
            status: "failed",
            durationMs: 42_000,
            toolCount: 3,
            error: "peer disconnected while waiting for the agent to answer; reconnect and try again",
          }),
        ]).flat();
        (window as unknown as { __showRows(rows: unknown[]): void }).__showRows(rows);
      });
      await page.locator(".acpmux-minimap__tick").first().focus();
      const card = page.locator(".acpmux-minimap__card");
      await card.waitFor({ state: "visible" });
      expect(await card.locator("strong").textContent()).toBe("Ready to ship");
      const token = card.locator("code [title]");
      expect(await token.getAttribute("title")).toBe("0123456789abcdef".repeat(4));
      expect(await token.locator("[aria-hidden]").textContent()).toBe("0123456789abcdef0…f0123456789abcdef");
      expect(await token.locator(".acpmux-minimap__full-token").textContent()).toBe("0123456789abcdef".repeat(4));
      expect(await card.locator(".acpmux-minimap__item").count()).toBeGreaterThan(0);
      expect(await card.locator(".acpmux-minimap__item").first().textContent()).toBe(
        "Canary first, then the complete staged rollout across every workspace.",
      );
      expect(await card.locator(".acpmux-minimap__failure").textContent()).toContain("reconnect and try again");
      expect(await card.locator("[data-meta=pr]").getAttribute("href")).toBe(
        "https://github.com/manaflow-ai/cmux/pull/25794",
      );
      const bounds = await card.evaluate((node) => {
        const rect = (selector: string) => node.querySelector(selector)!.getBoundingClientRect();
        const prompt = rect(".acpmux-minimap__prompt");
        const metadata = rect(".acpmux-minimap__metadata");
        const reply = rect(".acpmux-minimap__reply");
        const failure = rect(".acpmux-minimap__failure");
        const bookmark = rect(".acpmux-minimap__bookmark");
        const card = node.getBoundingClientRect();
        return {
          prompt: prompt.height,
          reply: reply.height,
          failure: failure.height,
          gap: metadata.top - prompt.bottom,
          width: card.width,
          bookmarkInside: bookmark.right <= card.right && bookmark.top >= card.top,
        };
      });
      expect(bounds.prompt).toBeGreaterThan(20);
      expect(bounds.prompt).toBeLessThanOrEqual(40);
      expect(bounds.reply).toBeLessThanOrEqual(80);
      expect(bounds.failure).toBeLessThanOrEqual(60);
      expect(bounds.gap).toBeGreaterThanOrEqual(4);
      expect(bounds.width).toBeLessThanOrEqual(360);
      expect(bounds.bookmarkInside).toBe(true);
      await page.locator(".acpmux-scroll").evaluate((node) => {
        node.scrollTop = 200;
      });
      await card.locator("[data-meta=pr]").focus();
      await page.keyboard.press("Home");
      expect(await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop)).toBe(0);
      await card.locator(".acpmux-minimap__bookmark").click();
      await page.waitForFunction(
        () => document.querySelector(".acpmux-minimap__bookmark")?.getAttribute("aria-pressed") === "true",
      );
      await page.setViewportSize({ width: 320, height: 640 });
      await page.waitForFunction(() => {
        const card = document.querySelector(".acpmux-minimap__card")?.getBoundingClientRect();
        return card && card.right <= innerWidth - 8;
      });
    } finally {
      await page.close();
    }
  });
});
