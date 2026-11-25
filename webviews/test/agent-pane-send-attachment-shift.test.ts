// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts, not shipped UI.
// A prompt sent with an image while the chat is idle lands once and holds still while its turn opens
// (Leo, 2026-11-25: "there's shift when i have an attachment in message and send to you on idle. when
// i send a message in gui, the space below should automatically start accomodating for the working and
// the thinking already").
//
// The pane's dev entry with the in-page mock acpmux (mock.ts), real Chromium. The mock answers the send
// `ECHO_MS` late, as acpmux writes the prompt's record after it took the image, then plays a turn of
// thinking and commands. Every painted frame from the send on records where the sent bubble and the rows
// above it are in the view, and the Layout Instability API's `layout-shift` entries.
//
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-attachment-shift.test.ts
// SEND_SHIFT_TRACE=1 prints each frame the bubble moved.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

type Frame = {
  t: number;
  bubble: { top: number; height: number } | null;
  /// The live Thinking line's top, in view coordinates.
  thinking: number | null;
  rows: number;
  scrollTop: number;
  /// The rows drawn under the sent bubble, by id.
  below: string[];
};
type Shift = { at: number; value: number; recent: boolean; sources: string[] };

/// web-vitals CLS: the largest session window's sum (a window ends after a 1 s gap or at 5 s).
function clsOf(shifts: readonly Shift[]): number {
  let best = 0;
  let sum = 0;
  let first = -Infinity;
  let last = -Infinity;
  for (const shift of shifts) {
    if (shift.recent) continue;
    if (shift.at - last > 1000 || shift.at - first > 5000) {
      sum = 0;
      first = shift.at;
    }
    sum += shift.value;
    last = shift.at;
    best = Math.max(best, sum);
  }
  return best;
}

