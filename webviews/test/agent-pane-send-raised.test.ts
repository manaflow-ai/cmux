// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-11 (ask-e237b0d178): "when there's a composer thing raised then it gets sent ... ok
// the fact that shit is animated up... do we even want stuff to push up vs just simple... covering
// stuff? ... if we can get it fast, MAYBE ... but if you look at the tnimation for when things get
// sent: it's not good". A send lands at once (#42669: MOTION_SEND_MS is 0): a six-line draft (the
// composer raised to its tallest) sent from the latest row draws its bubble at its resting place in
// the first frame it is drawn, as a one-line prompt does, and no row moves after it. On base the room
// the send keeps under its prompt was read as the composer's lift for one frame, and every row drew
// 12 px low before it jumped up (VirtualTranscript `lift`).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-raised.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One frame from the send: the sent bubble's top and the thread's (the rows' drawn offset).
type Frame = { at: number; top?: number; thread?: number };

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
          const thread = document.querySelector<HTMLElement>(".acpmux-thread");
          frames.push({
            at: performance.now() - start,
            top: bubble ? bubble.getBoundingClientRect().top : undefined,
            thread: thread ? thread.offsetTop : undefined,
          });
          // raf-read: every frame of the send (below).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __raised: { done: boolean } }).__raised.done = true;
        };
        // raf-read: the send is the behavior; each frame is read as that frame is drawn.
        requestAnimationFrame(tick);
      },
      { sent, ms },
    );

  test("a six-line draft sent from the latest row lands in place in its first frame, and nothing moves after", async () => {
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
      const report = placed
        .slice(0, 12)
        .map((frame) => `${Math.round(frame.at)}:${Math.round(frame.top!)}/${frame.thread}`)
        .join(" ");
      // The bubble is drawn where it rests from its first frame: no jump a frame later.
      for (const frame of placed) expect(Math.abs(frame.top! - rest), report).toBeLessThan(1);
      // The rows are never drawn down from their places (a lift only draws them up, for a raised card).
      for (const frame of placed) expect(frame.thread ?? 0, report).toBeLessThanOrEqual(0);
    } finally {
      await page.close();
    }
  });
});
