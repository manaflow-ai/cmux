// l10n-allow-file: test fixture prompts and agent names, not shipped UI.
// A transcript row keeps the size and the parts it painted on its first frame (Leo, 2026-11-22, with
// a picture of his chat's "lane_place: brief path not inlined started working" line: "in these cases
// currently ... there's like a secondary animation that shifts as it recalculates to shrink stuff.
// idk. with better designs this won't happen").
// Here: the stand-in acpmux's chat is in a running turn, and records arrive live at the gaps his
// session recorded them (a background agent's `subagent_spawned`, its `Agent:` tool call 706 ms
// later; three agents started 30 ms and 1 s apart; commands that start and end). The recorder
// (support/firstFrameRects.ts) reads every painted frame, and no row or part of one may have another
// box than on its first painted frame. Named apart: a running line's light band, the turn's live
// line, and a run of commands, each of which changes by design. Real Chromium against the pane's dev entry
// (support/papercutChat.ts). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/chat-row-first-frame.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import {
  type RectReport,
  markFirstFrameRects,
  paintedFor,
  shiftLines,
  shiftTotals,
  startFirstFrameRects,
  stopFirstFrameRects,
} from "./support/firstFrameRects";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { SUBAGENT_STARTED } from "../src/agent-session/acpmux/subagents/subagentRows";

