// l10n-allow-file: test fixture prompts and senders, not shipped UI.
// At rest every tick on the prompt rail shares one column, one x and one width, other sessions'
// messages included; the sender shows only in the hover preview (leo-workspace
// design/session-rail.md). #31681 set another session's tick in 6 px and shorter, so the rail read
// jagged; Leo 2026-11-02, on that rail: "WTF ARE THESE". In a real engine, since the column is CSS.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { incomingPrompt } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-rail-one-column.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-one-column: skipping (run `bunx playwright install chromium`)");
    describe.skip("thread rail one column", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
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

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const fromSession = (n: number, sender: string) => {
    const body = `Step ${n} landed on the helper's branch; CI is green.`;
    const incoming = incomingPrompt(body, {
      _meta: { provenance: { kind: "session_message", from: `${sender}-id`, fromName: sender, to: "me" } },
    });
    if (incoming?.kind !== "message") throw new Error(`not a message: ${JSON.stringify(incoming)}`);
    return row(`user-${n}`, "user", incoming.message.text, { incoming, resend: body });
  };
  /// Eighteen turns; every third prompt (ticks 1, 4, 7, ...) is a message from review-router.
  const rows = Array.from({ length: 18 }, (_, index) => [
    index % 3 === 1
      ? fromSession(index + 1, "review-router")
      : row(`user-${index + 1}`, "user", `Reply with only the word ok and the number ${index + 1}.`),
    row(`answer-${index + 1}`, "assistant", `ok ${index + 1}\n\nA second paragraph so the turn has some height.`),
    row(`summary-${index + 1}`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();

  async function open(): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => {
      (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown);
    }, rows);
    await page.waitForSelector('[data-tick="7"][data-incoming]');
    return page;
  }

  test("at rest every tick shares one left x and one width, other sessions' messages included", async () => {
    const page = await open();
    const bars = await page.evaluate(() =>
      Array.from(document.querySelectorAll<HTMLElement>("[data-tick]")).map((tick) => {
        const bar = tick.querySelector<HTMLElement>(".acpmux-minimap__bar")!.getBoundingClientRect();
        return { incoming: tick.dataset.incoming !== undefined, left: bar.left, width: bar.width };
      }),
    );
    expect(bars.filter((bar) => bar.incoming).length).toBeGreaterThan(2);
    expect(bars.filter((bar) => !bar.incoming).length).toBeGreaterThan(2);
    expect(new Set(bars.map((bar) => bar.left)).size).toBe(1);
    expect(new Set(bars.map((bar) => bar.width)).size).toBe(1);
    await page.close();
  });

  test("the hover preview still names the sender of another session's message, and only there", async () => {
    const page = await open();
    const hover = async (index: number, words: string) => {
      const box = await page.evaluate((at) => {
        const rect = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
        return { x: rect.left + 8, y: rect.top + rect.height / 2 };
      }, index);
      await page.mouse.move(box.x, box.y);
      await page.waitForSelector(`[data-tick="${index}"][data-tone="active"]`);
      await page.waitForFunction(
        (text) => document.querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")?.textContent?.includes(text),
        words,
      );
      // The harness loads no string catalog, so the line reads its key; the name is the model's
      // (thread-rail-incoming-sender.test.ts).
      return page.evaluate(() => ({
        incoming: document.querySelector(".acpmux-minimap__card")?.hasAttribute("data-incoming"),
        from: document.querySelector(".acpmux-minimap__card .acpmux-minimap__from")?.textContent ?? null,
      }));
    };
    const other = await hover(7, "Step 8 landed");
    expect(other.incoming).toBe(true);
    expect(other.from).toBeTruthy();
    const own = await hover(8, "the number 9.");
    expect(own.incoming).toBe(false);
    expect(own.from).toBeNull();
    await page.close();
  });
});
