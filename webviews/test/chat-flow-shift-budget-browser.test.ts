// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The chat's layout-shift budget, flow by flow (Leo, 2026-11-25: "layout shifts and awkward looking
// animations"). Six flows a person runs every day each get a budget the transcript and the composer
// must stay inside, judged on every painted frame:
//   send        type a prompt, Return, the reply streams in and the turn ends;
//   thinking    a turn that thinks first (a live thinking row), then answers;
//   compaction  /compact: a compaction row runs, finishes and its summary lands;
//   compaction-steer  /compact, and a prompt sent while it runs: the compaction folds, then the next
//               turn's Working for and Thinking take its place (Leo, 2026-11-25: "the worked for
//               collapsing the compaction and then the next worked for + thinking is weird");
//   background  a turn starts a background shell, answers and ends; the shell's end lands on the
//               idle chat afterwards;
//   reload      the page reloads onto the same chat: from its first frame nothing drawn moves, and
//               the composer and the newest row come back where they were.
// The check is the gallery's box tracker (src/gallery/shift.ts) judged by followJudge.ts, the same one
// agent-chat-stream-no-shift-browser.test.ts reads for a streamed turn with tool calls: a stray move is
// a transcript row or the composer moving other than by the rows' shared follow or by a row above it
// growing. Each flow's worst stray (px), the composer's move across each step (px) and, in Chromium, the
// browser's own layout-shift score (the CLS sum of entries without recent input) must stay in BUDGET.
//
// The control: each flow runs once more with a seeded 24 px jump (a rested row and the composer
// translated mid-step, or on a reload's tenth frame), and the same verdict must name it. A budget
// check that cannot catch a planted shift would pass a real one.
//
//   CMUX_BROWSER_TESTS=1 bun test test/chat-flow-shift-budget-browser.test.ts
// FLOW_SHIFT_OUT=DIR (or $FAST_CHECKS_OUT) writes flow-shift.json with every step's numbers.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import type { BoxShift } from "../src/gallery/shift";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { installBoxTracker, installBoxTrackerOnLoad } from "./support/boxTrackerPage";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import {
  BUDGET,
  COMPOSER,
  FLOWS,
  KNOWN,
  SEED_PX,
  overBudget,
  type FlowName,
  type StepReport,
} from "./support/chatFlowShiftBudget";