await requireBrowserLane("agent-pane-send-attachment-shift.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-attachment-shift: skipping (run `bunx playwright install chromium`)");
    describe.skip("send attachment shift", () => test("chromium", () => {}));
    return;
  }
  const TRACE = process.env.SEND_SHIFT_TRACE === "1";
  /// How late the mock writes the prompt's record (acpmux takes the image first).
  const ECHO_MS = 400;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function newChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// Pastes a PNG of `width` by `height` into the prompt.
  const pasteImage = (page: Page, width: number, height: number) =>
    page.evaluate(
      async ({ COMPOSER_EDITOR, width, height }) => {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const context = canvas.getContext("2d")!;
        context.fillStyle = "#3a7bd5";
        context.fillRect(0, 0, width, height);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        const data = new DataTransfer();
        data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
        document
          .querySelector(COMPOSER_EDITOR)!
          .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { COMPOSER_EDITOR, width, height },
    );

  /// Records every painted frame's sent bubble box (the newest `.cv-user` row, in view coordinates) and
  /// every layout shift, until `stop`.
  const record = (page: Page) =>
    page.evaluate(() => {
      const w = window as any;
      w.__frames = [] as unknown[];
      w.__shifts = [] as unknown[];
      w.__recording = true;
      const name = (node: Node | null) => {
        const element = node instanceof Element ? node : node?.parentElement;
        const row = element?.closest<HTMLElement>("[data-row-id]");
        return row ? `${row.dataset.rowId} ${element!.className}` : String(element?.className ?? "?");
      };
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as any[])
          w.__shifts.push({
            at: entry.startTime,
            value: entry.value,
            recent: entry.hadRecentInput,
            sources: (entry.sources ?? []).map(
              (source: any) =>
                `${name(source.node)} ${Math.round(source.previousRect.y)}->${Math.round(source.currentRect.y)} h${Math.round(source.previousRect.height)}->${Math.round(source.currentRect.height)}`,
            ),
          });
      }).observe({ type: "layout-shift", buffered: false });
      const tick = () => {
        if (!w.__recording) return;
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
        const bubbles = [...document.querySelectorAll<HTMLElement>(".cv-user")];
        const bubble = bubbles.at(-1)?.closest<HTMLElement>("[data-row-id]") ?? null;
        const box = bubble?.getBoundingClientRect();
        const below = bubble ? rows.slice(rows.indexOf(bubble) + 1).map((row) => row.dataset.rowId ?? "?") : [];
        const line = document.querySelector<HTMLElement>('[data-row-id="thinking-live"]')?.getBoundingClientRect();
        const scroller = document.querySelector<HTMLElement>(".acpmux-transcript-scroll, [data-transcript-scroll]");
        w.__frames.push({
          t: performance.now(),
          bubble: box ? { top: Math.round(box.top * 10) / 10, height: Math.round(box.height * 10) / 10 } : null,
          thinking: line ? Math.round((line.top - (box?.top ?? 0)) * 10) / 10 : null,
          rows: rows.length,
          scrollTop: scroller?.scrollTop ?? -1,
          below,
        });
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });

  const stop = (page: Page) =>
    page.evaluate(() => {
      const w = window as any;
      w.__recording = false;
      return { frames: w.__frames as Frame[], shifts: w.__shifts as Shift[] };
    });

  /// The send's own motion settles in its first frames (sendMorph.ts); a move after `SETTLE_MS` is the
  /// bubble pushed by what came in under or over it.
  const SETTLE_MS = 400;

  async function sendWithImage(width: number, height: number) {
    const page = await newChat();
    const prompt = page.locator(COMPOSER_EDITOR);
    // One finished turn first, so the send is from an idle chat with history.
    await prompt.click();
    await page.keyboard.type("hello");
    await page.keyboard.press("Enter");
    await page.locator(".cv-user__bubble", { hasText: "hello" }).waitFor();
    const stopButton = page.getByRole("button", { name: "Stop" });
    await stopButton.waitFor();
    await stopButton.waitFor({ state: "detached", timeout: 30_000 });
    await page.evaluate(
      (ms) => Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: ms }),
      ECHO_MS,
    );
    await prompt.click();
    await pasteImage(page, width, height);
    await page.locator(".acpmux-attachment-image").waitFor();
    await page.keyboard.type("what is this");
    // fixed-wait: the chip's own load settles before the send is measured.
    await page.waitForTimeout(300);
    await record(page);
    const sentAt = await page.evaluate(() => performance.now());
    await page.keyboard.press("Enter");
    // The turn opens (the echo), thinks and runs its first commands.
    await page.waitForFunction(() => document.querySelectorAll(".cv-user").length >= 2);
    // fixed-wait: the window the turn's opening plays in is the thing under test.
    await page.waitForTimeout(ECHO_MS + 2_500);
    const { frames, shifts } = await stop(page);
    await page.close();
    // The turn's opening: from the send until the first row under the bubble that is the turn's work (a
    // command, a reply), not its "Working for" heading or its live line. Rows of work coming in after that
    // move the bubble as the view follows them, by design.
    const opening = (id: string) => /^(thinking-live|working|worked|live|summary|turnSummary|date)/.test(id);
    const workAt = frames.findIndex((frame) => frame.t > sentAt && frame.below.some((id) => !opening(id)));
    const opened = workAt < 0 ? frames : frames.slice(0, workAt);
    let moved = 0;
    let jumps = 0;
    let grew = 0;
    // The Thinking line under the bubble (its top less the bubble's): the heading coming in over it later pushes it.
    let linePushed = 0;
    const lists = new Set<string>();
    const lines: string[] = [];
    let before: Frame | undefined;
    let belowBefore = "";
    for (const frame of opened) {
      const belowNow = frame.below.join(",");
      if (TRACE && frame.t >= sentAt && belowNow !== belowBefore)
        lines.push(
          `  +${Math.round(frame.t - sentAt)}ms under the bubble: ${belowNow || "nothing"} (top ${frame.bubble?.top})`,
        );
      belowBefore = belowNow;
      if (frame.t > sentAt + SETTLE_MS && frame.below.length) lists.add(belowNow);
      if (frame.t > sentAt + SETTLE_MS && frame.thinking !== null && before?.thinking != null) {
        const dl = frame.thinking - before.thinking;
        if (Math.abs(dl) >= 1) {
          linePushed += Math.abs(dl);
          lines.push(
            `  +${Math.round(frame.t - sentAt)}ms Thinking line ${before.thinking}->${frame.thinking} under the bubble`,
          );
        }
      }
      if (frame.bubble && before?.bubble && frame.t - sentAt > SETTLE_MS) {
        const dy = frame.bubble.top - before.bubble.top;
        const dh = frame.bubble.height - before.bubble.height;
        if (Math.abs(dy) >= 1 || Math.abs(dh) >= 1) {
          moved += Math.abs(dy);
          grew += Math.abs(dh);
          jumps += 1;
          lines.push(
            `  +${Math.round(frame.t - sentAt)}ms top ${before.bubble.top}->${frame.bubble.top} h ${before.bubble.height}->${frame.bubble.height} rows ${frame.rows}`,
          );
        }
      }
      before = frame;
    }
    // The row right under the bubble, over the whole turn: the turn's heading stands there from the send. A
    // heading that comes in at the first call takes the Thinking line's place and pushes it and all under it.
    const heads: string[] = [];
    // And the Thinking line's place under the bubble over the whole turn (the work folds under the heading).
    const linePlaces: number[] = [];
    for (const frame of frames) {
      if (frame.t < sentAt) continue;
      if (frame.thinking !== null && frame.thinking !== linePlaces.at(-1)) linePlaces.push(frame.thinking);
      const head = frame.below.find((id) => !id.startsWith("date"));
      if (head && head !== heads.at(-1)) heads.push(head);
    }
    const end = opened.at(-1)?.t ?? sentAt;
    const inOpening = shifts.filter((shift) => shift.at >= sentAt && shift.at <= end);
    const cls = clsOf(inOpening);
    const report = {
      image: `${width}x${height}`,
      cls: Number(cls.toFixed(5)),
      layoutShifts: inOpening.length,
      bubbleMovedPx: Math.round(moved),
      bubbleResizedPx: Math.round(grew),
      bubbleMoves: jumps,
      thinkingPushedPx: Math.round(linePushed),
      rowsUnderBubble: [...lists],
      thinkingPlaces: linePlaces,
      rowUnderBubble: heads.map((id) => id.replace(/local-[0-9a-f-]+|user-\d+/, "PROMPT")),
      openingMs: Math.round((opened.at(-1)?.t ?? sentAt) - sentAt),
    };
    console.log(`SEND_ATTACHMENT_SHIFT ${JSON.stringify(report)}`);
    if (TRACE) {
      for (const line of lines) console.log(line);
      for (const shift of inOpening)
        console.log(
          `  shift +${Math.round(shift.at - sentAt)}ms ${shift.value.toFixed(5)} ${shift.sources.join(" | ")}`,
        );
    }
    return report;
  }

  test("a wide screenshot sent on idle: the bubble lands once and holds while the turn opens", async () => {
    const report = await sendWithImage(1432, 198);
    expect(report.rowUnderBubble).toEqual(["worked-PROMPT"]);
    expect(report.bubbleMovedPx).toBe(0);
    expect(report.thinkingPushedPx).toBe(0);
    // From the send on, the heading and the line stand under the bubble: one set of rows until the turn's work.
    expect(report.rowsUnderBubble.length).toBe(1);
    expect(report.bubbleResizedPx).toBe(0);
    expect(report.cls).toBeLessThan(0.001);
  });

  test("a tall image sent on idle: the bubble lands once and holds while the turn opens", async () => {
    const report = await sendWithImage(600, 900);
    expect(report.rowUnderBubble).toEqual(["worked-PROMPT"]);
    expect(report.bubbleMovedPx).toBe(0);
    expect(report.thinkingPushedPx).toBe(0);
    // From the send on, the heading and the line stand under the bubble: one set of rows until the turn's work.
    expect(report.rowsUnderBubble.length).toBe(1);
    expect(report.bubbleResizedPx).toBe(0);
    expect(report.cls).toBeLessThan(0.001);
  });
});
