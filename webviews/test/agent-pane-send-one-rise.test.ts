// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-06 (ask-cdaf603762): "when i sent a message to them i saw a double jump like it sent
// my message and scrolled things up... then went down... then went back up again? to account for the
// thinking? idk, it like accounted for it first, then snapped, then went back?" A prompt sent from the
// latest row rises once: from the send until the agent answers, the sent bubble only ever moves up
// the screen, in every follow-motion arm, however late the thinking row and the host's echo come.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-one-rise.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { followMotion } from "../src/agent-session/acpmux/conversation/followMotion.experiment";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One frame after the send: the sent bubble's top on screen (px) and whether the thinking row is drawn.
type Frame = { at: number; top: number; thinking: boolean };

await requireBrowserLane("agent-pane-send-one-rise.test.ts", async () => {
  setDefaultTimeout(240_000);
  /// The agent's echo of the prompt, its thinking and its answer all come this late, as from a busy host.
  const SLOW_PROMPT_MS = 2500;
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-one-rise: skipping (run `bunx playwright install chromium`)");
    describe.skip("send rises once", () => test("chromium", () => {}));
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

  const send = async (page: Page, line: string) => {
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').click();
    await page.keyboard.type(line);
    await page.keyboard.press("Enter");
  };

  const openTurns = async (page: Page, arm: string) => {
    await page.addInitScript((arm) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "follow-motion": arm }));
      Object.assign(window, {
        webkit: {
          messageHandlers: { agentSession: { standIn: true, postMessage: async () => ({ ok: true, value: null }) } },
        },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, arm);
    const port = (pane!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').waitFor();
    for (const line of ["first question", "second question", "third question", "fourth question"]) {
      await send(page, line);
      await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
    }
    await page.waitForFunction(() => !document.querySelector(".acpmux-thread")?.hasAttribute("data-turn-end-folding"));
    await page.evaluate(
      (slowMs) => Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: slowMs }),
      SLOW_PROMPT_MS,
    );
  };

  /// Every frame from the send for `ms`: where the sent bubble is drawn, past the agent's late echo.
  const watch = (page: Page, text: string, ms: number) =>
    page.evaluate(
      ({ text, ms }) => {
        const frames: unknown[] = [];
        Object.assign(window, { __oneRise: { frames, done: false } });
        const start = performance.now();
        // raf-read: the motion is the behavior; each frame is read as it is drawn.
        const tick = () => {
          const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((node) =>
            node.textContent?.includes(text),
          );
          if (bubble)
            frames.push({
              at: Math.round(performance.now() - start),
              top: Math.round(bubble.getBoundingClientRect().top * 10) / 10,
              thinking: !!document.querySelector(".acpmux-thinking"),
            });
          // raf-read: every frame of the motion (above).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __oneRise: { done: boolean } }).__oneRise.done = true;
        };
        requestAnimationFrame(tick);
      },
      { text, ms },
    );

  for (const arm of Object.keys(followMotion.arms)) {
    test(`${arm}: a send from the latest row rises once, with no drop back before the thinking row`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
      await openTurns(page, arm);
      const line = "fifth question, held by a slow agent";
      await watch(page, line, SLOW_PROMPT_MS + 2000);
      await send(page, line);
      await page.waitForFunction(() => (window as unknown as { __oneRise: { done: boolean } }).__oneRise.done);
      const frames = await page.evaluate(
        () => (window as unknown as { __oneRise: { frames: Frame[] } }).__oneRise.frames,
      );
      await page.close();
      expect(frames.length, "the sent prompt was never drawn").toBeGreaterThan(10);
      // The bubble never moves down the screen by more than a pixel: a drop is the "snapped" frame.
      const drops = frames.flatMap((frame, index) =>
        index > 0 && frame.top > frames[index - 1]!.top + 1 ? [{ from: frames[index - 1], to: frame }] : [],
      );
      expect(drops, JSON.stringify(frames)).toEqual([]);
    });
  }
});
