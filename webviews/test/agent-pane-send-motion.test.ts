// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-07 (ask-bc3f176943): "there's space that's given to the user's message, and then the
// user's prompt, like, fades in from the right and, like, grows to the left. And yeah, and then
// there's the, like, space that accounts for with the thinking for whatever seconds and the push-up
// and the prompt. Like, it's all just one unified motion." A prompt sent from the latest row: its
// room is laid out at once, and on one clock (the send motion, 180 ms on its settling curve) the
// thread rises into it, the bubble opens leftward from its right edge with its text fading in behind
// the edge, and the thinking row fades in. Every frame from the send is read in the agent pane's dev
// entry, with the agent's answer held back as a real agent's is.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-motion.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// One frame after the send: the bubble's clip from the left (% of its width), the opacity of its
/// text, of its row and of the thinking row, and how far the thread is drawn back (px).
type Frame = { at: number; clip: number; text: number; row: number; thinking: number; thread: number };
type Clock = { target: string; duration: number; easing: string };

await requireBrowserLane("agent-pane-send-motion.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("send motion", () => test("chromium", () => {}));
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

  const openPane = async (page: Page) => {
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const port = (pane!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').waitFor();
  };

  const send = async (page: Page, line: string) => {
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').click();
    await page.keyboard.type(line);
    await page.keyboard.press("Enter");
  };

  /// Reads every frame from now for `ms`, and the clocks of the animations the send started.
  const watchSend = (page: Page, text: string, ms = 1200) =>
    page.evaluate(
      ({ text, ms }) => {
        const frames: unknown[] = [];
        const clocks: unknown[] = [];
        Object.assign(window, { __sendMotion: { frames, clocks, done: false } });
        const start = performance.now();
        const seen = new Set<Animation>();
        // raf-read: the motion is the behavior; each frame is read as it is drawn.
        const tick = () => {
          const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((node) =>
            node.textContent?.includes(text),
          );
          const thinking = document.querySelector(".acpmux-thinking");
          const thread = document.querySelector<HTMLElement>(".acpmux-thread");
          for (const animation of document.getAnimations()) {
            if (seen.has(animation)) continue;
            seen.add(animation);
            const target = (animation.effect as KeyframeEffect | null)?.target as Element | null;
            const timing = animation.effect?.getComputedTiming();
            if (!target || !timing || !Number.isFinite(Number(timing.duration))) continue;
            const name =
              target === thread
                ? "thread"
                : target.matches(".cv-user__bubble")
                  ? "bubble"
                  : target.matches(".acpmux-thinking")
                    ? "thinking"
                    : "";
            if (name)
              clocks.push({
                target: name,
                duration: Number(timing.duration),
                // A CSS animation's curve is its element's animation-timing-function (its keyframes'),
                // a scripted one's is its timing's.
                easing:
                  "animationName" in animation
                    ? getComputedStyle(target).animationTimingFunction.split(/,(?![^(]*\))/)[0]!
                    : (animation.effect as KeyframeEffect).getTiming().easing,
              });
          }
          if (bubble) {
            const clip = /inset\([^)]*?\s(-?[\d.]+)%/.exec(getComputedStyle(bubble).clipPath);
            const text = bubble.firstElementChild ?? bubble;
            const row = bubble.closest(".acpmux-row__message-presentation") ?? bubble;
            frames.push({
              at: Math.round(performance.now() - start),
              clip: clip ? Number(clip[1]) : 0,
              text: Number(getComputedStyle(text).opacity),
              row: Number(getComputedStyle(row).opacity),
              thinking: thinking ? Number(getComputedStyle(thinking).opacity) : -1,
              thread: Number(/\S+\s+(-?[\d.]+)px/.exec(getComputedStyle(thread!).translate)?.[1] ?? 0),
            });
          }
          // raf-read: every frame of the motion (above).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __sendMotion: { done: boolean } }).__sendMotion.done = true;
        };
        requestAnimationFrame(tick);
      },
      { text, ms },
    );
  const sendFrames = async (page: Page) => {
    await page.waitForFunction(() => (window as unknown as { __sendMotion: { done: boolean } }).__sendMotion.done);
    return page.evaluate(
      () => (window as unknown as { __sendMotion: { frames: Frame[]; clocks: Clock[] } }).__sendMotion,
    );
  };

  // The thread's rise follows the follow-motion experiment (#37614): its default arms chase each
  // move on a spring, and its eased arm is the glide this send clock drives (followGlide `sent`).
  // The rise's clock is read in that arm; the bubble and thinking row take the send clock in every arm.
  test("a prompt sent from the latest row: room, bubble, thinking row and rise are one motion on one clock", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"follow-motion":"eased"}'));
      await openPane(page);
      // Earlier turns, so the chat overflows and the send rises from the latest row.
      for (const line of ["first question", "second question", "third question"]) {
        await send(page, line);
        await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
        await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
      }
      // The agent answers late, as a real one does: the thinking row is all that comes with the prompt.
      await page.evaluate(() =>
        Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 }),
      );
      const line = "what else do you think would be good across the project";
      await watchSend(page, line);
      await send(page, line);
      const { frames, clocks } = await sendFrames(page);
      expect(frames.length, "the sent prompt was never drawn").toBeGreaterThan(5);
      const [first, last] = [frames[0]!, frames.at(-1)!];

      // One clock: the thread's rise, the bubble's opening and the thinking row's fade all run the
      // send motion (180 ms, its settling curve).
      for (const target of ["thread", "bubble", "thinking"]) {
        const clock = clocks.find((entry) => entry.target === target);
        expect(clock, `${target}: no animation started with the send (${JSON.stringify(clocks)})`).toBeDefined();
        expect(clock!.duration, `${target}'s duration`).toBe(180);
        expect(clock!.easing.replace(/\s/g, ""), `${target}'s curve`).toBe("cubic-bezier(0.16,1,0.3,1)");
      }

      // Its first frame: the room is there and the thread is drawn back by it, the bubble is open only
      // at its right part with its text not yet in, and the thinking row has not faded in.
      expect(first.thread, "the thread starts drawn back by the new rows").toBeGreaterThan(40);
      expect(first.clip, "the bubble starts open only from its right edge").toBeGreaterThan(30);
      expect(first.text, "the text comes in behind the bubble's edge").toBeLessThan(0.05);
      expect(first.row, "the prompt fades in").toBeLessThan(0.5);
      expect(first.thinking, "the thinking row fades in with it").toBeLessThan(0.5);
      // It opens leftward without stepping back, and the thread only rises.
      for (let index = 1; index < frames.length; index += 1) {
        expect(frames[index]!.clip, `the bubble's edge at ${frames[index]!.at} ms`).toBeLessThanOrEqual(
          frames[index - 1]!.clip + 0.01,
        );
        expect(frames[index]!.thread, `the thread at ${frames[index]!.at} ms`).toBeLessThanOrEqual(
          frames[index - 1]!.thread + 0.01,
        );
      }
      // And it settles: open, in place, every part fully in.
      expect(last.clip).toBeLessThan(0.05);
      expect(last.thread).toBeLessThan(0.5);
      expect(last.text).toBeGreaterThan(0.99);
      expect(last.row).toBeGreaterThan(0.99);
      expect(last.thinking).toBeGreaterThan(0.99);
    } finally {
      await page.close();
    }
  });
});
