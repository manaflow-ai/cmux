// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-11 (ask-e237b0d178): "when there's a composer thing raised then it gets sent ... if we
// can get it fast, MAYBE ... but if you look at the tnimation for when things get sent: it's not
// good". A six-line draft (the composer raised to its tallest) sent from the latest row: the thread
// rises into the sent prompt on the send motion's clock, as a one-line prompt does, instead of the
// arrival step's 320 ms; the copy of the words that flies to the bubble has the card's glass under it
// from the first frame, never bare words over the transcript; and the emptied composer draws no
// placeholder under the flying words.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-raised.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One frame from the send: the sent bubble's top, and while the copies fly, the glass copy's and the
/// words copy's opacity and whether the composer's placeholder is drawn.
type Frame = { at: number; top?: number; glass?: number; words?: number; placeholder: boolean };

await requireBrowserLane("agent-pane-send-raised.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-raised: skipping (run `bunx playwright install chromium`)");
    describe.skip("raised send", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let pane: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await pane.listen();
    await warmViteServer(pane, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const field = '.acpmux-composer-prompt [contenteditable="true"]';

  const openChat = async (page: Page) => {
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const port = (pane!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(field).waitFor();
    for (const line of ["first question", "second question", "third question", "fourth question"]) {
      await page.locator(field).click();
      await page.keyboard.type(line);
      await page.keyboard.press("Enter");
      await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
    }
    // The agent answers late, as a real one does: the send's own motion plays alone.
    await page.evaluate(() =>
      Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 }),
    );
  };

  /// Reads every frame from now for `ms`.
  const watch = (page: Page, sent: string, ms = 1000) =>
    page.evaluate(
      ({ sent, ms }) => {
        const frames: unknown[] = [];
        Object.assign(window, { __raised: { frames, done: false } });
        const start = performance.now();
        const tick = () => {
          const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find((node) =>
            node.textContent?.includes(sent),
          );
          const ghost = (kind: string) => {
            const node = document.querySelector<HTMLElement>(`[data-send-morph-ghost="${kind}"]`);
            return node ? Number(getComputedStyle(node).opacity) : undefined;
          };
          const placeholder = document.querySelector<HTMLElement>(".acpmux-composer .acpmux-md-placeholder");
          frames.push({
            at: performance.now() - start,
            top: bubble ? bubble.getBoundingClientRect().top : undefined,
            glass: ghost("bubble"),
            words: ghost("text"),
            placeholder:
              !!placeholder &&
              !placeholder.hidden &&
              getComputedStyle(placeholder).visibility !== "hidden" &&
              placeholder.getClientRects().length > 0,
          });
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __raised: { done: boolean } }).__raised.done = true;
        };
        requestAnimationFrame(tick);
      },
      { sent, ms },
    );

  test("a six-line draft sent from the latest row rises on the send's clock, its copy on its card", async () => {
    const page = await browser!.newPage({ viewport: { width: 720, height: 640 } });
    try {
      await openChat(page);
      await page.locator(field).click();
      for (let line = 1; line <= 6; line += 1) {
        await page.keyboard.type(`line ${line} of a longer prompt that the reader wrote`);
        if (line < 6) await page.keyboard.press("Shift+Enter");
      }
      // The composer is raised: taller than its resting card by several lines.
      const card = await page.locator(".acpmux-composer-box").evaluate((node) => node.getBoundingClientRect().height);
      expect(card).toBeGreaterThan(120);
      await watch(page, "line 6 of a longer prompt");
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => (window as unknown as { __raised: { done: boolean } }).__raised.done);
      const frames = (await page.evaluate(
        () => (window as unknown as { __raised: { frames: Frame[] } }).__raised.frames,
      )) as Frame[];
      const placed = frames.filter((frame) => frame.top !== undefined);
      expect(placed.length).toBeGreaterThan(10);
      const rest = placed.at(-1)!.top!;
      // The bubble moves only up, and rests within the send's clock (and two 60 Hz frames) of the
      // frame it first drew in. On the arrival step it rose for 320 ms.
      const first = placed[0]!.at;
      const settled = placed.find((frame, index) =>
        placed.slice(index).every((later) => Math.abs(later.top! - rest) < 1),
      );
      const report = placed.map((frame) => `${Math.round(frame.at - first)}:${Math.round(frame.top!)}`).join(" ");
      expect(settled, report).toBeDefined();
      expect(settled!.at - first, report).toBeLessThanOrEqual(MOTION_SEND_MS + 40);
      for (let index = 1; index < placed.length; index += 1)
        expect(placed[index]!.top!, report).toBeLessThanOrEqual(placed[index - 1]!.top! + 0.5);
      // While the words' copy is drawn, so is the card's glass under it, from the first frame.
      const flying = frames.filter((frame) => (frame.words ?? 0) > 0.05);
      expect(flying.length).toBeGreaterThan(0);
      for (const frame of flying) expect(frame.glass ?? 0, `${Math.round(frame.at)} ms`).toBeGreaterThan(0.95);
      // The emptied composer draws no placeholder under the flying words.
      for (const frame of flying) expect(frame.placeholder, `${Math.round(frame.at)} ms`).toBe(false);
    } finally {
      await page.close();
    }
  });
});
