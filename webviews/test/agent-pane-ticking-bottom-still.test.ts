// l10n-allow-file: test fixture prompts and the host line's stand-in text, not shipped UI.
// A chat followed at its bottom holds still while nothing new arrives, whatever ticks (Leo, 2026-11-18,
// with a recording of his NIGHTLY: "did we fix this scroll bounce at the bottom yet?"). His chat sat at
// the bottom with a running command ("cmux-ci submit … 8m 3s") and "Waiting for the agent service
// (1:48)… Restart agent service" over the composer, both counting up each second while acpmux took
// 5–12 s to answer, and the transcript jumped 30–70 px up and down every second or so while he did
// not scroll.
// Here: the stand-in acpmux's chat ends in a running turn with two commands (their clocks tick), the
// host's waiting line sits in the stack over the composer as App.tsx draws it, and its clock ticks
// each second. For 10 s every row in view must hold its place to the pixel, and the view must keep
// following (no Jump to latest). The second case makes the stand-in slow (every reply 8 s late) and
// has it send the running command's unchanged update every 1.2 s, as a busy acpmux does. Real
// Chromium against the pane's dev entry (support/papercutChat.ts); CI fails the file when it cannot
// launch it (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-ticking-bottom-still.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { JUMP_LATEST_SHOWN, TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

type Held = {
  rows: number;
  most: number;
  moves: { t: number; id: string; dy: number; scrollTop: number; fromEnd: number; jump: boolean }[];
  jump: boolean;
  startGap: number;
  worstGap: number;
  line: number;
};

