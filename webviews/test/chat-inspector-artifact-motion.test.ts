import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { mkdir, writeFile } from "node:fs/promises";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-artifact-motion.test.ts", async () => {
  const URL = "https://example.com/native-pane";
  const LINK = `.acpmux-scroll a[href='${URL}']`;
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
              update: {
                sessionUpdate: "agent_message_chunk",
                content: { type: "text", text: `Open the [right pane](${URL}) from this chat.` },
              },
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

  type Frame = {
    x: number;
    visible: boolean;
    sameNode: boolean;
    animations: number;
    width: number;
  };
  type Probe = Window & { motionFrames: Frame[]; motionDone: Promise<void> };
  // Install before the click/resize, so no first painted frame is lost to a protocol round trip.
  const startRecording = (page: Page, targetWidth: number) =>
    page.evaluate(
      ({ link, targetWidth }) => {
        const anchor = document.querySelector<HTMLElement>(link)!;
        const column = anchor.closest("p")!;
        const text = document.createRange();
        text.selectNodeContents(column);
        const scroll = anchor.closest<HTMLElement>(".acpmux-scroll")!;
        const frames: Frame[] = [];
        const read = () => {
          const rect = text.getBoundingClientRect();
          let visible = rect.width > 0 && rect.height > 0 && column.isConnected;
          for (let node: HTMLElement | null = column; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            visible &&=
              style.visibility !== "hidden" &&
              style.display !== "none" &&
              Number(style.opacity) > 0;
          }
          return {
            x: Number(rect.left.toFixed(2)),
            visible,
            sameNode: document.querySelector(link) === anchor,
            animations: scroll.getAnimations().length,
            width: window.innerWidth,
          };
        };
        frames.push(read());
        const probe = window as unknown as Probe;
        probe.motionFrames = frames;
        probe.motionDone = new Promise<void>((resolve) => {
          let still = 0;
          // Eight settled painted frames with no remaining shift animation, or 120 frames total.
          window.cmuxAfterPaint(() => {
            const next = read();
            still =
              next.x === frames.at(-1)!.x && next.width === targetWidth && next.animations === 0
                ? still + 1
                : 0;
            frames.push(next);
            if (still < 8 && frames.length < 120) return true;
            resolve();
            return false;
          });
        });
      },
      { link: LINK, targetWidth },
    );
  const finishRecording = (page: Page) =>
    page.evaluate(async () => {
      const probe = window as unknown as Probe;
      await probe.motionDone;
      return probe.motionFrames;
    });

  // A stop followed by a move is a new phase even if both moves have the same direction.
  const movement = (xs: number[]) => {
    let phases = 0,
      moving = false,
      direction = 0,
      reversed = false;
    for (let index = 1; index < xs.length; index++) {
      const delta = xs[index]! - xs[index - 1]!;
      const nextMoving = Math.abs(delta) >= 0.5;
      if (nextMoving) {
        if (!moving) phases++;
        if (direction && direction !== Math.sign(delta)) reversed = true;
        direction = Math.sign(delta);
      }
      moving = nextMoving;
    }
    return { phases, reversed };
  };

  test("motion oracle rejects no movement, reversal, and a same-direction restart", () => {
    expect(movement([0, 0, 0]).phases).toBe(0);
    expect(movement([0, 10, 10, 20]).phases).toBe(2);
    expect(movement([0, 10, 5]).reversed).toBe(true);
    expect(movement([0, 0, 10, 20, 20])).toEqual({ phases: 1, reversed: false });
  });

  test("a native link pane resize keeps the transcript mounted and moves its text once", async () => {
    const page = await pane!.open({ width: 1600, height: 700 });
    const evidence = process.env.CMUX_PANE_MOTION_EVIDENCE;
    const recording = evidence ? await page.context().newCDPSession(page) : undefined;
    const images: Promise<unknown>[] = [];
    let imageIndex = 0;
    if (evidence) await mkdir(evidence, { recursive: true });
    try {
      await page.evaluate(() => {
        const bridge = (
          window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
        ).cmuxAcpmuxBridge;
        bridge.applyHeaderState({ inspector: true, version: 2 });
      });
      await inspectorPushAlways(page, false);
      const toggle = page.locator("button.acpmux-chat-inspector-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      if ((await page.locator("aside.acpmux-chat-inspector").count()) === 0)
        await toggle.click({ force: true });
      await page
        .locator('aside.acpmux-chat-inspector[data-presence="shown"]')
        .waitFor({ timeout: 10_000 });
      await page.evaluate(async () => {
        await Promise.all(
          document.getAnimations().map((animation) => animation.finished.catch(() => undefined)),
        );
        for (let frame = 0; frame < 3; frame++) await window.cmuxPaintFrame();
      });
      // UrlChip emits a real navigation; native AgentPaneNavigation cancels it and opens a
      // browser beside the chat. Intercept at that boundary, not at the click handler.
      if (recording) {
        recording.on("Page.screencastFrame", ({ data, sessionId }) => {
          if (imageIndex < 120)
            images.push(
              writeFile(
                `${evidence}/frame-${String(imageIndex++).padStart(3, "0")}.png`,
                Buffer.from(data, "base64"),
              ),
            );
          void recording.send("Page.screencastFrameAck", { sessionId }).catch(() => undefined);
        });
        await recording.send("Page.startScreencast", { format: "png", everyNthFrame: 1 });
      }
      // The route is the native pane host seam: WebKit hands the navigation to the host, which
      // cancels the page navigation and resizes the live agent pane before the next paint.
      let nativeOpened = "";
      let resolveNativeOpen!: () => void;
      const nativeOpen = new Promise<void>((resolve) => {
        resolveNativeOpen = resolve;
      });
      await page.route(URL, async (route) => {
        if (!route.request().isNavigationRequest()) return route.continue();
        nativeOpened = route.request().url();
        resolveNativeOpen();
        // The native host consumes the navigation; fulfilling keeps the fake page alive while
        // the host applies the pane resize below.
        await route.fulfill({ status: 204, body: "" });
      });
      await startRecording(page, 1200);
      await page.locator(LINK).click({ noWaitAfter: true });
      await nativeOpen;
      expect(nativeOpened).toBe(URL);
      // The native host changes the live shell width; ResizeObserver/flushSync installs the
      // handoff marker before the first painted frame at that width.
      const nativeResize = async (width: number) => {
        await page.setViewportSize({ width, height: 700 });
        await page.waitForFunction(
          () =>
            document.querySelector<HTMLElement>(".acpmux-shell")?.dataset.inspectorChatResizing ===
            "true",
          undefined,
          { timeout: 10_000 },
        );
      };
      // The fake native host applies the pane's final viewport after it accepts the link.
      await nativeResize(1200);
      const opening = await finishRecording(page);

      await startRecording(page, 1600);
      await nativeResize(1600);
      const closing = await finishRecording(page);
      console.log(
        "native pane close text-column frames",
        closing.map((frame) => frame.x),
      );
      if (evidence)
        await writeFile(`${evidence}/trace.json`, JSON.stringify({ opening, closing }, null, 2));
      for (const [name, frames] of [
        ["open", opening],
        ["close", closing],
      ] as const) {
        console.log(
          `native pane ${name} text-column frames`,
          frames.map((frame) => frame.x),
        );
        expect(frames.every((frame) => frame.visible && frame.sameNode)).toBe(true);
        expect(frames.every((frame) => frame.animations === 0)).toBe(true);
        expect(movement(frames.map((frame) => frame.x))).toEqual({ phases: 1, reversed: false });
        const settled = frames.at(-1)!;
        const firstFinalWidth = frames.find(
          (frame) => frame.width === (name === "open" ? 1200 : 1600),
        );
        expect(firstFinalWidth, `${name} has no painted target-width frame`).toBeDefined();
        expect(firstFinalWidth!.x, `${name} landed one frame late`).toBe(settled.x);
      }
      expect(
        await page.locator(".acpmux-shell").getAttribute("data-inspector-chat-resizing"),
      ).toBeNull();
    } finally {
      if (recording) {
        await recording.send("Page.stopScreencast");
        await recording.detach();
        await Promise.all(images);
      }
      await page.close();
    }
  });

  test("hiding during the native resize handoff clears its transition marker", async () => {
    const page = await pane!.open({ width: 1600, height: 700 });
    try {
      await page.evaluate(() => {
        const bridge = (
          window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
        ).cmuxAcpmuxBridge;
        bridge.applyHeaderState({ inspector: true, version: 2 });
      });
      await inspectorPushAlways(page, false);
      const toggle = page.locator("button.acpmux-chat-inspector-toggle");
      await toggle.waitFor({ timeout: 10_000 });
      if ((await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').count()) === 0)
        await toggle.click({ force: true });
      await page
        .locator('aside.acpmux-chat-inspector[data-presence="shown"]')
        .waitFor({ timeout: 10_000 });

      // This is the state left by the native resize handoff before its scheduled RAF. Hiding the
      // inspector must clear it immediately; otherwise the next open keeps transitions disabled.
      await page.evaluate(() => {
        const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
        shell.dataset.inspectorChatResizing = "true";
        (
          document.querySelector("button.acpmux-chat-inspector-toggle") as HTMLButtonElement
        ).click();
      });
      await page.waitForFunction(() => {
        const presence = document
          .querySelector("aside.acpmux-chat-inspector")
          ?.getAttribute("data-presence");
        return !presence || presence === "hidden";
      });
      expect(
        await page.locator(".acpmux-shell").getAttribute("data-inspector-chat-resizing"),
      ).toBeNull();
    } finally {
      await page.close();
    }
  });
});
