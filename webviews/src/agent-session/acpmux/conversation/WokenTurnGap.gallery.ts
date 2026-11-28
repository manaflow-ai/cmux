// l10n-allow-file: gallery fixtures (a prompt and the agent's replies), not shipped UI.
// A turn a background command's end woke, right under the ended turn's footer. Leo, 2026-11-15:
// "idk it loads funny sometimes", on a reply's footer, an empty band, then a lone "Read …output" row
// floating under it. The "Background command finished" line between the two turns is hidden on
// purpose (its result goes onto the call that started the command), and the woken turn's first tool
// row stood the full turn gap under the footer (transcriptGrid.ts MARK_OPENS_TURN). The variants
// replay acpmux's events through the pane's own client (fixtures/recording.ts), so they show what
// the code makes; `<html data-woken-gap>` picks the look (model.ts `wokenGapLook`). Synthetic data.
// test/woken-turn-gap.test.ts holds the shipped gap in the model.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";

type Step = [string, string, Record<string, unknown>];
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
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

/// A person's turn that started a background command and ended on its reply, then the turn the
/// command's end woke: it reads the command's output, then replies. As acpmux records it in Leo's
/// chat, the woken turn has no prompt of its own: only its background_turn records bracket it.
export function wokenTurnGapEvents(running = false) {
  const steps: Step[] = [
    ["mux", "user_message", { text: "Clean up after the merged helpers", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    call("reclaim", "Reclaim the two merged-branch worktrees", "execute", {
      command: "wt reclaim --apply",
      run_in_background: true,
    }),
    say("Both fixes merged. I'm also removing the two worktrees those helpers left behind."),
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
    call("read-output", "Read b9yur0qrw.output", "read"),
    say(
      "The two worktrees are still there. `wt reclaim` keeps a worktree a live session holds, and both still have one. I'll remove them once those sessions end.",
    ),
    ["mux", "background_turn", { state: "ended", id: "bg-reclaim", trigger: "task_notification", quiet: false }],
  ];
  // Still running: the woken turn's read and a command in flight, no reply or end yet.
  if (running) steps.splice(-2, 2, call("ls", "ls -la .wt", "execute", { command: "ls -la .wt" }));
  const start = running ? minutesAgo(1) - steps.length * 6_000 : minutesAgo(20);
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: start + index * 6_000,
    dir,
    kind,
    msg,
  }));
}

const recordingOf = (running: boolean) => ({
  events: async () =>
    `${wokenTurnGapEvents(running)
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
});
const recording = recordingOf(false);
const working = () => {
  const base = chat([]);
  return {
    ...base,
    isWorking: true,
    sessions: base.sessions.map((session) => ({ ...session, status: "working" as const })),
  };
};

export default agentPaneEntry({
  id: "agent-pane.woken-turn-gap",
  title: "A turn a background task woke, under the ended turn's footer",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/model.ts#opensBackgroundTurn", "agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    block: {
      note: "Shipped: the woken turn's work folds under its Worked for, the run gap (16) under the footer (footer-working-16), never the empty turn gap. The footer already closes the turn above; a reply there keeps a prompt's turn gap.",
      snapshot: chat([]),
      recording,
    },
    turn: {
      note: "Before: the full turn gap (32) over the tool row, with no prompt in it, so the row floats under the footer.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "woken-gap": "turn" },
    },
    tail: {
      note: "Alternative: the tool row takes the hidden notice's place, flush under the footer as a status line there sits. It reads as the ended turn's tail.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "woken-gap": "tail" },
    },
    // Leo, 2026-11-25: "did we identify the cause between the gap here? betwen the copy branch etc
    // buttons and the next working for?" The woken turn still running under the footer.
    working: {
      note: "Shipped, while the woken turn runs: its first tool row stands the block gap under the footer (24), as any step under a footer does; once it ends, its Worked for stands 16. test/woken-turn-gap.test.ts holds both.",
      snapshot: working(),
      recording: recordingOf(true),
    },
    // Leo, 2026-11-25: "did we identify the cause between the gap here? betwen the copy branch etc buttons and the
    // next working for?" The footer row to the woken turn's Worked for: `<html data-footer-working-gap>`
    // (transcriptGrid.ts `footerWorkingGapLook`). `run` (16) ships.
    "footer-working-24": {
      note: "Before: Worked for stood the block gap (24) under the footer row; with the buttons centred in their 32 row and the line in its 32 row it reads as ~38 from the icons to the words.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "footer-working-gap": "block" },
    },
    "footer-working-16": {
      note: "Shipped: the run gap (16), as Worked for stands under any one-line row. ~30 from the icons to the words.",
      snapshot: chat([]),
      recording,
    },
    "footer-working-8": {
      note: "Alternative: the footer gap (8), as the footer sits under its reply. ~22 from the icons to the words.",
      snapshot: chat([]),
      recording,
      documentAttributes: { "footer-working-gap": "footer" },
    },
  },
});
