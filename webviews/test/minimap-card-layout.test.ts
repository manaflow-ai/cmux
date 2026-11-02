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

  test("a three-line prompt shares the fixed card height with the reply and stays clear of the bookmark", async () => {
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
            "Summarize the current rollout\nwhile retaining the useful failure details\nand compare it with the previous release",
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
      expect(await card.locator(".acpmux-minimap__prompt").textContent()).toContain("\n");
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
        const baseline = node.cloneNode(true) as HTMLElement;
        baseline.removeAttribute("data-prompt");
        baseline.removeAttribute("data-card-failure");
        baseline.style.cssText = "position:absolute; visibility:hidden; max-height:none; overflow:visible;";
        baseline.querySelector<HTMLElement>(".acpmux-minimap__prompt")!.style.webkitLineClamp = "2";
        baseline.querySelector<HTMLElement>(".acpmux-minimap__reply")!.style.cssText =
          "-webkit-line-clamp:4; height:auto; max-height:none;";
        document.body.append(baseline);
        const baselineHeight = baseline.getBoundingClientRect().height;
        baseline.remove();
        const inside = (child: DOMRect) =>
          child.top >= card.top && child.bottom <= card.bottom && child.left >= card.left && child.right <= card.right;
        return {
          prompt: prompt.height,
          reply: reply.height,
          failure: failure.height,
          gap: metadata.top - prompt.bottom,
          width: card.width,
          baselineHeight,
          bookmarkInside: bookmark.right <= card.right && bookmark.top >= card.top,
          promptInside: inside(prompt),
          metadataInside: inside(metadata),
          replyInside: inside(reply),
          failureInside: inside(failure),
        };
      });
      expect(bounds.prompt).toBeGreaterThan(20);
      expect(bounds.prompt).toBeLessThanOrEqual(60);
      expect(bounds.reply).toBeGreaterThanOrEqual(20);
      // Chromium's body line box is fractional, but each rendered reply line remains complete.
      expect(bounds.reply).toBeLessThanOrEqual(84);
      expect(bounds.failure).toBeLessThanOrEqual(60);
      expect(bounds.gap).toBeGreaterThanOrEqual(4);
      expect(bounds.width).toBeLessThanOrEqual(360);
      expect(await card.evaluate((node) => node.getBoundingClientRect().height)).toBeLessThanOrEqual(
        bounds.baselineHeight,
      );
      expect(bounds.bookmarkInside).toBe(true);
      expect(bounds.promptInside).toBe(true);
      expect(bounds.metadataInside).toBe(true);
      expect(bounds.replyInside).toBe(true);
      expect(bounds.failureInside).toBe(true);
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
    } finally {
      await page.close();
    }
  });

  test("a short prompt keeps its natural height while a long prompt spends reply lines", async () => {
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
        const rows = [
          [
            row("user-short", "user", "A short prompt"),
            row("reply-short", "assistant", "A reply with enough detail to keep the card useful."),
            row("summary-short", "turnSummary", undefined, { status: "completed" }),
          ],
          [
            row(
              "user-long",
              "user",
              "First prompt line\nSecond prompt line\nThird prompt line\nFourth line is beyond the cap",
            ),
            row(
              "reply-long",
              "assistant",
              "First reply line stays visible.\nSecond reply line stays visible.\nThird detail remains in the transcript.",
            ),
            row("summary-long", "turnSummary", undefined, { status: "completed" }),
          ],
          [
            row("user-third", "user", "Another prompt"),
            row("reply-third", "assistant", "Another reply."),
            row("summary-third", "turnSummary", undefined, { status: "completed" }),
          ],
          [
            row("user-fourth", "user", "Final prompt"),
            row("reply-fourth", "assistant", "Final reply."),
            row("summary-fourth", "turnSummary", undefined, { status: "completed" }),
          ],
        ].flat();
        (window as unknown as { __showRows(rows: unknown[]): void }).__showRows(rows);
      });

      const inspect = async (tick: number) => {
        const target = page.locator(`[data-tick="${tick}"]`);
        await target.focus();
        const card = page.locator(".acpmux-minimap__card");
        await card.waitFor({ state: "visible" });
        return card.evaluate((node) => {
          const bounds = (selector: string) => node.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
          const prompt = bounds(".acpmux-minimap__prompt");
          const reply = bounds(".acpmux-minimap__reply");
          const card = node.getBoundingClientRect();
          return {
            card: card.height,
            baseline: (() => {
              const clone = node.cloneNode(true) as HTMLElement;
              clone.removeAttribute("data-prompt");
              clone.removeAttribute("data-card-failure");
              clone.style.cssText = "position:absolute; visibility:hidden; max-height:none; overflow:visible;";
              clone.querySelector<HTMLElement>(".acpmux-minimap__prompt")!.style.webkitLineClamp = "2";
              clone.querySelector<HTMLElement>(".acpmux-minimap__reply")!.style.cssText =
                "-webkit-line-clamp:4; height:auto; max-height:none;";
              document.body.append(clone);
              const height = clone.getBoundingClientRect().height;
              clone.remove();
              return height;
            })(),
            prompt: prompt.height,
            promptScroll: (node.querySelector(".acpmux-minimap__prompt") as HTMLElement).scrollHeight,
            reply: reply.height,
            text: node.querySelector(".acpmux-minimap__prompt")?.textContent ?? "",
          };
        });
      };
      const short = await inspect(0);
      const long = await inspect(1);
      expect(short.prompt).toBeLessThanOrEqual(20);
      expect(short.card).toBeLessThan(166);
      expect(Math.abs(short.card - short.baseline)).toBeLessThanOrEqual(1);
      expect(long.prompt).toBeGreaterThan(short.prompt);
      expect(long.prompt).toBeLessThanOrEqual(60);
      expect(long.promptScroll).toBeGreaterThan(long.prompt + 1);
      expect(long.reply).toBeGreaterThanOrEqual(20);
      expect(long.card).toBeLessThanOrEqual(166);
      expect(long.card).toBeLessThanOrEqual(long.baseline);
      expect(long.text).toContain("Fourth line is beyond the cap");
    } finally {
      await page.close();
    }
  });

  test("a narrow failure card wraps metadata without clipping any prompt, error or reply line", async () => {
    // The rail intentionally hides below its supported gutter; keep the transcript viewport wide
    // enough to mount the tick, then constrain the card itself to exercise narrow wrapping.
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
            `user-${index}`,
            "user",
            "Prompt line one\nPrompt line two\nPrompt line three\nPrompt line four\nPrompt line five\nPrompt line six",
          ),
          row(
            `reply-${index}`,
            "assistant",
            "A useful reply remains visible below the failure details.\nSecond reply line stays whole.\nThird detail follows.\nhttps://github.com/manaflow-ai/cmux/pull/25794 https://github.com/manaflow-ai/cmux/pull/25795 https://github.com/manaflow-ai/cmux/pull/25796",
          ),
          row(`summary-${index}`, "turnSummary", undefined, {
            status: "failed",
            durationMs: 42_000,
            toolCount: 7,
            fileCount: 5,
            error: "peer disconnected while waiting for the agent to answer; reconnect and try again now",
          }),
        ]).flat();
        (window as unknown as { __showRows(rows: unknown[]): void }).__showRows(rows);
      });
      const tick = page.locator('[data-tick="0"]');
      await tick.focus();
      const card = page.locator(".acpmux-minimap__card");
      await card.waitFor({ state: "visible" });
      await card.evaluate((node) => {
        node.style.width = "280px";
        node.style.minWidth = "0";
        node.style.maxWidth = "280px";
      });
      await page.waitForFunction(() => {
        const card = document.querySelector<HTMLElement>(".acpmux-minimap__card");
        const metadata = card?.querySelector<HTMLElement>(".acpmux-minimap__metadata");
        return !!card && card.getBoundingClientRect().width <= 280 && !!metadata && metadata.offsetHeight > 16;
      });
      const bounds = await card.evaluate((node) => {
        const card = node.getBoundingClientRect();
        const get = (selector: string) => node.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
        const inside = (rect: DOMRect) =>
          rect.top >= card.top && rect.bottom <= card.bottom && rect.left >= card.left && rect.right <= card.right;
        const baseline = node.cloneNode(true) as HTMLElement;
        baseline.removeAttribute("data-prompt");
        baseline.removeAttribute("data-card-failure");
        baseline.style.cssText = `position:absolute; visibility:hidden; width:${card.width}px; min-width:0; max-width:${card.width}px; max-height:none; overflow:visible;`;
        baseline.querySelector<HTMLElement>(".acpmux-minimap__prompt")!.style.webkitLineClamp = "2";
        baseline.querySelector<HTMLElement>(".acpmux-minimap__reply")!.style.cssText =
          "-webkit-line-clamp:4; height:auto; max-height:none;";
        document.body.append(baseline);
        const baselineHeight = baseline.getBoundingClientRect().height;
        baseline.remove();
        return {
          card,
          baselineHeight,
          prompt: get(".acpmux-minimap__prompt"),
          metadata: get(".acpmux-minimap__metadata"),
          failure: get(".acpmux-minimap__failure"),
          reply: get(".acpmux-minimap__reply"),
          inside: [
            ".acpmux-minimap__prompt",
            ".acpmux-minimap__metadata",
            ".acpmux-minimap__failure",
            ".acpmux-minimap__reply",
          ].map((selector) => inside(get(selector))),
        };
      });
      expect(bounds.card.height).toBeLessThanOrEqual(bounds.baselineHeight);
      expect(bounds.prompt.height).toBeLessThanOrEqual(60);
      expect(bounds.metadata.height).toBeGreaterThan(16);
      expect(bounds.failure.height).toBeGreaterThan(40);
      expect(bounds.reply.height).toBeGreaterThanOrEqual(20);
      expect(bounds.inside.every(Boolean)).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("a reply-only preview keeps its four-line budget", async () => {
    const page = await browser.newPage({ viewport: { width: 880, height: 640 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
      const bounds = await page.evaluate(() => {
        const card = document.createElement("div");
        card.className = "acpmux-minimap__card";
        card.innerHTML = '<div class="acpmux-minimap__reply"><p>one</p><p>two</p><p>three</p><p>four</p></div>';
        card.style.cssText = "position:absolute; visibility:hidden;";
        document.body.append(card);
        const reply = card.querySelector<HTMLElement>(".acpmux-minimap__reply")!.getBoundingClientRect();
        const height = card.getBoundingClientRect().height;
        card.remove();
        return { height, reply: reply.height };
      });
      expect(bounds.reply).toBeGreaterThanOrEqual(80);
      expect(bounds.height).toBeGreaterThanOrEqual(bounds.reply);
    } finally {
      await page.close();
    }
  });
});
