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
  MARK_FOOTER_ROW,
  TRANSCRIPT_BLOCK_GAP,
  TRANSCRIPT_TURN_GAP,
  rowMark,
} from "../src/agent-session/acpmux/transcriptGrid";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
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
const wokenAfterFooter = (opensWith: "tool" | "reply"): Step[] => [
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
  ...(opensWith === "tool" ? [call("read-output", "Read b9yur0qrw.output", "read")] : []),
  say("The two huge-blue worktrees are still there. wt reclaim keeps a worktree a live session holds."),
  ["mux", "background_turn", { state: "ended", id: "bg-reclaim", trigger: "task_notification", quiet: false }],
];

/// The drawn rows and the gap over the woken turn's first row, with the row over it.
async function gapUnderFooter(opensWith: "tool" | "reply") {
  const daemon = fakeDaemon(record(wokenAfterFooter(opensWith)));
  const { client, rows } = await connect(daemon);
  try {
    const view = turnView(rows(), new Set()).filter((row) => row.kind !== "date") as AcpmuxRow[];
    const first = view.findIndex((row) => row.inBackground === "bg-reclaim");
    const layout = layoutConversation(view, 720);
    const gap = layout.tops[first]! - layout.tops[first - 1]! - layout.heights[first - 1]!;
    return { view, first, gap };
  } finally {
    client.close();
  }
}

for (const look of [undefined, "line"] as const) {
  const arm = look ?? "default";
  test(`a woken turn's first tool row under the ended turn's footer stands the block gap, not an empty turn gap (${arm} background look)`, async () => {
    if (look) globalThis.cmuxExperiments = { "background-turn-look": look };
    const { view, first, gap } = await gapUnderFooter("tool");
    // The background command's line draws nothing: its result is on its call.
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    // Right under the ended turn's footer row: its first row is the "Read" call.
    expect(view[first]?.kind).toBe("activity");
    expect(view[first - 1]?.kind).toBe("turnSummary");
    expect(rowMark(view[first - 1]!)).toBe(MARK_FOOTER_ROW);
    expect(gap).toBe(TRANSCRIPT_BLOCK_GAP);
  });

  test(`a woken turn that opens on its reply under a footer keeps the turn gap (${arm} background look)`, async () => {
    if (look) globalThis.cmuxExperiments = { "background-turn-look": look };
    const { view, first, gap } = await gapUnderFooter("reply");
    expect(view[first]?.kind).toBe("assistant");
    expect(view[first - 1]?.kind).toBe("turnSummary");
    expect(gap).toBe(TRANSCRIPT_TURN_GAP);
  });
}
