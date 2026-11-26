// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The room kept under the last row after a scroll back down is filled by the rows that come next, and a
// scroll draws no composer (Leo, 2026-11-22: "just saw a composer flicker/re-render when for some reason
// there's also a ton of space at the bottom? idk if it was accounting maybe for tool calls in a long
// steered with attachment situation like... and then i scrolled up and then the composer flickered.
// weird state around here all-around. the whole situation needs to be audited and sniffed out").
//
// While the reader is scrolled up, the room under the last row keeps the stack's height from when they
// left (VirtualTranscript `heldRoom`). The stack was tall then: a draft with attachments, queued steer
// cards. It shrinks while they read (the steer goes in, the draft clears). Back at the end by their own
// wheel, that room is kept so nothing they look at moves (Leo, 2026-11-20). It was kept as a fixed height
// until the next prompt, so every row the turn brought after that landed above a band of empty room
// over the composer: his screenshot, 250-300 px under "Thinking". The rows that arrive must fill it:
// once more has come than the room, the room under the last row is what it was before he scrolled up.
//
// And the composer: a transcript scroll renders it 0 times (`cmuxAcpmuxDebug.renders().composer`), and
// its editor is the same node after (no remount).
//
// One chat of 40 finished turns and a running one (support/papercutChat.ts) through the pane's dev entry
// and a stand-in acpmux; real Chromium and WebKit with real wheel events; every read is of a painted
// frame. Off this host: cmux-ci test --setup playwright -- 'cd webviews && CMUX_BROWSER_TESTS=1 bun test
// test/agent-pane-kept-room-fills-browser.test.ts'.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_EDITOR, MAIN_DOCK } from "../src/agent-session/acpmux/composerSelectors";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-kept-room-fills-browser.test.ts", async () => {
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
      console.warn(`agent-pane-kept-room-fills: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("kept room fills", () => test("browsers", () => {}));
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
  /// The running turn goes on: a call at a time, each finished, none ending the turn.
  const calls = (from: number, count: number): PapercutStep[][] =>
    Array.from({ length: count }, (_, index) => {
      const id = `k${from + index}`;
      return [call(id, `bun test suite-${from + index} --filter steer`), done(id)];
    });
  const queue = [
    { promptId: "q-1", prompt: "The first steer, with the screenshots of the scroll rail\n\nand a second paragraph" },
    { promptId: "q-2", prompt: "The second steer, about the hover icon\n\nand one more line" },
    { promptId: "q-3", prompt: "The third steer\n\nwith its own two lines" },
  ];
  /// What makes the stack tall before the reader scrolls up, and what shrinks it while they are up.
  const cases: {
    name: string;
    session?: Record<string, unknown>;
    tall: (page: Page) => Promise<void>;
    shrink: PapercutStep[];
    clear?: (page: Page) => Promise<void>;
  }[] = [
    {
      name: "queued steers go into the turn",
      session: { steering: true, queuePaused: false, queued: queue.length, queue },
      tall: async () => {},
      shrink: queue.map(({ promptId }) => ["mux", "dequeued", { promptId }] as PapercutStep),
    },
    {
      name: "a tall draft is cleared",
      tall: async (page) => {
        await page.locator(COMPOSER_EDITOR).first().click();
        for (let line = 0; line < 9; line++) {
          await page.keyboard.type(`A long steer, line ${line + 1}`);
          await page.keyboard.press("Shift+Enter");
        }
      },
      shrink: [],
      clear: async (page) => {
        await page.locator(COMPOSER_EDITOR).first().focus();
        await page.keyboard.press("ControlOrMeta+a");
        await page.keyboard.press("Backspace");
      },
    },
  ];

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
  const composerRenders = async (page: Page) => {
    const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<string, number>;
    console.log(`kept-room renders ${JSON.stringify(renders)}`);
    return renders.composer ?? 0;
  };
  const editorNode = (page: Page) =>
    page.evaluate((selector) => {
      const node = document.querySelector(selector) as (Element & { __probe?: number }) | null;
      if (!node) return "none";
      node.__probe ??= Math.random();
      return String(node.__probe);
    }, COMPOSER_EDITOR);

  for (const [engine, type] of engines) {
    for (const each of cases) {
      test(`${engine}: ${each.name} while scrolled up; back at the end, the turn's rows fill the room`, async () => {
        const browser = await type.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, { turns: 40, running: true, session: each.session });
        try {
          const errors: string[] = [];
          let opened: Page | undefined;
          const page = await pane
            .open({ width: 900, height: 760 }, async (page) => {
              opened = page;
              page.on("pageerror", (error) => errors.push(`pageerror: ${error.message} ${error.stack ?? ""}`));
              page.on("console", (message) => {
                if (message.type() === "error") errors.push(`console: ${message.text()}`);
              });
            })
            .catch(async (error) => {
              const shown = await opened?.evaluate(() => document.body.innerText.slice(0, 400)).catch(() => "?");
              throw new Error(`the chat never opened: ${errors.slice(0, 6).join(" | ")}; page: ${shown}`, {
                cause: error,
              });
            });
          await settle(page);
          const rest = await view(page);
          expect(rest.fromEnd).toBeLessThanOrEqual(1);
          await each.tall(page);
          await settle(page);
          const tall = await view(page);

          // Scrolled up 1200 px by the wheel: the composer draws no time, and stays the same node.
          const node = await editorNode(page);
          await composerRenders(page);
          // Every painted frame of the scroll: the composer box's place and size, and its opacity.
          await page.evaluate(() => {
            const frames: string[] = [];
            (window as any).__composerFrames = frames;
            window.cmuxAfterPaint(() => {
              const box = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock .acpmux-composer-box");
              if (!box) frames.push("none");
              else {
                const rect = box.getBoundingClientRect();
                frames.push(
                  [rect.top, rect.left, rect.width, rect.height, getComputedStyle(box).opacity].map(String).join(","),
                );
              }
              return (window as any).__composerFrames === frames;
            });
          });
          for (let moved = 0; moved < 1200; moved += STEP) await wheel(page, -STEP);
          await settle(page);
          const scrollRenders = await composerRenders(page);
          const composerLooks = await page.evaluate(() => {
            const frames = (window as any).__composerFrames as string[];
            (window as any).__composerFrames = undefined;
            return [...new Set(frames)];
          });
          const sameNode = (await editorNode(page)) === node;

          // While up, the stack shrinks.
          for (const [dir, kind, msg] of each.shrink) pane.record(kind, msg, dir);
          await each.clear?.(page);
          await settle(page);
          // fixed-wait: past the page's arrival holds (FLOOR_HOLD_MS 1000 ms), so what is kept is what they left.
          await page.waitForTimeout(1200);
          await settle(page);
          const parked = await view(page);
          expect(parked.fromEnd).toBeGreaterThan(400);

          // Back down to the end by the wheel, and on past it.
          let atEnd: View | undefined;
          let pastEnd = 0;
          for (let step = 0; step < 150 && pastEnd < 3; step++) {
            await wheel(page, STEP);
            const after = await view(page, 3);
            if (after.fromEnd <= 0.5) {
              atEnd ??= after;
              pastEnd++;
            }
          }
          expect(atEnd).toBeDefined();
          await settle(page);
          const back = await view(page);

          // The turn goes on: calls arrive one at a time. The first moves no row in view while room is kept.
          const arrivals = calls(1, 12);
          for (const step of arrivals[0]!) pane.record(step[1], step[2], step[0]);
          await settle(page);
          const first = await view(page);
          const firstMoved = back.room > rest.room + 60 ? movedDown(back, first) : 0;
          for (const steps of arrivals.slice(1)) {
            for (const [dir, kind, msg] of steps) pane.record(kind, msg, dir);
            await settle(page);
          }
          // fixed-wait: past FLOOR_HOLD_MS, so a hold that still had the room would show it.
          await page.waitForTimeout(1200);
          await settle(page);
          const filled = await view(page);
          console.log(
            `kept-room ${engine} "${each.name}": room under the last row before ${rest.room.toFixed(1)}, ` +
              `tall stack ${tall.room.toFixed(1)}, back at the end ${back.room.toFixed(1)}, after 1 call ` +
              `${first.room.toFixed(1)} (rows moved ${firstMoved.toFixed(1)}), after 12 calls ${filled.room.toFixed(1)}; ` +
              `composer renders on a 1200 px scroll ${scrollRenders}, same editor node ${sameNode}, composer ` +
              `box looks over the scroll's frames ${JSON.stringify(composerLooks)}`,
          );
          expect({
            engine,
            case: each.name,
            room: Math.abs(filled.room - rest.room) <= 2 ? "rest" : filled.room,
            firstMoved: Math.abs(firstMoved) <= 1 ? 0 : firstMoved,
            scrollRenders,
            sameNode,
            composerLooks: composerLooks.length,
          }).toEqual({
            engine,
            case: each.name,
            room: "rest",
            firstMoved: 0,
            scrollRenders: 0,
            sameNode: true,
            composerLooks: 1,
          });
          await page.close();
        } finally {
          await pane.close();
        }
      });
    }
  }
});