await requireBrowserLane("agent-pane-ticking-bottom-still.test.ts", async () => {
  setDefaultTimeout(300_000);

  /// Puts the ticking waiting line in the stack, then reads every painted frame for `ms`: how far each
  /// row in view at the start moved, and whether Jump to latest showed.
  const hold = (page: Page, ms: number): Promise<Held> =>
    page.evaluate(
      async ({ rowSelector, jumpShown, ms }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
        const fromEnd = () => scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
        const startGap = fromEnd();
        // HostWaitingLine's markup: the group, its line, the message with its clock and the quiet
        // Restart agent service after it.
        const group = document.createElement("output");
        group.className = "acpmux-host-line-group";
        group.dataset.testHostLine = "";
        group.innerHTML =
          '<div class="acpmux-host-line"><p class="acpmux-host-line-message">Waiting for the agent service (1:48)</p><button type="button" class="acpmux-host-line-quiet">Restart agent service</button></div>';
        dock.insertBefore(group, dock.querySelector(":scope > .acpmux-composer"));
        const message = group.querySelector("p")!;
        let seconds = 108;
        const tick = setInterval(() => {
          seconds += 1;
          message.textContent = `Waiting for the agent service (${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")})`;
        }, 1000);
        const painted = () =>
          new Promise<void>((resolve) =>
            requestAnimationFrame(() => {
              const channel = new MessageChannel();
              channel.port1.onmessage = () => resolve();
              channel.port2.postMessage(0);
            }),
          );
        // Two frames for the line's own arrival (it lies over the foot; host-line-still covers it).
        await painted();
        await painted();
        const view = scroller.getBoundingClientRect();
        const tops = () =>
          new Map(
            [...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => [
              row.dataset.rowId!,
              row.getBoundingClientRect().top,
            ]),
          );
        const before = new Map([...tops()].filter(([, top]) => top > view.top && top < view.bottom));
        const moves: Held["moves"] = [];
        let most = 0;
        let jump = false;
        let worstGap = 0;
        const start = performance.now();
        while (performance.now() - start < ms) {
          await painted();
          const now = tops();
          const shown = !!document.querySelector(jumpShown);
          jump ||= shown;
          let frameMost = 0;
          let frameId = "";
          for (const [id, top] of before) {
            const at = now.get(id);
            const dy = at === undefined ? 9999 : at - top;
            if (Math.abs(dy) > Math.abs(frameMost)) {
              frameMost = dy;
              frameId = id;
            }
            most = Math.max(most, Math.abs(dy));
          }
          if (Math.abs(frameMost) > 0.5 && moves.length < 60)
            moves.push({
              t: Math.round(performance.now() - start),
              id: frameId,
              dy: Math.round(frameMost * 10) / 10,
              scrollTop: Math.round(scroller.scrollTop),
              fromEnd: Math.round(fromEnd()),
              jump: shown,
            });
          worstGap = Math.max(worstGap, fromEnd());
        }
        clearInterval(tick);
        return { rows: before.size, most, moves, jump, startGap, worstGap, line: group.getBoundingClientRect().height };
      },
      { rowSelector: TRANSCRIPT_ROW, jumpShown: JUMP_LATEST_SHOWN, ms },
    );

  const expectStill = (result: Held) => {
    expect(result.startGap).toBeLessThanOrEqual(2);
    expect(result.rows).toBeGreaterThan(3);
    expect(result.line).toBeGreaterThan(12);
    expect(result.jump).toBe(false);
    expect(result.most).toBeLessThanOrEqual(0.5);
  };

  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: true, ready: ".acpmux-row" });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  test("a followed chat with a ticking host line and running commands holds still for 10 s", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      // Let the open settle first: the first draw's own motion is not this test's.
      // fixed-wait: the first draw's own motion is not under test; the hold judges what follows.
      await page.waitForTimeout(1500);
      const result = await hold(page, 10_000);
      console.log("ticking", JSON.stringify(result));
      expectStill(result);
    } finally {
      await page.close();
    }
  });

  test("a slow acpmux re-sending the running command's update holds the followed chat still", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    const sentBefore = pane.methods.length;
    let resend: ReturnType<typeof setInterval> | undefined;
    try {
      // fixed-wait: the first draw's own motion is not under test; the hold judges what follows.
      await page.waitForTimeout(1500);
      pane.slowReplies.ms = 8000;
      resend = setInterval(
        () =>
          pane.record(
            "tool_call_update",
            {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: { sessionUpdate: "tool_call_update", toolCallId: "r1", status: "in_progress" },
              },
            },
            "in",
          ),
        1200,
      );
      const result = await hold(page, 10_000);
      console.log("slow", JSON.stringify(result), "methods", JSON.stringify(pane.methods.slice(sentBefore)));
      expectStill(result);
    } finally {
      if (resend) clearInterval(resend);
      pane.slowReplies.ms = 0;
      await page.close();
    }
  });

  // Leo's line read "Restart agent service" too: the pane was reconnecting (App.tsx `connectHost`).
  // A reconnect whose hole is wider than one read (the running command's updates piled up while it
  // was away) read it forward a page at a time, 1.2 s a read here, and drew each page.
  test("a reconnect that bridges a wide hole holds the followed chat still", async () => {
    const away = await papercutPane(() => browser, {
      turns: 40,
      running: true,
      ready: ".acpmux-row",
      attachPage: 64,
      forwardReads: true,
      eventsLatencyMs: 1200,
    });
    try {
      const page = await away.open({ width: 900, height: 700 });
      // fixed-wait: the first draw's own motion is not under test; the hold judges what follows.
      await page.waitForTimeout(1500);
      const update = {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "tool_call_update", toolCallId: "r1", status: "in_progress" },
        },
      };
      away.drop();
      away.recordAway(12_000, "tool_call_update", update, "in");
      const result = await hold(page, 12_000);
      console.log("reconnect", JSON.stringify(result), "reads", JSON.stringify(away.history.requests.length));
      expectStill(result);
      await page.close();
    } finally {
      await away.close();
    }
  });

  // Leo's pointer sat over the transcript in the recording: a trackpad flick down at the bottom (a
  // burst of decaying wheel events, as macOS sends one) every 1.3 s, while everything ticks. The
  // view is at its end already, so a wheel down has nowhere to go: no row may move.
  test("flicking down at the bottom of a followed, ticking chat moves no row", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      // fixed-wait: the first draw's own motion is not under test; the hold judges what follows.
      await page.waitForTimeout(1500);
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width * 0.8, box.y + box.height * 0.7);
      const held = hold(page, 10_000);
      // fixed-wait: the hold's first frames pass before the flicks start.
      await page.waitForTimeout(200);
      for (let burst = 0; burst < 6; burst++) {
        for (let step = 0; step < 18; step++) {
          await page.mouse.wheel(0, Math.max(2, Math.round(60 * 0.82 ** step)));
          // fixed-wait: a trackpad's wheel events arrive about once a frame.
          await page.waitForTimeout(16);
        }
        // fixed-wait: the gap between Leo's flicks in the recording.
        await page.waitForTimeout(1000);
      }
      const result = await held;
      console.log("flick", JSON.stringify(result));
      expectStill(result);
    } finally {
      await page.close();
    }
  });

  // The same reconnect to an acpmux that takes 5 s to answer anything (the attach too): the open's
  // hold on the drawn chat (direct.ts OPEN_HOLD_MS) ends long before the chat is read again.
  test("a reconnect to a slow acpmux holds the followed chat still", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      // fixed-wait: the first draw's own motion is not under test; the hold judges what follows.
      await page.waitForTimeout(1500);
      pane.slowReplies.ms = 5000;
      pane.drop();
      const result = await hold(page, 12_000);
      console.log("slow-reconnect", JSON.stringify(result));
      expectStill(result);
    } finally {
      pane.slowReplies.ms = 0;
      await page.close();
    }
  });
});
