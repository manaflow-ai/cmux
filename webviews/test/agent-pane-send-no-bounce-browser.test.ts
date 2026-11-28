// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A send moves the transcript once, one way (Leo, 2026-11-22: "the chat transcript above doesn't
// quite smoothly account for things." / "it goes up and then it goes down" / "esp for long
// messages"). From the frame Enter is pressed until the chat is still, the rows above the prompt
// move in one direction only (up, as the prompt lands under them), never up and then back down or
// down and then up; so does the scroller's offset.
//
// Sends of 1, 10 and 60 lines, from the latest row and scrolled 1200 px up, with the chat idle and with
// a turn running (the prompt queues behind it). Every painted frame (support/paintedFrames.ts) records the scroller's
// scrollTop, the bottom of the last row, the top of the row that was last before the send (it is
// above the prompt throughout) and the composer card's top and height. A send fails when that row's
// screen position moves both ways by more than STILL_PX (the offset's directions are reported beside
// it); each send's trace prints as one `send-no-bounce` JSON line.
//
// The pane's dev entry and a stand-in acpmux (support/papercutChat.ts), 40 finished turns. Real
// Chromium and WebKit; CI fails the file when one cannot launch (requireBrowserLane). Locally (never on
// cosmic-gray): CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-no-bounce-browser.test.ts
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_EDITOR, MAIN_DOCK } from "../src/agent-session/acpmux/composerSelectors";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

type Frame = {
  t: number;
  scrollTop: number;
  last: number;
  anchor: number | null;
  card: number;
  cardH: number;
  rows: number;
};
declare global {
  interface Window {
    __sendTrace?: { frames: Frame[]; stop?: () => void };
  }
}

/// A move under this (px) between two frames is rounding, not motion.
const STILL_PX = 0.5;

/// The directions a series moves in over the trace: the sum of its moves up and down.
function directions(values: number[]): { up: number; down: number } {
  let up = 0;
  let down = 0;
  // Moves are summed between frames that changed by more than STILL_PX from the last counted value, so
  // subpixel drift never adds up into a direction.
  let at = values[0];
  for (const value of values.slice(1)) {
    if (at === undefined) {
      at = value;
      continue;
    }
    const delta = value - at;
    if (Math.abs(delta) <= STILL_PX) continue;
    if (delta < 0) up += -delta;
    else down += delta;
    at = value;
  }
  return { up: Math.round(up * 10) / 10, down: Math.round(down * 10) / 10 };
}

