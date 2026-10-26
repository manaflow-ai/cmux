import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

const REPLY = "Here is the preview:\n\n```cmux-render\n<title>Motion probe</title><p>preview</p>\n```";

await requireBrowserLane("chat-inspector-artifact-motion.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, {
      turns: 1,
      running: false,
      extra: [
        [
          "in",
          "agent_message_chunk",
          {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
            },
          },
        ],
        ["mux", "turn_result", { status: "completed" }],
      ],
    });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  test("opening a preview while Session Info is open moves the transcript once", async () => {
    const page = await pane!.open({ width: 1200, height: 700 });
    try {
      await page.evaluate(() => {
        const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
          .cmuxAcpmuxBridge;
        bridge.applyHeaderState({ inspector: true, version: 2 });
      });
      await inspectorPushAlways(page, false);
      const toggle = page.locator("button.acpmux-chat-inspector-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      if ((await page.locator("aside.acpmux-chat-inspector").count()) === 0) await toggle.click({ force: true });
      await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });
      const openPreview = page.getByRole("button", { name: "Open preview" });
      await openPreview.waitFor({ timeout: 10_000 });
      await page.evaluate(() => {
        const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const frames: number[] = [Number(scroll.getBoundingClientRect().left.toFixed(2))];
        let done = false;
        const stop = window.cmuxAfterPaint(() => {
          const scroll = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroll) return true;
          frames.push(Number(scroll.getBoundingClientRect().left.toFixed(2)));
          const active = [...document.getAnimations()].some((animation) => {
            const end = animation.effect?.getComputedTiming().endTime;
            return end !== Infinity && animation.playState === "running";
          });
          if (document.querySelector(".acpmux-artifact") && !active && frames.length >= 4) {
            done = true;
            return false;
          }
          return frames.length < 240;
        });
        Object.assign(window, { __artifactMotion: { frames, get done() { return done; } }, __artifactMotionStop: stop });
      });
      await openPreview.click();
      await page.waitForFunction(() => (window as any).__artifactMotion?.done === true, undefined, { timeout: 20_000 });
      const frames = await page.evaluate(() => (window as any).__artifactMotion.frames as number[]);
      console.log("artifact motion frames", frames);
      const final = frames.at(-1)!;
      const direction = Math.sign(final - frames[0]!);
      const deltas = frames.slice(1).map((x, index) => x - frames[index]!);
      expect({
        frames,
        monotonic: deltas.every((delta) => Math.abs(delta) < 0.5 || Math.sign(delta) === direction),
        final,
      }).toEqual({ frames, monotonic: true, final });
    } finally {
      await page.close();
    }
  });
});
