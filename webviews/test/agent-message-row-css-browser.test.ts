// l10n-allow-file: test fixtures.
// The CSS that styled a message's DisclosureRow reaches the one message row (AgentMessageRow.tsx)
// that every message between agents now draws (cmux#37653): in an opened waiting group
// (PendingMessagesCard.css) a sender's lines leave out the name its head already says, and an opened
// message card's corner copy (CardCopy.css) lights when the card is hovered and keeps its float in a
// card shorter than the button. Real Chromium on the pane's CSS (browser/agent-message-row-css.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-message-row-css-browser.test.ts", async () => {
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
    await warmViteServer(vite, "/test/browser/agent-message-row-css.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/agent-message-row-css.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("agent message row CSS", () => {
    test("an opened waiting group's lines leave out the sender its head names", async () => {
      const pending = page.getByTestId("pending");
      await pending.locator(".cv-pending__toggle").click();
      const senders = pending.locator(".cv-pending__sender .cv-agentmsg__line .cv-received__sender");
      await expect(senders.count()).resolves.toBe(2);
      for (const display of await senders.evaluateAll((all) => all.map((node) => getComputedStyle(node).display)))
        expect(display).toBe("none");
      // The head still names it.
      await expect(pending.locator(".cv-pending__sender-head .cv-received__sender").isVisible()).resolves.toBe(true);
    });

    test("an opened message card's corner copy lights when the card is hovered", async () => {
      const received = page.getByTestId("received");
      await received.locator(".cv-agentmsg__toggle").click();
      const copy = received.locator(".cv-agentmsg__card > .cv-card-copy");
      await expect(copy.count()).resolves.toBe(1);
      await page.mouse.move(0, 599);
      expect(Number(await copy.evaluate((node) => getComputedStyle(node).opacity))).toBeLessThan(1);
      await received.locator(".cv-agentmsg__card").hover({ position: { x: 4, y: 4 } });
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".cv-agentmsg__card > .cv-card-copy")!).opacity === "1",
        undefined,
        { timeout: 2_000 },
      );
    });

    test("an opened message card holds its floated corner copy", async () => {
      const card = page.getByTestId("received").locator(".cv-agentmsg__card");
      await expect(card.evaluate((node) => getComputedStyle(node).display)).resolves.toBe("flow-root");
    });
  });
});
