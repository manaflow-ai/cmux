// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-15: "idk it loads funny sometimes", on a reply's footer (copy, time, read aloud, ⋯),
// then an empty band, then a lone "Read b9yur0qrw.output" row floating under it. A background
// command's end woke the agent after its turn had ended: the "Background command finished" line
// between the two turns is hidden on purpose (its result goes onto the call that started the task,
// backgroundTurns.ts `drawsBackgroundLine`), and the woken turn's first tool row stood the full turn
// gap (transcriptGrid.ts MARK_OPENS_TURN) under the footer, with nothing in it. The footer already
// closes the turn above, so a tool row under it stands the block gap any row under a footer stands;
// a reply there keeps the turn gap a prompt has (design/chat-transcript.md, cmux#39023).
import { afterEach, expect, test } from "bun:test";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import {
  FOOTER_WORKING_GAP_LOOKS,
  MARK_FOOTER_ROW,
  MARK_INDICATOR,
  MARK_STATUS,
  MARK_STEP,
  MARK_WORKED,
  TRANSCRIPT_BLOCK_GAP,
  TRANSCRIPT_FOOTER_GAP,
  TRANSCRIPT_RUN_GAP,
  TRANSCRIPT_TURN_GAP,
  rowMark,
  transcriptGap,
} from "../src/agent-session/acpmux/transcriptGrid";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

const g = globalThis as { document?: unknown };
const documentBefore = g.document;
/// `<html data-footer-working-gap>` (transcriptGrid.ts `footerWorkingGapLook`), as rowGapTable.test.ts stubs it.
const footerWorkingLook = (look: string | undefined) => {
  g.document = look === undefined ? documentBefore : { documentElement: { dataset: { footerWorkingGap: look } } };
};

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
  g.document = documentBefore;
});

const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const call = (id: string, title: string, kind: string, rawInput?: Record<string, unknown>): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "completed", rawInput }),
];

/// Leo's chat: a turn that started a background command and ended on its reply (a footer row under
/// it), then the command's end woke the agent, which read the command's output and replied.
const wokenAfterFooter = (opensWith: "tool" | "reply" | "running"): Step[] => [
  ["mux", "user_message", { text: "Reclaim the two merged-branch worktrees", turnId: "t1" }],
  ["mux", "turn_started", { turnId: "t1" }],
  call("reclaim", "wt reclaim --apply", "execute", { command: "wt reclaim --apply", run_in_background: true }),
  say("I'm also removing the two huge-blue worktrees those helpers left behind."),
  ["mux", "turn_result", { turnId: "t1", status: "completed" }],
  [
    "mux",
    "background_turn",
    {
      state: "started",
      id: "bg-reclaim",
      trigger: "task_notification",
      cause: {
        kind: "shell",
        status: "completed",
        weight: "result",
        origin: "reclaim",
        summary: 'Background command "Reclaim the two merged-branch worktrees" completed (exit code 0)',
      },
    },
  ],
  ...(opensWith === "reply" ? [] : [call("read-output", "Read b9yur0qrw.output", "read")]),
  ...((opensWith === "running"
    ? []
    : [
        say("The two huge-blue worktrees are still there. wt reclaim keeps a worktree a live session holds."),
        ["mux", "background_turn", { state: "ended", id: "bg-reclaim", trigger: "task_notification", quiet: false }],
      ]) as Step[]),
];

/// The drawn rows and the gap over the woken turn's first row, with the row over it.
/// `look`: the `<html data-footer-working-gap>` arm, set for the layout only (the client wants a real document).
async function gapUnderFooter(opensWith: "tool" | "reply" | "running", look?: string) {
  const daemon = fakeDaemon(record(wokenAfterFooter(opensWith)));
  const { client, rows } = await connect(daemon);
  try {
    const view = turnView(rows(), new Set()).filter((row) => row.kind !== "date") as AcpmuxRow[];
    // Its first row: its "Worked for" when its work folds under one (cmux#49592), else its reply.
    const first = view.findIndex(
      (row) => row.inBackground === "bg-reclaim" || row.id === "worked-backgroundTurn-bg-reclaim",
    );
    footerWorkingLook(look);
    const layout = layoutConversation(view, 720);
    footerWorkingLook(undefined);
    const gap = layout.tops[first]! - layout.tops[first - 1]! - layout.heights[first - 1]!;
    return { view, first, gap };
  } finally {
    client.close();
  }
}

