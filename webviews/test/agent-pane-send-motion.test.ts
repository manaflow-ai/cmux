// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-07 (ask-bc3f176943): "there's space that's given to the user's message, and then the
// user's prompt, like, fades in from the right and, like, grows to the left. And yeah, and then
// there's the, like, space that accounts for with the thinking for whatever seconds and the push-up
// and the prompt. Like, it's all just one unified motion." Then Leo, 2026-11-11: "that slow settle
// animation is just so bad. Like, just do it." The one motion's clock (the send step,
// MOTION_SEND_MS) is 0: a prompt sent from the latest row has its room, its bubble and the thinking
// row in place, whole, in the frame the composer empties, and the thread does not rise; no flight
// (sendMorph.ts), rise (followGlide.ts `sent`) or entrance (conversation.css SEND-ENTRANCE) plays
// on a clock above 0. Every frame from the send is read in the agent pane's dev entry, with the
// agent's answer held back as a real agent's is. The second case reads the bubble's own entrance
// (a prompt from another device, a send while scrolled up) through the gallery's `inplace` switch.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-motion.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";
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
                : target.matches("[data-send-morph-layer]")
                  ? "morph"
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

  /// Earlier turns, so the chat overflows and the send rises from the latest row; the agent then
  /// answers late, as a real one does: the thinking row is all that comes with the prompt.
  /// The thread's rise follows the follow-motion experiment (#37614): its default arms chase each
  /// move on a spring, and its eased arm is the glide this send clock drives (followGlide `sent`).
  /// The rise's clock is read in that arm; the bubble and thinking row take the send clock in every arm.
  /// `follow`: the follow-motion arm; the product's is `blocks`.
  const openTurns = async (page: Page, follow: string | undefined = "eased") => {
    if (follow)
      await page.addInitScript(
        (arm) => localStorage.setItem("cmux.experiments", JSON.stringify({ "follow-motion": arm })),
        follow,
      );
    await openPane(page);
    for (const line of ["first question", "second question", "third question"]) {
      await send(page, line);
      await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
    }
    // The last turn's end folds its work (turnEndFold.ts) and the rows glide on nothing else meanwhile:
    // the measured send comes once it has settled, as a reader's next prompt does.
    await page.waitForFunction(() => !document.querySelector(".acpmux-thread")?.hasAttribute("data-turn-end-folding"));
    await page.evaluate(() =>
      Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 }),
    );
  };

  /// Lands at once: no animation the send started (the thread's rise, the flight, the bubble's
  /// opening, the thinking row's fade) runs a clock above 0, and from the bubble's first frame the
  /// thread is not drawn back, the bubble is open and its text, its row and the thinking row are whole.
  const expectLanded = (frames: Frame[], clocks: Clock[], label: string) => {
    expect(MOTION_SEND_MS, "the scale's send step").toBe(0);
    for (const clock of clocks)
      expect(clock.duration, `${label}: the ${clock.target}'s clock (${JSON.stringify(clocks)})`).toBe(0);
    expect(frames.length, `${label}: the sent prompt was never drawn`).toBeGreaterThan(5);
    for (const frame of frames) {
      expect(frame.thread, `${label}: the thread is not drawn back at ${frame.at} ms`).toBeLessThan(0.5);
      expect(frame.clip, `${label}: the bubble is open at ${frame.at} ms`).toBeLessThan(0.05);
      expect(frame.text, `${label}: the text is whole at ${frame.at} ms`).toBeGreaterThan(0.99);
      expect(frame.row, `${label}: the prompt is whole at ${frame.at} ms`).toBeGreaterThan(0.99);
      // -1: no thinking row drawn in that frame.
      if (frame.thinking >= 0)
        expect(frame.thinking, `${label}: the thinking row is whole at ${frame.at} ms`).toBeGreaterThan(0.99);
    }
  };

  test("from the latest row, the composer's prompt is the bubble at once: nothing flies, rises or fades", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await openTurns(page);
      const line = "what else do you think would be good across the project";
      await watchSend(page, line);
      await send(page, line);
      const { frames, clocks } = await sendFrames(page);
      expectLanded(frames, clocks, "from the latest row");
      expect(
        clocks.some((entry) => entry.target === "morph"),
        "no copy of the composer's prompt moves into the bubble",
      ).toBe(false);
    } finally {
      await page.close();
    }
  });

  // The product's follow motion chases each move of the rows on a spring (followChase.ts): a send on
  // the 0 clock is in place in its own pass, with nothing left to chase (review of #41550, F1).
  test("with the default follow motion, the sent prompt and the thread are in place at once", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await openTurns(page, "blocks");
      const line = "what else do you think would be good across the project";
      await watchSend(page, line);
      await send(page, line);
      const { frames, clocks } = await sendFrames(page);
      expectLanded(frames, clocks, "default follow motion");
    } finally {
      await page.close();
    }
  });

  // System Reduce Motion fades arrivals; a sent prompt and its thinking row still take the send clock
  // (review of #41550, F2).
  test("with Reduce Motion, the sent prompt and its thinking row are whole at once, no fade", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 }, reducedMotion: "reduce" });
    try {
      await openTurns(page, "blocks");
      const line = "what else do you think would be good across the project";
      await watchSend(page, line);
      await send(page, line);
      const { frames, clocks } = await sendFrames(page);
      expectLanded(frames, clocks, "Reduce Motion");
    } finally {
      await page.close();
    }
  });

  test("a prompt's own entrance: room, bubble, thinking row and thread are in place at once", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await openTurns(page);
      // The bubble's own entrance, as a prompt from another device or one sent while scrolled up
      // draws it: the gallery's switch turns the composer's move off (sendMorph.ts).
      await page.evaluate(() => document.querySelector(".acpmux-shell")!.setAttribute("data-send-morph", "inplace"));
      const line = "what else do you think would be good across the project";
      await watchSend(page, line);
      await send(page, line);
      const { frames, clocks } = await sendFrames(page);
      expectLanded(frames, clocks, "its own entrance");
    } finally {
      await page.close();
    }
  });
});
