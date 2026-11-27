// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// Scrolled up, rows arrive; back down at the end, the room under the last row is never cut while
// the reader is looking at it (Leo, 2026-11-20: "so I've scrolled up and you guys have added two
// calls or messages ... there's like space at the bottom or something and it gets pushed and there's
// space for the composer as well maybe. And so I scroll down and there's like an extra bit of scroll
// that I maybe need to do, maybe not. And then like we cut it out. We cut out the extra space. And
// so that is the jump.").
//
// The reader parks 1200 px up a running turn, the turn's calls finish and its reply comes in (and,
// with a queue, the queued prompts run and the queue card leaves the bottom stack), then the reader
// wheels back down to the end in 40 px steps and on past it. At each step the rows in view move
// up by what the wheel scrolled and no more nor less; then, at rest at the end, they hold still.
// Any other move is the transcript moving content under the viewport ("px moved"), which is 0.
//
// One chat of 40 finished turns and a running one (support/papercutChat.ts) through the pane's dev
// entry and a stand-in acpmux. Real Chromium and WebKit (the app's engine) with real wheel events;
// every read is of a painted frame (support/paintedFrames.ts). CI fails the file when it cannot
// launch them (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-scrolled-up-bottom-trim.test.ts
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { MAIN_DOCK } from "../src/agent-session/acpmux/composerSelectors";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-scrolled-up-bottom-trim.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-scrolled-up-bottom-trim: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("scrolled up, bottom trim", () => test("browsers", () => {}));
    return;
  }
  const browsers: Browser[] = [];
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
  });

  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const call = (id: string, command: string): PapercutStep => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command },
    }),
  ];
  const done = (id: string): PapercutStep => [
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
  ];
  const say = (text: string): PapercutStep => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  /// The running turn's calls finish, one more runs, and the reply comes in.
  const runningTurnEnds: PapercutStep[] = [
    done("r1"),
    done("r2"),
    say("Both checks pass. One more for the parser."),
    call("r3", "bun test parser"),
    done("r3"),
    say("All three are green: the parser, its tests and the merged head."),
    ["mux", "turn_result", { status: "completed" }],
  ];
  /// A queued prompt runs: the card leaves the queue, its prompt and the reply come in.
  const queuedRuns = (promptId: string, text: string, n: number): PapercutStep[] => [
    ["mux", "dequeued", { promptId }],
    ["mux", "user_message", { text, promptId, turnId: `turn-${promptId}` }],
    ["mux", "turn_started", {}],
    call(`${promptId}-c`, `bun test queued-${n}`),
    done(`${promptId}-c`),
    say(`Queued answer ${n}: that one is green too, and nothing else changed.`),
    ["mux", "turn_result", { status: "completed" }],
  ];
  const queue = [
    { promptId: "q-1", prompt: "The first queued prompt, about the parser and its tests" },
    { promptId: "q-2", prompt: "The second queued prompt, about the docs" },
  ];
  const cases: {
    name: string;
    session?: Record<string, unknown>;
    arrive: PapercutStep[];
    /// Attach only the newest records and hold every older page's reply until the reader is back at the
    /// end with the room kept: the page then lands above them, which must not eat the room nor move them.
    olderPageAtEnd?: true;
  }[] = [
    { name: "calls and a reply", arrive: runningTurnEnds },
    {
      name: "calls, a reply and the queue's prompts",
      session: { steering: true, queuePaused: false, queued: queue.length, queue },
      arrive: [
        ...runningTurnEnds,
        ...queuedRuns("q-1", queue[0]!.prompt, 1),
        ...queuedRuns("q-2", queue[1]!.prompt, 2),
      ],
    },
    { name: "calls and a reply, then an older page lands", arrive: runningTurnEnds, olderPageAtEnd: true },
  ];

  /// Waits until the transcript and the stack hold still over 12 painted frames, and no finite
  /// animation runs.
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
            const now = [scroller.scrollTop, scroller.scrollHeight, dock?.getBoundingClientRect().top].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 600) return true;
            resolve();
            return false;
          });
        }),
      { MAIN_DOCK },
    );
  type View = { fromEnd: number; room: number; tops: [string, number][] };
  /// After `frames` painted frames: the scroller's distance from its end, the room between the last
  /// row and the stack, and the screen top of each row in view.
  const view = (page: Page, frames = 1) =>
    page.evaluate(
      ({ frames, TRANSCRIPT_ROW, MAIN_DOCK }) =>
        new Promise<View>((resolve) => {
          let painted = 0;
          window.cmuxAfterPaint(() => {
            if (++painted < frames) return true;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const box = scroller.getBoundingClientRect();
            const rows = [...scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)];
            const dock = document.querySelector<HTMLElement>(MAIN_DOCK)!.getBoundingClientRect();
            const last = Math.max(...rows.map((row) => row.getBoundingClientRect().bottom));
            const tops: [string, number][] = [];
            for (const row of rows) {
              const rect = row.getBoundingClientRect();
              if (rect.bottom > box.top && rect.top < dock.top) tops.push([row.dataset.rowId!, rect.top]);
            }
            resolve({
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              room: dock.top - last,
              tops,
            });
            return false;
          });
        }),
      { frames, TRANSCRIPT_ROW, MAIN_DOCK },
    );
  /// How far the rows in view both times moved down from `before` to `after` (the median row).
  const movedDown = (before: View, after: View) => {
    const was = new Map(before.tops);
    const moves = after.tops.filter(([id]) => was.has(id)).map(([id, top]) => top - was.get(id)!);
    moves.sort((a, b) => a - b);
    return moves.length ? moves[Math.floor(moves.length / 2)]! : 0;
  };
  const STEP = 40;
  const wheel = async (page: Page, deltaY: number) => {
    await page.mouse.move(450, 150);
    await page.mouse.wheel(0, deltaY);
  };

  for (const [engine, type] of engines) {
    for (const each of cases) {
      test(`${engine}: scrolled up, ${each.name} arrive; back at the end, nothing moves under the view`, async () => {
        const browser = await type.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, {
          turns: 40,
          running: true,
          session: each.session,
          ...(each.olderPageAtEnd ? { attachPage: 80 } : {}),
        });
        if (each.olderPageAtEnd) pane.stall(["_acpmux/events"]);
        try {
          const page = await pane.open({ width: 900, height: 700 });
          await settle(page);
          const rest = await view(page);
          expect(rest.fromEnd).toBeLessThanOrEqual(1);
          for (let moved = 0; moved < 1200; moved += STEP) await wheel(page, -STEP);
          await settle(page);
          for (const [dir, kind, msg] of each.arrive) pane.record(kind, msg, dir);
          await settle(page);
          // fixed-wait: past the page's own arrival holds (a sent prompt's room is held FLOOR_HOLD_MS on its
          // timer), so what the reader comes back down to is what those timers left, not what they will cut.
          await page.waitForTimeout(500);
          await settle(page);
          const parked = await view(page);
          // Still where the reader parked: arrivals never pull a reader who scrolled up down.
          expect(parked.fromEnd).toBeGreaterThan(600);
          /// Each step: [what the wheel could scroll, how far the rows in view moved down beyond it].
          const steps: [number, number][] = [];
          let before = parked;
          let atEnd: View | undefined;
          for (let step = 0; step < 120; step++) {
            await wheel(page, STEP);
            const after = await view(page, 3);
            const asked = Math.min(STEP, Math.max(0, before.fromEnd));
            steps.push([Math.round(asked * 10) / 10, Math.round((movedDown(before, after) + asked) * 10) / 10]);
            atEnd ??= after.fromEnd <= 0.5 ? after : undefined;
            before = after;
            // Three more steps on past the end, as a reader's wheel does.
            if (atEnd && steps.length >= 3 && steps.slice(-3).every(([asked]) => asked === 0)) break;
          }
          expect(atEnd).toBeDefined();
          if (each.olderPageAtEnd) {
            // The reader went up past the loaded top, so a page was asked; it lands now, at the end.
            expect(pane.history.requests.length).toBeGreaterThan(0);
            await settle(page);
            before = await view(page);
            pane.stall([]);
          }
          await settle(page);
          // fixed-wait: the timing is the behaviour under test: the room kept at the end must still be there
          // after the page's FLOOR_HOLD_MS (1000 ms) timer, which is when a cut would come.
          await page.waitForTimeout(1500);
          await settle(page);
          const later = await view(page);
          const idle = movedDown(before, later);
          const moved = steps.filter(([, extra]) => Math.abs(extra) > 1);
          const total = moved.reduce((sum, [, extra]) => sum + Math.abs(extra), 0) + Math.abs(idle);
          console.log(
            `bottom-trim ${engine} "${each.name}": px moved under the view ${total.toFixed(1)} ` +
              `(steps ${JSON.stringify(moved)}, at rest ${idle.toFixed(1)}); room under the last row: ` +
              `at the latest row before ${rest.room.toFixed(1)}, on reaching the end ${atEnd!.room.toFixed(1)}, ` +
              `at rest ${later.room.toFixed(1)}; ${steps.length} steps`,
          );
          expect({ engine, case: each.name, moved, idle: Math.abs(idle) > 1 ? idle : 0 }).toEqual({
            engine,
            case: each.name,
            moved: [],
            idle: 0,
          });
          await page.close();
        } finally {
          await pane.close();
        }
      });
    }
  }
});
