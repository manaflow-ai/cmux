import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-artifact-motion.test.ts", async () => {
  const REPLY = "Open the [right pane](https://example.com/native-pane) from this chat.";
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

  const settle = (page: Page) =>
    page.evaluate(async () => {
      await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
      for (let frame = 0; frame < 3; frame++) await window.cmuxPaintFrame();
    });

  const recordResize = async (page: Page, width: number) => {
    const before = await page.evaluate(() => {
      const current = document.querySelector<HTMLElement>("a[href='https://example.com/native-pane']")!;
      const rect = current.getBoundingClientRect();
      return { x: Number(rect.left.toFixed(2)), visible: rect.width > 0 && rect.height > 0, animations: 0 };
    });
    await page.setViewportSize({ width, height: 700 });
    return page.evaluate(async (initial) => {
      const frames: { x: number; visible: boolean; animations: number }[] = [];
      for (let index = 0; index < 120; index++) {
        await window.cmuxPaintFrame();
        const current = document.querySelector<HTMLElement>("a[href='https://example.com/native-pane']");
        const rect = current?.getBoundingClientRect() ?? new DOMRect();
        const scroll = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-stage > .acpmux-scroll");
        frames.push({
          x: Number(rect.left.toFixed(2)),
          visible:
            current !== null && rect.width > 0 && rect.height > 0 && getComputedStyle(current).visibility !== "hidden",
          animations: scroll?.getAnimations().length ?? 0,
        });
        if (frames.length >= 4 && frames.at(-1)!.x === frames.at(-2)!.x && frames.at(-2)!.x === frames.at(-3)!.x) break;
      }
      return [initial, ...frames];
    }, before);
  };

  const movementPhases = (frames: { x: number }[]) => {
    const deltas = frames.slice(1).map((frame, index) => frame.x - frames[index]!.x);
    const signs = deltas.filter((delta) => Math.abs(delta) >= 0.5).map((delta) => Math.sign(delta));
    return { signs, phases: signs.filter((sign, index) => index === 0 || sign !== signs[index - 1]).length };
  };

  test("a native link pane resize keeps the live transcript visible and moves once", async () => {
    const page = await pane!.open({ width: 1600, height: 700 });
    try {
      await page.evaluate(() => {
        const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
          .cmuxAcpmuxBridge;
        bridge.applyHeaderState({ inspector: true, version: 2 });
        document.addEventListener("click", (event) => {
          if ((event.target as Element | null)?.closest("a[href='https://example.com/native-pane']")) {
            event.preventDefault();
            (window as any).__nativeLinkClicked = true;
          }
        });
      });
      await inspectorPushAlways(page, false);
      const toggle = page.locator("button.acpmux-chat-inspector-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      if ((await page.locator("aside.acpmux-chat-inspector").count()) === 0) await toggle.click({ force: true });
      await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });
      await settle(page);
      const link = page.locator("a[href='https://example.com/native-pane']").first();
      await link.waitFor({ timeout: 10_000 });

      await link.click();
      await page.waitForFunction(() => (window as any).__nativeLinkClicked === true);
      console.log(
        "native link count after click",
        await page.locator("a[href='https://example.com/native-pane']").count(),
      );
      const opening = await recordResize(page, 1200);
      console.log(
        "native pane open text-column frames",
        opening.map((frame) => frame.x),
      );

      const closing = await recordResize(page, 1600);
      console.log(
        "native pane close text-column frames",
        closing.map((frame) => frame.x),
      );

      expect(opening.every((frame) => frame.visible)).toBe(true);
      expect(closing.every((frame) => frame.visible)).toBe(true);
      expect(opening.every((frame) => frame.animations === 0)).toBe(true);
      expect(closing.every((frame) => frame.animations === 0)).toBe(true);
      expect(movementPhases(opening).phases).toBe(1);
      expect(movementPhases(closing).phases).toBe(1);
    } finally {
      await page.close();
    }
  });
});