await requireBrowserLane("chat-row-first-frame.test.ts", async () => {
  setDefaultTimeout(300_000);

  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  const helper = (n: number) => `0190a000-0000-7000-8000-00000000fc01/toolu_helper${n}`;
  /// A background agent's start, as acpmux records it: its name, task and prompt at once.
  const spawned = (n: number, name: string): PapercutStep => [
    "in",
    "subagent_spawned",
    update(
      {
        sessionUpdate: "subagent_spawned",
        subagentSessionId: helper(n),
        name,
        task: name,
        prompt: `Fix ${name} and report what changed.`,
        background: true,
      },
      {
        subagents: [
          {
            id: helper(n),
            parent: null,
            name,
            task: name,
            prompt: `Fix ${name} and report what changed.`,
            state: "running",
            background: true,
            toolCallId: `toolu_helper${n}`,
          },
        ],
      },
    ),
  ];
  /// The agent's own `Agent:` call, which the harness reports after the start.
  const agentCall = (n: number, name: string): PapercutStep => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: `toolu_helper${n}`,
      title: `Agent: ${name}`,
      kind: "think",
      status: "in_progress",
      rawInput: { description: name, prompt: `Fix ${name} and report what changed.`, run_in_background: true },
    }),
  ];
  const progress = (n: number, name: string): PapercutStep => [
    "in",
    "subagent_progress",
    update(
      { sessionUpdate: "subagent_progress", subagentSessionId: helper(n), action: "Bash", toolUses: 1, tokens: 900 },
      {
        subagents: [
          {
            id: helper(n),
            parent: null,
            name,
            task: name,
            state: "running",
            background: true,
            action: "Bash",
            toolUses: 1,
            tokens: 900,
            elapsedMs: 1200,
          },
        ],
      },
    ),
  ];
  const command = (id: string, text: string): PapercutStep => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: text,
      kind: "execute",
      status: "in_progress",
      rawInput: { command: text },
    }),
  ];
  const ended = (id: string): PapercutStep => [
    "in",
    "tool_call_update",
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "completed",
      rawOutput: "ok",
      content: [{ type: "content", content: { type: "text", text: "ok" } }],
    }),
  ];
  const LONG =
    "cd /Users/dev/.wt/checkouts/cmux/lane--chat-row-first-frame-size/webviews && set -o pipefail && bun test test/chat-row-first-frame.test.ts test/row-arrival-settle.test.ts 2>&1 | tail -40";

  /// A running line's light band crosses its words on a loop (ShimmerText.tsx): paint, never layout.
  /// A row's gap target is the unseen click area over the room under it (VirtualTranscript.tsx): it is as
  /// tall as that room, which is the next row's to set when it arrives. The room itself is judged, as
  /// the recorder's "room under" part of the row below.
  const MOVES_BY_DESIGN = ".cv-shimmer__band, .cv-row-shimmer__band, .acpmux-row__gap";
  /// The turn's live line under the last row says what runs now, so its words change with each record.
  const LIVE_LINE = "thinking-live";
  const outsideLiveLine = (report: RectReport) =>
    shiftLines({ ...report, shifts: report.shifts.filter((shift) => shift.row !== LIVE_LINE) });

  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  /// Plays `steps` into an open chat, each after its gap in ms, and reports what shifted.
  const play = async (label: string, steps: [gapMs: number, name: string, step: PapercutStep][], width = 900) => {
    const pane = await papercutPane(() => browser, { turns: 6, running: true, ready: TRANSCRIPT_ROW });
    let page: Page | undefined;
    try {
      page = await pane.open({ width, height: 700 });
      await paintedFor(page, 1500);
      await startFirstFrameRects(page, TRANSCRIPT_ROW, MOVES_BY_DESIGN);
      for (const [gapMs, name, [dir, kind, msg]] of steps) {
        if (gapMs > 0) await paintedFor(page, gapMs);
        await markFirstFrameRects(page, name);
        pane.record(kind, msg, dir);
      }
      await paintedFor(page, 3000);
      const report = await stopFirstFrameRects(page);
      console.log(
        `first-frame ${label}: ${report.frames} frames, ${report.rows} rows, ${report.parts} parts, ${report.shifts.length} shifted`,
        JSON.stringify(shiftTotals(report)),
      );
      for (const line of shiftLines(report)) console.log(`first-frame ${label} shift: ${line}`);
      const texts = await page.evaluate(
        (rowSelector) =>
          [...document.querySelectorAll<HTMLElement>(rowSelector)]
            .slice(-6)
            .map((row) => `${row.dataset.rowId}: ${(row.textContent ?? "").slice(0, 90)}`),
        TRANSCRIPT_ROW,
      );
      console.log(`first-frame ${label} rows: ${JSON.stringify(texts)}`);
      return report;
    } finally {
      await page?.close();
      await pane.close();
    }
  };

  const NAME = "lane_place: brief path not inlined";

  test("one background agent's start line keeps its first frame", async () => {
    const report = await play("one-agent", [
      [0, "spawn", spawned(1, NAME)],
      [706, "agent-call", agentCall(1, NAME)],
      [300, "progress", progress(1, NAME)],
    ]);
    expect(report.rows).toBeGreaterThan(3);
    expect(report.parts).toBeGreaterThan(50);
    expect(outsideLiveLine(report)).toEqual([]);
  });

  // A turn has one start line (runningTray.ts `withSubagentLines`, cmux#51238; Leo, 2026-11-22: fifteen
  // "started working" lines filled the screen), so an agent the turn starts later joins that line and
  // redraws it: two names, then three as icons and a count (startedLineCrowd.experiment.ts). That is
  // the line's design, so the test logs what moves on the start line and holds every other row.
  test("agents started one after another move no row but the turn's start line", async () => {
    const names = [NAME, "Audit chat row renderings", "Prepush gate cost and offload"];
    const lines: string[] = [];
    for (const width of [900, 520]) {
      const report = await play(
        `three-agents-${width}`,
        [
          [0, "spawn-1", spawned(1, names[0]!)],
          [30, "spawn-2", spawned(2, names[1]!)],
          [1000, "spawn-3", spawned(3, names[2]!)],
          [300, "agent-call-1", agentCall(1, names[0]!)],
        ],
        width,
      );
      const startLine = report.shifts.filter((shift) => shift.row.startsWith(SUBAGENT_STARTED));
      console.log(
        `first-frame three-agents-${width} start line: ${JSON.stringify(shiftTotals({ ...report, shifts: startLine }))}`,
      );
      lines.push(
        ...outsideLiveLine({
          ...report,
          shifts: report.shifts.filter((shift) => !shift.row.startsWith(SUBAGENT_STARTED)),
        }),
      );
    }
    expect(lines).toEqual([]);
  });

  // A run of commands is one row that grows a line per command, and its head counts them, so the
  // run's own row changes as commands join and end (the fold's design, conversation/ToolGroupRow.tsx).
  // Every other row holds: nothing above the run is measured again or placed again.
  test("commands that start and end move no row but their own run", async () => {
    const report = await play("commands", [
      [0, "long-starts", command("long1", LONG)],
      [400, "short-starts", command("short1", "git status")],
      [600, "long-ends", ended("long1")],
      [200, "short-ends", ended("short1")],
    ]);
    const run = report.shifts.filter((shift) => shift.row.startsWith("activity-"));
    console.log(`first-frame commands run: ${JSON.stringify(shiftTotals({ ...report, shifts: run }))}`);
    expect(
      outsideLiveLine({ ...report, shifts: report.shifts.filter((shift) => !shift.row.startsWith("activity-")) }),
    ).toEqual([]);
  });
});
