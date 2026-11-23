// cmux-web-test-timeout: 900
// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// A turn that streams text, runs tool calls and ends moves no row the reader sees except by the one
// follow every row shares (Leo, after asking how the reference transcript does its tool calls and
// message sends: "it doesn't layout shift... we shouldnt either!"). In the reference transcript a
// row never jumps when a tool call starts, updates or finishes, text streams in without reflowing
// the rows above it, the composer keeps its place, and a run that finishes and folds to one line
// gives its room back at the tail, not above the reader.
//
// The page is the pane's dev entry and a stand-in acpmux (support/papercutChat.ts), real Chromium
// and WebKit. One turn is replayed in steps: the send, the reply's first text in deltas, a command
// that starts, streams its output and finishes, more text, a second command, the final reply, the
// turn's end. Each step is tracked frame by frame with the gallery's box tracker (src/gallery/shift.ts,
// judged by followJudge.ts): every transcript row in view, and the composer, by where it paints.
// A stray move is a row (or the composer) that moved other than by the frame's shared follow or by
// a row above it growing; each one is reported with its step, row, px and the follow.
//
// Arms: the reader at the latest row (the view follows) or scrolled up into the turn (nothing in
// view may move at all), each with the runs left as the pane draws them and with the reader opening
// the first command while it runs.
//
//   CMUX_BROWSER_TESTS=1 bun test test/agent-chat-stream-no-shift-browser.test.ts
// STREAM_SHIFT_OUT=DIR (or $FAST_CHECKS_OUT) writes the report and, with STREAM_SHIFT_SHOTS=1, a still
// after each step in light and dark.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import type { BoxShift } from "../src/gallery/shift";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { installBoxTracker } from "./support/boxTrackerPage";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-chat-stream-no-shift-browser.test.ts", async () => {
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
      console.warn(`agent-chat-stream-no-shift: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("stream no shift", () => test("no engine", () => {}));
    return;
  }

  const OUT = process.env.STREAM_SHIFT_OUT ?? process.env.FAST_CHECKS_OUT;
  const SHOTS = process.env.STREAM_SHIFT_SHOTS === "1" && !!OUT;
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const call = (id: string, command: string) =>
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command },
    });
  const output = (id: string, text: string, status = "in_progress") =>
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status,
      content: [{ type: "content", content: { type: "text", text } }],
      ...(status === "completed" ? { rawOutput: { exit_code: 0 } } : {}),
    });
  const words = (text: string) => text.split(/(?<= )/);
  const LOG = Array.from({ length: 14 }, (_, line) => `ok ${line + 1} - retry cap holds for case ${line + 1}`);

  type Pane = Awaited<ReturnType<typeof papercutPane>>;
  type Play = (pane: Pane, page: Page) => Promise<void>;
  // fixed-wait: the stream's own cadence (deltas some tens of ms apart, as an agent sends them) is the input under test.
  const pause = (ms: number) => Bun.sleep(ms);
  const stream =
    (texts: string[], gap = 35): Play =>
    async (pane) => {
      for (const text of texts) {
        pane.record("agent_message_chunk", chunk(text), "in");
        await pause(gap);
      }
    };

  /// The turn, step by step. `turn` names this replay's ids so the arms share one chat.
  const steps = (turn: string): [string, Play][] => [
    [
      "send",
      // Typed in the composer and sent with Return, as the reader does; the stand-in acpmux echoes the
      // prompt under the id the page sent it with.
      async (pane, page) => {
        const text = `Find the retry loops (${turn})`;
        await page.locator(".acpmux-composer-box [contenteditable=true]").first().click();
        await page.keyboard.type(text);
        const before = pane.prompts.length;
        const asked = pane.sent("session/prompt", pane.methods.filter((method) => method === "session/prompt").length);
        await page.keyboard.press("Enter");
        await asked;
        const promptId = pane.prompts[before]?._meta?.acpmux?.promptId as string;
        pane.record("user_message", { text, promptId, turnId: `t-${turn}` });
        pane.record("turn_started", {});
      },
    ],
    [
      "text",
      stream(
        words(
          "I'll look for every retry loop first. The fetch client, the socket reconnect and the upload queue " +
            "each sleep on their own, so I'll run the retry tests to see which caps hold.\n\n",
        ),
      ),
    ],
    [
      "tool 1 starts",
      async (pane) => {
        pane.record("tool_call", call(`${turn}-a`, "bun test retry"), "in");
      },
    ],
    [
      "tool 1 output",
      async (pane) => {
        for (let lines = 2; lines <= LOG.length; lines += 3) {
          pane.record("tool_call_update", output(`${turn}-a`, LOG.slice(0, lines).join("\n")), "in");
          await pause(60);
        }
      },
    ],
    [
      "tool 1 finishes",
      async (pane) => {
        pane.record("tool_call_update", output(`${turn}-a`, LOG.join("\n"), "completed"), "in");
      },
    ],
    [
      "text 2",
      stream(
        words("All fourteen cases pass. The upload queue still sleeps a fixed second, so I'll check its loop.\n\n"),
      ),
    ],
    [
      "tool 2 starts",
      async (pane) => {
        pane.record("tool_call", call(`${turn}-b`, "rg -n 'sleep' src/upload"), "in");
      },
    ],
    [
      "tool 2 finishes",
      async (pane) => {
        pane.record(
          "tool_call_update",
          output(`${turn}-b`, "src/upload/queue.ts:41: await sleep(1000)", "completed"),
          "in",
        );
      },
    ],
    [
      "final",
      stream(
        words(
          "The upload queue now calls `backoff(attempt)`, which stops at eight seconds, like the other two.\n\n" +
            "- fetch client\n- socket reconnect\n- upload queue\n\nEvery retry loop shares one capped backoff.",
        ),
      ),
    ],
    [
      "turn ends",
      async (pane) => {
        pane.record("turn_result", { status: "completed" });
      },
    ],
  ];

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
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return Math.round(node.scrollHeight - node.clientHeight - node.scrollTop);
    });

  /// Opens the newest run's line (the reader clicks it), when the pane draws it closed.
  const openNewestRun = (page: Page) =>
    page.evaluate(() => {
      const toggles = [
        ...document.querySelectorAll<HTMLElement>(".acpmux-scroll button.cv-tool.is-toggle[aria-expanded]"),
      ];
      const newest = toggles.at(-1);
      if (newest?.getAttribute("aria-expanded") === "false") newest.click();
      return newest?.getAttribute("aria-expanded") ?? "none";
    });

  type StepReport = {
    step: string;
    worst: number;
    stray: { label: string; dy: number; dx: number; follow: number; frame: number }[];
    /// Scrolled-up arm: the most any rested row in view moved (it must not move at all).
    moved: number;
    moves: { label: string; dy: number; frame: number }[];
    composer: number;
    fromEnd: number;
    /// The sent prompt's top against the transcript's top after the step.
    prompt: number | null;
  };
  const reports: Record<string, StepReport[]> = {};

  type Arm = { name: string; at: "latest" | "scrolled-up"; open: boolean };
  const ARMS: Arm[] = [
    { name: "latest", at: "latest", open: false },
    { name: "latest, run opened", at: "latest", open: true },
    { name: "scrolled up", at: "scrolled-up", open: false },
  ];

  const browsers = new Map<string, Browser>();
  let pane: Pane | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const first = browsers.values().next().value!;
    pane = await papercutPane(() => current ?? first, { turns: 10, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    for (const browser of browsers.values()) await browser.close();
    if (OUT) {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, "stream-shift.json"), JSON.stringify(reports, null, 2));
    }
  });
  let current: Browser | undefined;
  let serial = 0;

  const composerTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-composer-box")!.getBoundingClientRect().bottom);
  /// The sent prompt's row: its top against the transcript's top (null when it is not drawn).
  const promptTop = (page: Page, text: string) =>
    page.evaluate(
      ({ text, rowSelector }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const row = [...scroller.querySelectorAll<HTMLElement>(rowSelector)].find((each) =>
          each.textContent?.includes(text),
        );
        return row
          ? Math.round((row.getBoundingClientRect().top - scroller.getBoundingClientRect().top) * 10) / 10
          : null;
      },
      { text, rowSelector: TRANSCRIPT_ROW },
    );

  for (const [engine] of engines)
    describe(engine, () => {
      for (const arm of ARMS)
        test(`${arm.name}: a streamed turn with two runs moves no row but by the follow`, async () => {
          current = browsers.get(engine)!;
          const turn = `${engine}-${++serial}`;
          const page = await pane!.open({ width: 900, height: 760 });
          try {
            await installBoxTracker(page);
            const report: StepReport[] = [];
            const all = steps(turn);
            for (const [index, [step, play]] of all.entries()) {
              // Scrolled up: the send and the first text at the latest row, then the reader wheels up into
              // the turn and reads while the rest arrives under the view.
              if (arm.at === "scrolled-up" && step === "tool 1 starts") {
                await page.mouse.move(450, 200);
                for (let moved = 0; moved < 240; moved += 40) await page.mouse.wheel(0, -40);
                await settle(page);
              }
              const composerBefore = await composerTop(page);
              await page.evaluate(() => window.cmuxBoxTracker!.start());
              await play(pane!, page);
              await settle(page);
              const shift: BoxShift = await page.evaluate(() => window.cmuxBoxTracker!.stop());
              if (arm.open && step === "tool 1 starts") {
                await openNewestRun(page);
                await settle(page);
              }
              const follow = shift.follow!;
              const rows = shift.moves.filter((move) => move.label.includes("[row "));
              const entry: StepReport = {
                step,
                worst: follow.worst,
                stray: follow.stray.map(({ label, dy, dx, follow, frame }) => ({ label, dy, dx, follow, frame })),
                moved: Math.max(0, ...rows.map((move) => Math.abs(move.dy))),
                moves: rows.slice(0, 8).map(({ label, dy, frame }) => ({ label, dy, frame })),
                composer: Math.round(Math.abs((await composerTop(page)) - composerBefore) * 10) / 10,
                fromEnd: await fromEnd(page),
                prompt: await promptTop(page, `Find the retry loops (${turn})`),
              };
              report.push(entry);
              const short = (arm.at === "latest" ? entry.stray : entry.moves)
                .slice(0, 3)
                .map((move) => `${move.label.replace(/^.*\[row /, "").replace(/\]$/, "")} ${move.dy}px`)
                .join("; ");
              console.log(
                `stream-shift ${engine} ${arm.name} #${index} ${step}: stray ${entry.worst}px moved ${entry.moved}px composer ${entry.composer}px end ${entry.fromEnd}px prompt ${entry.prompt}px ${short}`.slice(
                  0,
                  380,
                ),
              );
              if (SHOTS && OUT && arm.name === "latest") {
                fs.mkdirSync(path.join(OUT, "frames"), { recursive: true });
                for (const scheme of ["light", "dark"] as const) {
                  await page.emulateMedia({ colorScheme: scheme });
                  await settle(page);
                  await page.screenshot({ path: path.join(OUT, "frames", `${engine}-${scheme}-${index}.png`) });
                }
              }
            }
            reports[`${engine} ${arm.name}`] = report;
            if (arm.at === "latest") {
              // Send to top: the sent prompt lands at the top of the view (under the thread's top padding)
              // and holds that pixel through the whole turn, while the turn fills the room under it and
              // then grows on below the view.
              const sent = report[0]!.prompt;
              expect(sent).not.toBeNull();
              expect(sent!).toBeLessThanOrEqual(40);
              expect(
                report
                  .filter((entry) => entry.prompt === null || Math.abs(entry.prompt - sent!) > 1)
                  .map((entry) => `${entry.step}: prompt at ${entry.prompt}px, sent at ${sent}px`),
              ).toEqual([]);
              // The prompt holding its pixel holds every row above it (rows stay packed): no follow carries
              // the view. The rows under the reply move down only by its growth, which the judge below
              // allows and nothing else.
              // No row strays from the follow, at any step.
              expect(
                report
                  .filter((entry) => entry.worst > 1)
                  .map((entry) => `${entry.step}: ${entry.worst}px ${entry.stray[0]?.label}`),
              ).toEqual([]);
            } else {
              // Scrolled up: what the reader reads holds its pixels while the turn grows under it.
              expect(
                report
                  .slice(2)
                  .filter((entry) => entry.moved > 1)
                  .map((entry) => `${entry.step}: ${entry.moved}px ${entry.moves[0]?.label}`),
              ).toEqual([]);
            }
            // The composer never moves.
            expect(
              report.filter((entry) => entry.composer > 1).map((entry) => `${entry.step}: ${entry.composer}`),
            ).toEqual([]);
          } finally {
            await page.close();
          }
        });
    });
});