await requireBrowserLane("chat-flow-shift-budget-browser.test.ts", async () => {
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
      console.warn(`chat-flow-shift-budget: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("chat flow shift budget", () => test("no engine", () => {}));
    return;
  }

  const OUT = process.env.FLOW_SHIFT_OUT ?? process.env.FAST_CHECKS_OUT;
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) =>
    update({
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text },
    });
  const thought = (text: string) =>
    update({
      sessionUpdate: "agent_thought_chunk",
      content: { type: "text", text },
    });
  const words = (text: string) => text.split(/(?<= )/);

  type Pane = Awaited<ReturnType<typeof papercutPane>>;
  type Play = (pane: Pane, page: Page) => Promise<void>;
  // fixed-wait: the stream's own cadence (deltas some tens of ms apart, as an agent sends them) is the input under test.
  const pause = (ms: number) => Bun.sleep(ms);
  const stream =
    (make: (text: string) => Record<string, unknown>, kind: string, texts: string[], gap = 35): Play =>
    async (pane) => {
      for (const text of texts) {
        pane.record(kind, make(text), "in");
        await pause(gap);
      }
    };
  /// Typed in the composer and sent with Return, as a person does; the stand-in acpmux echoes the
  /// prompt under the id the page sent it with.
  const send =
    (text: string, turn: string): Play =>
    async (pane, page) => {
      await page.locator(COMPOSER_EDITOR).first().click();
      await page.keyboard.type(text);
      const before = pane.prompts.length;
      const asked = pane.sent("session/prompt", pane.methods.filter((method) => method === "session/prompt").length);
      await page.keyboard.press("Enter");
      await asked;
      const promptId = pane.prompts[before]?._meta?.acpmux?.promptId as string;
      pane.record("user_message", { text, promptId, turnId: `t-${turn}` });
      pane.record("turn_started", {});
    };
  const ends: Play = async (pane) => pane.record("turn_result", { status: "completed" });

  /// Text each flow must leave in the transcript.
  const DRAWN: Record<Exclude<FlowName, "reload">, string> = {
    send: "Only the queue needs the cap.",
    thinking: "asks the link for the current one",
    compaction: "/compact",
    "compaction-steer": "The cap now lives in one place.",
    background: "The dev server is up on port 5173.",
  };
  /// Text a step must show once it settles: the live row the flow is about, before its turn folds it away.
  const SHOWS: Record<string, RegExp> = {
    thinking: /Thinking/,
    "compaction runs": /Compacting/,
    "next thinking": /Thinking/,
  };
  /// A background shell: the tool call that starts it, its result, and acpmux's task row going running.
  const BG = {
    taskId: "bg-call-flow",
    toolCallId: "call-flow-bg",
    command: "bun run dev",
    description: "bun run dev",
    origin: "bash",
  };
  const flows = (turn: string): Record<Exclude<FlowName, "reload">, [string, Play][]> => ({
    send: [
      ["send", send(`Which retry loops sleep a fixed time? (${turn})`, turn)],
      [
        "reply",
        stream(
          chunk,
          "agent_message_chunk",
          words(
            "The upload queue sleeps a fixed second between tries; the fetch client and the socket reconnect " +
              "back off.\n\n- fetch client\n- socket reconnect\n- upload queue\n\nOnly the queue needs the cap.",
          ),
        ),
      ],
      ["turn ends", ends],
    ],
    thinking: [
      ["send", send(`Why does the upload stall after a reconnect? (${turn})`, turn)],
      [
        "thinking",
        stream(
          thought,
          "agent_thought_chunk",
          words(
            "The stall starts after a reconnect, so the queue must hold a socket that closed. " +
              "Its retry reads the old handle and waits for a close that already happened. ",
          ),
        ),
      ],
      [
        "answer",
        stream(
          chunk,
          "agent_message_chunk",
          words("The queue keeps the closed socket. It now asks the link for the current one on every retry."),
        ),
      ],
      ["turn ends", ends],
    ],
    compaction: [
      ["send", send("/compact", turn)],
      [
        "compaction runs",
        async (pane) =>
          pane.record(
            "compaction",
            update({
              sessionUpdate: "compaction",
              state: "running",
              reason: "manual",
            }),
            "in",
          ),
      ],
      [
        "compaction ends",
        async (pane) =>
          pane.record(
            "compaction",
            update({
              sessionUpdate: "compaction",
              state: "completed",
              reason: "manual",
              tokensBefore: 182000,
            }),
            "in",
          ),
      ],
      [
        "summary",
        async (pane) =>
          pane.record(
            "compaction_summary",
            update({
              sessionUpdate: "compaction_summary",
              text: `Summary (${turn}): retry caps, upload queue.`,
            }),
            "in",
          ),
      ],
      ["turn ends", ends],
    ],
    "compaction-steer": [
      ["send", send("/compact", turn)],
      [
        "compaction runs",
        async (pane) =>
          pane.record(
            "compaction",
            update({
              sessionUpdate: "compaction",
              state: "running",
              reason: "manual",
            }),
            "in",
          ),
      ],
      // Typed and sent while the compaction runs: it waits for the compaction's turn to end.
      ["steer during compaction", send(`Now move the retry cap into one place. (${turn})`, `${turn}-next`)],
      [
        "compaction ends",
        async (pane) => {
          pane.record(
            "compaction",
            update({
              sessionUpdate: "compaction",
              state: "completed",
              reason: "manual",
              tokensBefore: 182000,
            }),
            "in",
          );
          pane.record(
            "compaction_summary",
            update({
              sessionUpdate: "compaction_summary",
              text: `Summary (${turn}): retry caps, upload queue.`,
            }),
            "in",
          );
          pane.record("turn_result", { status: "completed" });
        },
      ],
      [
        "next thinking",
        async (pane, page) => {
          pane.record("turn_started", {});
          await stream(
            thought,
            "agent_thought_chunk",
            words("The cap is read in three places; one constant will do. "),
          )(pane, page);
        },
      ],
      [
        "next answer",
        stream(chunk, "agent_message_chunk", words("The cap now lives in one place. The three callers read it.")),
      ],
      ["turn ends", ends],
    ],
    background: [
      ["send", send(`Run the dev server and tell me when it is up. (${turn})`, turn)],
      [
        "background starts",
        async (pane) => {
          const call = {
            toolCallId: BG.toolCallId,
            title: BG.command,
            kind: "execute",
          };
          pane.record(
            "tool_call",
            update({
              sessionUpdate: "tool_call",
              ...call,
              status: "in_progress",
              rawInput: {
                command: BG.command,
                description: BG.command,
                run_in_background: true,
              },
            }),
            "in",
          );
          await pause(200);
          pane.record(
            "tool_call_update",
            update({
              sessionUpdate: "tool_call_update",
              toolCallId: BG.toolCallId,
              status: "completed",
              content: [
                {
                  type: "content",
                  content: {
                    type: "text",
                    text: "Command running in background with ID: bg-1",
                  },
                },
              ],
            }),
            "in",
          );
          await pause(100);
          pane.record(
            "background_task_update",
            update({
              sessionUpdate: "background_task_update",
              ...BG,
              state: "running",
            }),
            "in",
          );
        },
      ],
      ["reply", stream(chunk, "agent_message_chunk", words("The dev server is up on port 5173."))],
      ["turn ends", ends],
      [
        "background ends",
        async (pane) =>
          pane.record(
            "background_task_update",
            update({
              sessionUpdate: "background_task_update",
              ...BG,
              state: "completed",
            }),
            "in",
          ),
      ],
    ],
  });

  /// Every finite animation over, then the transcript's offset and height the same over 12 painted frames.
  const settle = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const moving = () =>
        document
          .getAnimations()
          .some(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      let last = "";
      for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
        held = now === last && !moving() ? held + 1 : 0;
        last = now;
      }
    });
  const composerBottom = (page: Page) =>
    page.evaluate(
      (selector) => document.querySelector<HTMLElement>(selector)?.getBoundingClientRect().bottom ?? Number.NaN,
      COMPOSER,
    );
  /// The newest row's top in the viewport, for the reload's return check.
  const newestRowTop = (page: Page) =>
    page.evaluate((rowSelector) => {
      const rows = [...document.querySelectorAll<HTMLElement>(rowSelector)].filter(
        (row) => row.getBoundingClientRect().height > 0,
      );
      return rows.at(-1)?.getBoundingClientRect().top ?? Number.NaN;
    }, TRANSCRIPT_ROW);

  /// Layout-shift entries from each document's start (Chromium; WebKit has none), read and cleared per step.
  const installClsRecorder = (page: Page) =>
    page.addInitScript(() => {
      const w = window as unknown as {
        cmuxFlowCls: number;
        cmuxFlowClsLive: boolean;
      };
      w.cmuxFlowCls = 0;
      w.cmuxFlowClsLive = false;
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries() as unknown as {
            value: number;
            hadRecentInput: boolean;
          }[])
            if (!entry.hadRecentInput) w.cmuxFlowCls += entry.value;
        }).observe({ type: "layout-shift", buffered: true });
        w.cmuxFlowClsLive = true;
      } catch {
        // WebKit: no layout-shift entries.
      }
    });
  const takeCls = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as {
        cmuxFlowCls: number;
        cmuxFlowClsLive: boolean;
      };
      const value = w.cmuxFlowClsLive ? Math.round(w.cmuxFlowCls * 10000) / 10000 : null;
      w.cmuxFlowCls = 0;
      return value;
    });

  /// The planted shift: once a row is drawn and `frames` more frames painted, a rested row in view and
  /// the composer move SEED_PX, with nothing else moving (a stray the judge must name).
  /// With `once`, it runs as an init script: only on the document a reload made after arming it.
  const SEED = (args: { px: number; frames: number; rowSelector: string; composer: string; once?: boolean }) => {
    if (args.once) {
      if (sessionStorage.getItem("cmuxSeedShift") !== "1") return;
      sessionStorage.removeItem("cmuxSeedShift");
    }
    const plant = async () => {
      const paint = () => new Promise<void>((done) => requestAnimationFrame(() => done()));
      while (!document.querySelector(args.rowSelector)) await paint();
      for (let frame = 0; frame < args.frames; frame += 1) await paint();
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")?.getBoundingClientRect();
      const rows = [...document.querySelectorAll<HTMLElement>(args.rowSelector)].filter((row) => {
        const box = row.getBoundingClientRect();
        return box.height > 0 && (!view || (box.top >= view.top && box.bottom <= view.bottom));
      });
      const row = rows.at(-2) ?? rows.at(-1);
      if (row) row.style.translate = `0 ${args.px}px`;
      const composer = document.querySelector<HTMLElement>(args.composer);
      if (composer) composer.style.translate = `0 ${-args.px}px`;
    };
    void plant();
  };
  const seedArgs = {
    px: SEED_PX,
    frames: 4,
    rowSelector: TRANSCRIPT_ROW,
    composer: COMPOSER,
  };

  const reports: Record<string, StepReport[]> = {};
  const browsers = new Map<string, Browser>();
  let pane: Pane | undefined;
  let current: Browser | undefined;
  let serial = 0;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const first = browsers.values().next().value!;
    pane = await papercutPane(() => current ?? first, {
      turns: 10,
      running: false,
    });
  });
  afterAll(async () => {
    await pane?.close();
    for (const browser of browsers.values()) await browser.close();
    if (OUT) {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, "flow-shift.json"), JSON.stringify(reports, null, 2));
    }
  });

  const measure = async (page: Page, step: string, play: () => Promise<void>, seeded: boolean) => {
    const composerBefore = await composerBottom(page);
    const dump = (tag: string) => page.evaluate((sel) => [...document.querySelectorAll<HTMLElement>(sel)].filter((r) => r.getBoundingClientRect().height > 0).slice(-8).map((r) => `${r.dataset.rowId ?? r.getAttribute("aria-label") ?? r.className.slice(0,30)}|${(r.textContent ?? "").slice(0, 40)}|${Math.round(r.getBoundingClientRect().top)}`), TRANSCRIPT_ROW).then((rows) => { if (process.env.FLOW_DEBUG) console.log("DBG", tag, step, "\n  " + rows.join("\n  ")); });
    await dump("before");
    await takeCls(page);
    await page.evaluate(() => window.cmuxBoxTracker!.start());
    if (seeded) await page.evaluate(SEED, seedArgs);
    await play();
    await settle(page);
    await dump("after");
    const shift: BoxShift = await page.evaluate(() => window.cmuxBoxTracker!.stop());
    const follow = shift.follow!;
    return {
      step,
      stray: follow.worst,
      strays: follow.stray.slice(0, 4).map(({ label, dy, dx, follow, frame }) => ({
        label,
        dy,
        dx,
        follow,
        frame,
      })),
      composer: Math.round(Math.abs((await composerBottom(page)) - composerBefore) * 10) / 10,
      cls: await takeCls(page),
    } satisfies StepReport;
  };

  /** Plays `flow` on a new page; with `seeded`, the planted jump lands in its second step (a reload's tenth frame). */
  const runFlow = async (engine: string, flow: FlowName, seeded: boolean): Promise<StepReport[]> => {
    current = browsers.get(engine)!;
    const turn = `${engine}-${flow}-${++serial}`;
    const page = await pane!.open({ width: 900, height: 760 }, async (page) => {
      await installClsRecorder(page);
      if (flow === "reload") {
        await installBoxTrackerOnLoad(page);
        if (seeded)
          await page.addInitScript(SEED, {
            ...seedArgs,
            frames: 10,
            once: true,
          });
      }
    });
    try {
      const report: StepReport[] = [];
      if (flow === "reload") {
        await settle(page);
        const composerBefore = await composerBottom(page);
        const rowBefore = await newestRowTop(page);
        if (seeded) await page.evaluate(() => sessionStorage.setItem("cmuxSeedShift", "1"));
        // The tracker starts on the new document's DOMContentLoaded; the clock stops once the chat is
        // back and has held still.
        await page.reload();
        await page.getByText("Answer 10:", { exact: false }).first().waitFor({ timeout: 120_000 });
        await settle(page);
        const shift: BoxShift = await page.evaluate(() => window.cmuxBoxTracker!.stop());
        const follow = shift.follow!;
        const back = Math.abs((await newestRowTop(page)) - rowBefore);
        const composer = Math.round(Math.abs((await composerBottom(page)) - composerBefore) * 10) / 10;
        report.push({
          step: "reload",
          // A newest row that comes back elsewhere moved, whatever the frames between showed.
          stray: Math.round(Math.max(follow.worst, back) * 10) / 10,
          strays: [
            ...(back > 0.5
              ? [
                  {
                    label: "newest row's place after the reload",
                    dy: back,
                    dx: 0,
                    follow: 0,
                    frame: -1,
                  },
                ]
              : []),
            ...follow.stray.slice(0, 4).map(({ label, dy, dx, follow, frame }) => ({
              label,
              dy,
              dx,
              follow,
              frame,
            })),
          ],
          composer,
          cls: await takeCls(page),
        });
      } else {
        await installBoxTracker(page);
        // By count, not by set: a flow can draw a row whose text an earlier flow already drew ("/compact").
        const rowsBefore = new Map<string, number>();
        for (const text of await page.locator(TRANSCRIPT_ROW).allInnerTexts())
          rowsBefore.set(text, (rowsBefore.get(text) ?? 0) + 1);
        for (const [index, [step, play]] of flows(turn)[flow].entries()) {
          report.push(await measure(page, step, () => play(pane!, page), seeded && index === 1));
          if (SHOWS[step]) expect(await page.locator(".acpmux-scroll").innerText()).toMatch(SHOWS[step]!);
        }
        // The flow drew what it plays (a fixture that renders nothing would pass with 0px): rows it did
        // not find (by text: the transcript is virtual, so a count can fall as rows grow and older ones
        // leave the window), and the flow's own text in the transcript.
        const drawn = await page.locator(TRANSCRIPT_ROW).allInnerTexts();
        const seen = new Map<string, number>();
        const added = drawn.filter((text) => {
          seen.set(text, (seen.get(text) ?? 0) + 1);
          return seen.get(text)! > (rowsBefore.get(text) ?? 0);
        });
        expect(added.length).toBeGreaterThan(0);
        expect(drawn.join("\n")).toContain(DRAWN[flow]);
      }
      for (const entry of report)
        console.log(
          `flow-shift ${engine} ${flow}${seeded ? " (seeded)" : ""} ${entry.step}: stray ${entry.stray}px composer ${entry.composer}px cls ${entry.cls} ${entry.strays
            .slice(0, 2)
            .map((stray) => `${stray.label} ${stray.dy}px`)
            .join("; ")}`.slice(0, 380),
        );
      reports[`${engine} ${flow}${seeded ? " seeded" : ""}`] = report;
      return report;
    } finally {
      await page.close();
    }
  };

  for (const [engine] of engines)
    describe(engine, () => {
      for (const flow of FLOWS) {
        test(`${flow}: the transcript and the composer stay inside the flow's shift budget`, async () => {
          const budget = { ...BUDGET[flow], ...KNOWN[`${engine} ${flow}`] };
          expect(overBudget(await runFlow(engine, flow, false), budget)).toEqual([]);
        });
        // The control, once per flow (Chromium, or the one engine that launched).
        if (engine === engines[0]![0])
          test(`${flow}: a seeded ${SEED_PX}px jump breaks the budget`, async () => {
            const over = overBudget(await runFlow(engine, flow, true), BUDGET[flow]);
            expect(over.some((line) => line.includes("stray"))).toBe(true);
            expect(over.some((line) => line.includes("composer"))).toBe(true);
          });
      }
    });
});