for (const look of [undefined, "line"] as const) {
  const arm = look ?? "default";
  test(`a woken turn's Worked for under the ended turn's footer stands the run gap, not an empty turn gap (${arm} background look)`, async () => {
    if (look) globalThis.cmuxExperiments = { "background-turn-look": look };
    const { view, first, gap } = await gapUnderFooter("tool");
    // The background command's line draws nothing: its result is on its call.
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    // Right under the ended turn's footer row: its first row is the "Worked for" its "Read" call
    // folds under, once the woken turn ended (cmux#49592).
    expect(view[first]?.kind).toBe("worked");
    expect(view.some((row) => row.kind === "activity" && row.inBackground === "bg-reclaim")).toBe(false);
    expect(view[first - 1]?.kind).toBe("turnSummary");
    expect(rowMark(view[first - 1]!)).toBe(MARK_FOOTER_ROW);
    expect(gap).toBe(TRANSCRIPT_RUN_GAP);
  });

  test(`a woken turn that opens on its reply under a footer keeps the turn gap (${arm} background look)`, async () => {
    if (look) globalThis.cmuxExperiments = { "background-turn-look": look };
    const { view, first, gap } = await gapUnderFooter("reply");
    expect(view[first]?.kind).toBe("assistant");
    expect(view[first - 1]?.kind).toBe("turnSummary");
    expect(gap).toBe(TRANSCRIPT_TURN_GAP);
  });
}

// Leo, 2026-11-25: "did we identify the cause between the gap here? betwen the copy branch etc buttons
// and the next working for?" While the woken turn still runs, its first row under the ended turn's
// footer (its first tool row, a step) stands the same run gap (16) as its Worked for once it has ended, never a
// turn gap or a reserved band (gallery agent-pane.woken-turn-gap `working`). #56330 locked 24 here; 16 ships now.
test("a woken turn still running stands the run gap under the ended turn's footer", async () => {
  const { view, first, gap } = await gapUnderFooter("running");
  expect(view[first - 1]?.kind).toBe("turnSummary");
  expect(rowMark(view[first - 1]!)).toBe(MARK_FOOTER_ROW);
  expect(gap).toBe(TRANSCRIPT_RUN_GAP);
});

// The footer-to-"Working for" gap, per gallery arm (`<html data-footer-working-gap>`): `run` (16) ships; `block` (24,
// before) and `footer` (8) are the alternatives. Never flush (Leo, 2026-11-21: "there is no space before").
const ARMS = [
  [undefined, TRANSCRIPT_RUN_GAP],
  ["block", TRANSCRIPT_BLOCK_GAP],
  ["run", TRANSCRIPT_RUN_GAP],
  ["footer", TRANSCRIPT_FOOTER_GAP],
] as const;
test("the footer-working arms are 24, 16 and 8 at Interface Size 1", () => {
  expect(FOOTER_WORKING_GAP_LOOKS).toEqual({ block: 24, run: 16, footer: 8 });
});
for (const [look, want] of ARMS) {
  const arm = look ?? "default";
  test(`footer row to Working for / Worked for / the indicator / a step stands ${want} (${arm} arm)`, () => {
    footerWorkingLook(look);
    expect(transcriptGap(MARK_FOOTER_ROW, MARK_WORKED)).toBe(want);
    expect(transcriptGap(MARK_FOOTER_ROW, MARK_INDICATOR)).toBe(want);
    expect(transcriptGap(MARK_FOOTER_ROW, MARK_STEP)).toBe(want);
    // A status line under the footer is the ended turn's tail: flush in every arm.
    expect(transcriptGap(MARK_FOOTER_ROW, MARK_STATUS)).toBe(0);
    expect(want).toBeGreaterThan(0);
  });
  test(`a woken turn's Worked for stands ${want} under the ended turn's footer (${arm} arm)`, async () => {
    const { view, first, gap } = await gapUnderFooter("tool", look);
    expect(view[first]?.kind).toBe("worked");
    expect(rowMark(view[first - 1]!)).toBe(MARK_FOOTER_ROW);
    expect(gap).toBe(want);
    // While it runs, its first row under the footer is its tool row (a step): the same gap.
    // A reply there keeps the turn gap in every arm.
    const running = await gapUnderFooter("running", look);
    expect(running.view[running.first]?.kind).toBe("activity");
    expect(running.gap).toBe(want);
    expect((await gapUnderFooter("reply", look)).gap).toBe(TRANSCRIPT_TURN_GAP);
  });
}