await requireBrowserLane("agent-pane-send-no-bounce-browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`send-no-bounce: ${engine[0]} did not launch`);
      console.warn(`send-no-bounce: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("send no bounce", () => test("browsers", () => {}));
    return;
  }
  const browsers: Browser[] = [];
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
  });

  /// Until the transcript, the stack and every finite animation hold still over 12 painted frames.
  const settle = (page: Page) =>
    page.evaluate(
      ({ MAIN_DOCK }) =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames++;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const dock = document.querySelector<HTMLElement>(MAIN_DOCK);
            const thread = document.querySelector<HTMLElement>(".acpmux-thread");
            const now = [
              scroller.scrollTop,
              scroller.scrollHeight,
              dock?.getBoundingClientRect().top,
              thread?.getBoundingClientRect().top,
            ].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 900) return true;
            resolve();
            return false;
          });
        }),
      { MAIN_DOCK },
    );

  /// Starts recording every painted frame; the anchor is the row last in the transcript now.
  const startTrace = (page: Page) =>
    page.evaluate(
      ({ TRANSCRIPT_ROW }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows = () => [...scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)];
        const anchorId = rows().at(-1)?.dataset.rowId;
        const trace: { frames: Frame[]; stop?: () => void } = { frames: [] };
        window.__sendTrace = trace;
        trace.stop = window.cmuxAfterPaint((t) => {
          const all = rows();
          const anchor = all.find((row) => row.dataset.rowId === anchorId);
          const card = document.querySelector<HTMLElement>(".acpmux-composer-box")?.getBoundingClientRect();
          trace.frames.push({
            t: Math.round(t * 10) / 10,
            scrollTop: Math.round(scroller.scrollTop * 10) / 10,
            last: Math.round(Math.max(...all.map((row) => row.getBoundingClientRect().bottom)) * 10) / 10,
            anchor: anchor ? Math.round(anchor.getBoundingClientRect().top * 10) / 10 : null,
            card: Math.round((card?.top ?? 0) * 10) / 10,
            cardH: Math.round((card?.height ?? 0) * 10) / 10,
            rows: all.length,
          });
        });
      },
      { TRANSCRIPT_ROW },
    );
  const stopTrace = (page: Page) =>
    page.evaluate(() => {
      const trace = window.__sendTrace!;
      trace.stop?.();
      return trace.frames;
    });

  /// Types `lines` lines into the prompt (Shift+Enter between them), at rest before the send.
  const typeLines = async (page: Page, lines: number) => {
    await page.locator(COMPOSER_EDITOR).first().click();
    for (let line = 1; line <= lines; line++) {
      await page.keyboard.insertText(`Line ${line} of the prompt: check the relay's retry path and its tests`);
      if (line < lines) await page.keyboard.press("Shift+Enter");
    }
    await settle(page);
  };

  const cases: { lines: number; running: boolean; up: boolean }[] = [];
  for (const up of [false, true])
    for (const running of [false, true]) for (const lines of [1, 10, 60]) cases.push({ lines, running, up });

  for (const [engine, type] of engines) {
    for (const { lines, running, up } of cases) {
      const name = `${engine}: a ${lines}-line send ${running ? "while a turn runs" : "from an idle chat"}${up ? ", scrolled up," : ""} moves the transcript one way`;
      test(name, async () => {
        const browser = await type.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, {
          turns: 40,
          running,
          ...(running ? { session: { steering: true, queuePaused: false, queued: 0, queue: [] } } : {}),
        });
        try {
          const page = await pane.open({ width: 900, height: 760 });
          await settle(page);
          await typeLines(page, lines);
          if (up) {
            // The reader scrolls 1200 px up the chat, then sends: the view goes to the latest row.
            await page.mouse.move(450, 150);
            for (let moved = 0; moved < 1200; moved += 40) await page.mouse.wheel(0, -40);
            await settle(page);
          }
          const before = pane.prompts.length;
          const asked = pane.sent(
            "session/prompt",
            pane.methods.filter((method) => method === "session/prompt").length,
          );
          await startTrace(page);
          await page.keyboard.press("Enter");
          await asked;
          const sent = pane.prompts[before]?._meta?.acpmux ?? {};
          const text = Array.from(
            { length: lines },
            (_, i) => `Line ${i + 1} of the prompt: check the relay's retry path and its tests`,
          ).join("\n");
          // acpmux's record of the prompt: idle, its turn starts; mid-turn, it queues.
          if (running) pane.record("queued", { text, promptId: sent.promptId, position: 1 });
          else {
            pane.record("user_message", { text, promptId: sent.promptId, turnId: `turn-${sent.promptId}` });
            pane.record("turn_started", {});
          }
          await settle(page);
          // fixed-wait: room held for a sent prompt is let go on a timer (VirtualTranscript FLOOR_HOLD_MS,
          // 1000 ms); a move back then is the bounce under test, so the trace runs past it.
          await page.waitForTimeout(1600);
          await settle(page);
          const frames = await stopTrace(page);
          await page.close();
          const anchor = directions(frames.map((frame) => frame.anchor).filter((top): top is number => top !== null));
          const offset = directions(frames.map((frame) => frame.scrollTop));
          const last = directions(frames.map((frame) => frame.last));
          // Only frames where something changed, for the trace line.
          const changed = frames.filter(
            (frame, index) =>
              index === 0 || JSON.stringify({ ...frame, t: 0 }) !== JSON.stringify({ ...frames[index - 1]!, t: 0 }),
          );
          console.log(
            `send-no-bounce ${JSON.stringify({ engine, lines, running, up, frames: frames.length, anchor, offset, last, trace: changed.slice(0, 60) })}`,
          );
          // What the reader sees is the rows' screen position; the offset alone can move under a lift
          // that draws the rows where they were (it is reported, not gated).
          // Scrolled up, the send takes the view down to the latest row: the offset only grows.
          expect({
            anchor: Math.min(anchor.up, anchor.down) > STILL_PX ? anchor : "one way",
            offset: up && Math.min(offset.up, offset.down) > STILL_PX ? offset : "one way",
          }).toEqual({ anchor: "one way", offset: "one way" });
        } finally {
          await pane.close();
        }
      });
    }
  }
});
