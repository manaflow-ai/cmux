import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-artifact-motion.test.ts", async () => {
  const REPLY = "Here is the preview:\n\n```cmux-render\n<title>Motion probe</title><p>preview</p>\n```";
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
      await page.waitForFunction(
        () =>
          [...document.getAnimations()].every((animation) => {
            const end = animation.effect?.getComputedTiming().endTime;
            return end === Infinity || animation.playState !== "running";
          }),
        undefined,
        { timeout: 10_000 },
      );
      await page.evaluate(async () => {
        for (let frame = 0; frame < 3; frame++) await window.cmuxPaintFrame();
      });
      // The native preview split springs its pane width; animate the fixture's side item the same
      // way so the assertion catches a webview shift that starts after the pane has already moved.
      await page.addStyleTag({
        content: ".acpmux-artifact { flex-basis: 0 !important; transition: flex-basis 320ms ease-out !important; }",
      });
      const openPreview = page.getByRole("button", { name: "Open preview" });
      await openPreview.waitFor({ timeout: 10_000 });
      await page.evaluate(() => {
        const observer = new MutationObserver(() => {
          const artifact = document.querySelector<HTMLElement>(".acpmux-artifact");
          if (!artifact || artifact.dataset.motionProbe) return;
          artifact.dataset.motionProbe = "opening";
          artifact.style.setProperty("flex-basis", "clamp(320px, 46%, 760px)", "important");
          observer.disconnect();
        });
        observer.observe(document.querySelector(".acpmux-shell")!, { childList: true, subtree: true });
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
        Object.assign(window, {
          __artifactMotion: {
            frames,
            get done() {
              return done;
            },
          },
          __artifactMotionStop: stop,
        });
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
