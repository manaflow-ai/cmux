// l10n-allow-file: synthetic received messages, never shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import strings from "../src/agent-session/acpmux/generated/strings.json";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-folded-messages-browser.test.ts", async () => {
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  }, 120_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("a message-heavy chat keeps the rail and each folded sender preview and navigation target", async () => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, reducedMotion: "reduce" });
    try {
      await page.addInitScript((strings) => {
        globalThis.__cmuxPaneStrings = strings;
      }, strings);
      await page.goto(`${vite.resolvedUrls!.local[0]}test/browser/transcript-follow.html`);
      await page.waitForFunction(
        () => typeof (window as unknown as { __showRows?: unknown }).__showRows === "function",
      );
      const rows = Array.from({ length: 24 }, (_, index) => ({
        id: `user-${index + 10}`,
        kind: "user",
        version: 1,
        at: 1_700_000_000_000 + index,
        text: `Synthetic report ${index}`,
        incoming: {
          kind: "message",
          message: {
            name: `Worker ${index}`,
            sessionId: `worker-${index}`,
            text: `Synthetic report ${index}`,
            raw: `Synthetic report ${index}`,
          },
        },
      }));
      rows.push({
        id: "answer",
        kind: "assistant",
        version: 1,
        at: 1_700_000_001_000,
        text: Array.from(
          { length: 40 },
          (_, index) =>
            `Synthetic response paragraph ${index}: the demonstration checks each received report and records the result.`,
        ).join("\n\n"),
      } as (typeof rows)[number]);
      await page.evaluate((rows) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(rows), rows);
      await page.locator(".cv-waiting").waitFor();
      if (process.env.RAIL_FOLD_CAPTURE) await page.screenshot({ path: process.env.RAIL_FOLD_CAPTURE });
      const ticks = page.locator(".acpmux-minimap__tick");
      expect(await ticks.count()).toBe(24);
      const tick = ticks.nth(7);
      await tick.focus();
      const card = page.locator(".acpmux-minimap__card");
      await card.waitFor();
      expect(await card.innerText()).toContain("Worker 7");
      expect(await card.innerText()).toContain("Synthetic report 7");
      expect(await tick.getAttribute("aria-label")).toContain("Worker 7");
      await page.locator(".acpmux-scroll").evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await tick.click();
      await page.waitForFunction(() => document.querySelector(".acpmux-scroll")!.scrollTop < 100);
      const parent = page.locator('[data-row-id="messages-user-10"]');
      expect(await parent.count()).toBe(1);
      if (process.env.RAIL_FOLD_PREVIEW_CAPTURE) await page.screenshot({ path: process.env.RAIL_FOLD_PREVIEW_CAPTURE });
    } finally {
      await page.close();
    }
  }, 120_000);
});
