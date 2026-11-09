// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
// Leo, 2026-11-08 (ask-157340f908): "if you're not at the bottom, it goes, like, there's a little
// animation where it appears to jump over your composer and then tuck under it ... it kind of, like,
// waterfalls over the composer if you think of the composer as a bar, that they go, like, over and
// then under behind." A prompt sent while the transcript is scrolled up: the composer is empty from
// the first frame, and a small copy of what was sent (its text as a pill, its chips' thumbnails)
// rises from the composer over its top edge and drops behind the bar, on the send clock
// (conversation/sendTuck.ts). Sent from the latest row, or with motion off, nothing tucks: the
// composer just clears. Every frame from the send is read in the agent pane's dev entry.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-tuck.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { left: number; top: number; width: number; height: number };
/// One frame from the send: the time since the send's key went down, what the composer still holds,
/// the composer's box, the drawn copy (the layer whose copy is drawn, its box, and whether the
/// composer draws at its center: it is behind the bar there), every copy still on the page, and
/// whether the sent prompt's bubble shows in the transcript above the composer.
type Frame = {
  at: number;
  text: string;
  chips: number;
  composer: Box;
  ghost?: { layer: string; box: Box; behind: boolean };
  ghosts: number;
  shown: boolean;
};

await requireBrowserLane("agent-pane-send-tuck.test.ts", async () => {
  const SENT = "tuck this prompt under the composer";
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-tuck: skipping (run `bunx playwright install chromium`)");
    describe.skip("send tuck", () => test("chromium", () => {}));
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

  const port = () => (pane!.httpServer!.address() as { port: number }).port;
  const prompt = (page: Page) => page.locator('.acpmux-composer-prompt [contenteditable="true"]');

  /// The agent pane's dev entry with its in-page mock agent, three exchanges in, so the chat overflows.
  const openChat = async (page: Page) => {
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    await page.goto(`http://127.0.0.1:${port()}/`);
    await prompt(page).waitFor();
    for (const line of ["first question", "second question", "third question", "fourth question"]) {
      await prompt(page).click();
      await page.keyboard.type(line);
      await page.keyboard.press("Enter");
      await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
    }
    expect(
      await page.locator(".acpmux-scroll").evaluate((scroll) => scroll.scrollHeight > scroll.clientHeight + 200),
      "the chat overflows",
    ).toBe(true);
    // The agent answers late, as a real one does.
    await page.evaluate(() =>
      Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 }),
    );
  };

  /// The reader scrolls the transcript up with the wheel, away from its latest row.
  const scrollUp = async (page: Page) => {
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 80);
    for (let step = 0; step < 6; step += 1) await page.mouse.wheel(0, -400);
    await page.waitForFunction(() => {
      const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop > 300;
    });
    // The view settles where the reader left it: its offset holds for ten painted frames.
    await page.evaluate(async () => {
      const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let still = 0;
      let last = scroll.scrollTop;
      while (still < 10) {
        // raf-read: a settle check, one read per painted frame.
        await new Promise(requestAnimationFrame);
        still = scroll.scrollTop === last ? still + 1 : 0;
        last = scroll.scrollTop;
      }
    });
  };

  /// A screenshot pasted into the composer beside typed text, ready to send.
  const fillComposer = async (page: Page) => {
    await prompt(page).click();
    await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 800;
      canvas.height = 500;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      document
        .querySelector('.acpmux-composer-prompt [contenteditable="true"]')!
        .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.waitForFunction(() => {
      const image = document.querySelector<HTMLImageElement>(".acpmux-composer .acpmux-attachment img");
      return !!image && image.complete && image.naturalWidth > 0;
    });
    await page.keyboard.type(` ${SENT}`);
  };

  /// Reads every frame from the send's key for `ms`.
  const watchSend = (page: Page, ms = 900) =>
    page.evaluate(
      ({ sent, ms }) => {
        const state = { frames: [] as unknown[], done: false };
        (window as unknown as { __tuck: typeof state }).__tuck = state;
        const rect = (element: Element): Box => {
          const { left, top, width, height } = element.getBoundingClientRect();
          return { left, top, width, height };
        };
        let start = -1;
        window.addEventListener(
          "keydown",
          (event) => {
            if (event.key === "Enter" && start < 0) start = performance.now();
          },
          { capture: true },
        );
        // Each frame is read once it is drawn: a task posted from the frame's callback runs after its
        // layout, its resize observers and its paint, so the read is what the frame showed.
        const read = () => {
          if (state.done) return;
          {
            const composer = document.querySelector(".acpmux-composer-box")!;
            const composerBox = rect(composer);
            const ghosts = [...document.querySelectorAll<HTMLElement>("[data-send-tuck-ghost]")];
            const drawn = ghosts.find((ghost) => Number(getComputedStyle(ghost).opacity) > 0.5);
            let ghost: { layer: string; box: Box; behind: boolean } | undefined;
            if (drawn) {
              const box = rect(drawn);
              // The copy takes the pointer for this one read: what draws at its center is then the
              // copy where it is drawn, and the composer where the bar covers or clips it.
              drawn.style.pointerEvents = "auto";
              const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
              drawn.style.pointerEvents = "";
              ghost = {
                layer: drawn.getAttribute("data-send-tuck-ghost") ?? "",
                box,
                behind: !!hit && !!composer.closest(".acpmux-composer")?.contains(hit),
              };
            }
            const scroll = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
            const shown = [...document.querySelectorAll(".cv-user__bubble")].some((bubble) => {
              if (!bubble.textContent?.includes(sent)) return false;
              const box = bubble.getBoundingClientRect();
              return box.bottom > scroll.top && box.top < composerBox.top && box.height > 0;
            });
            state.frames.push({
              at: Math.round(performance.now() - start),
              text: (document.querySelector(".acpmux-composer-prompt [contenteditable]")?.textContent ?? "").trim(),
              chips: document.querySelectorAll(".acpmux-composer .acpmux-attachment").length,
              composer: composerBox,
              ghost,
              ghosts: ghosts.length,
              shown,
            });
            if (performance.now() - start >= ms) state.done = true;
          }
        };
        const after = new MessageChannel();
        after.port1.onmessage = read;
        // raf-read: the send is the behavior; each frame is read as that frame is drawn (above).
        const tick = () => {
          if (state.done) return;
          if (start >= 0) after.port2.postMessage(null);
          // raf-read: every frame of the send (above).
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      },
      { sent: SENT, ms },
    );
  const sendFrames = async (page: Page) => {
    await page.waitForFunction(() => (window as unknown as { __tuck: { done: boolean } }).__tuck.done);
    return page.evaluate(() => (window as unknown as { __tuck: { frames: Frame[] } }).__tuck.frames);
  };

  /// The send clock (`--agent-motion-send`) on the page.
  const sendClock = (page: Page) =>
    page.evaluate(() => {
      const value = getComputedStyle(document.documentElement).getPropertyValue("--agent-motion-send").trim();
      const amount = Number.parseFloat(value);
      return value.endsWith("ms") ? amount : value.endsWith("s") ? amount * 1000 : MOTION_SEND_MS;
    });

  /// The reader's "Scroll to bottom when I send" choice, as the composer's menu sets it.
  const setRide = (page: Page, rides: boolean) =>
    page.evaluate(async (rides) => {
      // The pane's own module (the dev server serves the pane's folder at /).
      const settings = (await import(/* @vite-ignore */ `${location.origin}/composerSettings.ts`)) as {
        setScrollToBottomOnSend(value: boolean): void;
      };
      settings.setScrollToBottomOnSend(rides);
    }, rides);

  /// The composer is empty from the first frame after the send, and stays so.
  const expectCleared = (frames: Frame[], label: string) => {
    expect(frames.length, `${label}: no frame was read`).toBeGreaterThan(5);
    for (const frame of frames) {
      expect(frame.text, `${label}: the composer's text at ${frame.at} ms`).toBe("");
      expect(frame.chips, `${label}: the composer's chips at ${frame.at} ms`).toBe(0);
    }
  };

  /// Over, then under: the copy starts at the composer, rises over its top edge, ends behind the bar
  /// (the composer draws at its center), and is gone by the end of the send clock and a frame.
  const expectTuck = (frames: Frame[], clock: number, label: string) => {
    expectCleared(frames, label);
    const drawn = frames.filter((frame) => frame.ghost);
    expect(drawn.length, `${label}: no copy of the prompt was drawn`).toBeGreaterThan(3);
    const first = drawn[0]!;
    expect(first, `${label}: the copy is drawn from the send's first frame`).toBe(frames[0]!);
    const { box: start } = first.ghost!;
    const composer = first.composer;
    const middle = start.top + start.height / 2;
    expect(middle, `${label}: the copy starts at the composer`).toBeGreaterThan(composer.top);
    expect(middle, `${label}: the copy starts at the composer`).toBeLessThan(composer.top + composer.height);
    const highest = Math.min(...drawn.map((frame) => frame.ghost!.box.top));
    expect(highest, `${label}: the copy rises over the composer's top edge`).toBeLessThan(composer.top - 4);
    const apex = drawn.findIndex((frame) => frame.ghost!.box.top === highest);
    // Over the bar on its way up, behind it on its way down.
    expect(first.ghost!.layer, `${label}: it rises over the composer`).toBe("over");
    expect(first.ghost!.behind, `${label}: it is drawn over the composer as it lifts`).toBe(false);
    const last = drawn.at(-1)!;
    expect(last.ghost!.layer, `${label}: it falls behind the composer`).toBe("under");
    expect(last.ghost!.behind, `${label}: the bar covers it at the end (${JSON.stringify(last)})`).toBe(true);
    expect(last.ghost!.box.top + last.ghost!.box.height / 2).toBeGreaterThan(last.composer.top);
    expect(apex, `${label}: it falls after its rise`).toBeLessThan(drawn.length - 1);
    // Gone by the end of the send clock and a frame (or two, for a busy runner).
    const gone = frames.find((frame) => frame.at > first.at && frame.ghosts === 0);
    expect(gone, `${label}: the copies were never removed`).toBeDefined();
    expect(gone!.at - first.at, `${label}: the copies were removed late`).toBeLessThan(clock + 60);
    for (const frame of frames.filter((frame) => frame.at > gone!.at))
      expect(frame.ghosts, `${label}: a copy came back at ${frame.at} ms`).toBe(0);
  };

  test("scrolled up, the view kept: the sent prompt waterfalls over the composer and tucks behind it", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await setRide(page, false);
      await scrollUp(page);
      await fillComposer(page);
      const clock = await sendClock(page);
      await watchSend(page);
      await page.keyboard.press("Enter");
      const frames = await sendFrames(page);
      expectTuck(frames, clock, "kept view");
      // Nothing new appears in the transcript the reader looks at while it tucks.
      for (const frame of frames)
        expect(frame.shown, `the sent prompt shows in the transcript at ${frame.at} ms`).toBe(false);
      // The view stayed where the reader was; the transcript has it at its latest row when they go down.
      const transcript = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(transcript.x + transcript.width / 2, transcript.y + 80);
      for (let step = 0; step < 12; step += 1) await page.mouse.wheel(0, 600);
      await page.locator(".cv-user__bubble", { hasText: SENT }).waitFor();
    } finally {
      await page.close();
    }
  });

  test("scrolled up, the view riding to the latest row (the default): the prompt tucks all the same", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await scrollUp(page);
      await fillComposer(page);
      const clock = await sendClock(page);
      await watchSend(page);
      await page.keyboard.press("Enter");
      expectTuck(await sendFrames(page), clock, "riding view");
    } finally {
      await page.close();
    }
  });

  test("sent from the latest row nothing tucks: the composer just clears", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await fillComposer(page);
      await watchSend(page, 500);
      await page.keyboard.press("Enter");
      const frames = await sendFrames(page);
      expectCleared(frames, "at the latest row");
      for (const frame of frames) expect(frame.ghosts, `a copy at ${frame.at} ms`).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("with motion off nothing tucks, scrolled up or not", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
      await scrollUp(page);
      await fillComposer(page);
      await watchSend(page, 500);
      await page.keyboard.press("Enter");
      const frames = await sendFrames(page);
      expectCleared(frames, "motion off");
      for (const frame of frames) expect(frame.ghosts, `a copy at ${frame.at} ms`).toBe(0);
    } finally {
      await page.close();
    }
  });
});
