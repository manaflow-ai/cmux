// l10n-allow-file: gallery fixtures (sample prompts, commands, thoughts and replies), not shipped UI.
// A run of background commands that finished folds into one counted line, as a tool call's line
// reads: "14 background commands finished, sent 2 messages, received 9 messages". Thoughts, sends,
// received messages and a subagent's end between them fold into it (foldPolicy.ts). Leo,
// 2026-11-12, on 10-20 "Background command completed" rows drawn one by one inside a finished turn's
// "Worked for 4m 44s": "how come these aren't folded? they were missed in the logic?" and "this is
// prob pretty obvious as fold candidates... tho ig a 'completed' is technically a more special cased
// version?" Tests: conversation/foldPolicy.test.tsx.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";
import { backgroundRunRowId } from "./backgroundRuns";
import { SUBAGENT_DONE } from "../subagents/subagentRows";

const DESCRIPTIONS = [
  "Fetch job logs with escapes stripped",
  "Wait for job logs",
  "Find canonical_path imports at head",
  "Wait for imports lookup",
  "Block until worktrees ready",
  "Locate unused import and review text",
  "Create worktree for platform branch",
  "Wait for review lookup to finish",
  "Create worktree for the fix branch",
  "Wait for both worktrees to be created",
  "Create worktree with ack",
  "Read react-apps-check failures",
  "Fetch base and check test file",
  "Wait briefly for checkouts",
];

let seq = 0;
const done = (minutes: number, state: "completed" | "failed" | "stopped" = "completed", text?: string): AcpmuxRow => {
  const id = `gallery-bg-${(seq += 1)}`;
  return row("backgroundTask", minutes, {
    id,
    backgroundTask: {
      toolCallId: `${id}-call`,
      command: text ?? DESCRIPTIONS[(seq - 1) % DESCRIPTIONS.length]!,
      state,
      ...(state === "failed" && { exitCode: 1 }),
    },
  });
};
const thinking = (minutes: number, text: string) => activity([thought(text)], minutes);
const send = (minutes: number, to: string, text: string) =>
  activity(
    [
      tool(`acpmux send ${to}`, "execute", "completed", {
        command: `acpmux send ${to} '${text}'`,
        output: "queued\n",
        exitCode: 0,
      }),
    ],
    minutes,
  );
/// `n` messages from other agents, in a row: the pane draws them as one "Received N messages" row.
const received = (minutes: number, n: number): AcpmuxRow[] =>
  Array.from({ length: n }, (_, i) => {
    const name = ["deputy", "disk-helper", "review-lane"][i % 3]!;
    const text = `Status ${i + 1}: green, nothing for you.`;
    return row("user", minutes - i * 0.001, {
      incoming: { kind: "message", message: { name, sessionId: name, text, raw: text } },
    });
  });
const subagentDone = (minutes: number) =>
  row(SUBAGENT_DONE, minutes, {
    subagents: [{ id: "gallery-sub", name: "Codex desktop auth", state: "done", startedAt: 0, endedAt: 1 } as never],
  });

/// Leo's turn: 14 background commands that finished, between thoughts, two sends, an inbox batch and
/// a subagent's end, then the answer. `failAt` makes that command fail; `stopAt` stops one.
function leosTurn({ failAt, stopAt }: { failAt?: number; stopAt?: number } = {}): AcpmuxRow[] {
  seq = 0;
  let n = 0;
  const next = (minutes: number) => {
    n += 1;
    return done(minutes, n === failAt ? "failed" : n === stopAt ? "stopped" : "completed");
  };
  return [
    user("Why does the Codex app say account authentication unavailable?", 20),
    activity([tool("Read auth.json", "read", "completed", { inputSummary: "~/.codex/auth.json" })], 19.9),
    next(19),
    thinking(18.9, "The disk helper seems to have wrapped up; checking its note before I answer."),
    send(18.8, "fix-chat-flip-loop", "the reorder is fixed, please confirm on your side"),
    next(18),
    next(17.5),
    next(17),
    next(16.5),
    thinking(16.4, "Sorting out why the review lookup is slow; it reads every PR."),
    next(16),
    next(15.5),
    next(15),
    next(14.5),
    ...received(14.4, 9),
    next(14),
    subagentDone(13.9),
    next(13.5),
    thinking(13.4, "Passing a note to the bottom-area helper."),
    send(13.3, "audit-chat-bottom", "notice rows draw below the reply that triggered them"),
    next(13),
    next(12.5),
    next(12),
    assistant(
      "**Codex app sign-in:** the saved login expired and it cannot renew it. In Codex Desktop, open Settings, Account, then sign in again.",
      11.9,
    ),
    summary(11.85, { status: "completed", durationMs: 284_000, toolCount: 18 }),
  ];
}

/// Background commands that finished after the turn's answer, as the bottom of Leo's screenshot.
function tail(): AcpmuxRow[] {
  seq = 100;
  return [
    user("Check the three lanes and land what is green", 12),
    activity([tool("gh pr checks", "execute", "completed", { command: "gh pr checks 41527" })], 11.9),
    assistant("Two of three are green; landing them now.", 11.5),
    summary(11.45, { status: "completed", durationMs: 30_000, toolCount: 1 }),
    done(11, "completed", "export ACPMUX_CALLER_SUBAGENT=general-purpose:a858dde; wt new cmux landing-cost"),
    thinking(10.9, "The landing-cost worktree is ready."),
    done(10.5, "completed", "Create worktree for landing-cost branch"),
    done(10, "completed", "Wait for landing-cost checkout"),
  ];
}

const openSelector =
  (selector: string): Play =>
  async (ctx) => {
    const node = () => ctx.document.querySelector<HTMLElement>(selector);
    if (node()?.getAttribute("aria-expanded") === "false") {
      await ctx.click({ selector });
      await ctx.waitFor(() => node()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
    }
  };
const openWorked = openSelector(".cv-worked");
const RUN = `[data-row-id="${backgroundRunRowId("gallery-bg-1")}"] .cv-background-turn`;
const openWorkedAndRun: Play = async (ctx) => {
  await openWorked(ctx);
  await openSelector(RUN)(ctx);
};

const variant = (note: string, rows: AcpmuxRow[], play?: Play): AgentPaneVariant => ({
  note,
  snapshot: chat(rows, { title: "Background command runs" }),
  ...(play && {
    play,
    checks: { layoutShiftMax: { value: 0.6, reason: "Opening a fold reveals its rows below the clicked line." } },
  }),
});

export default agentPaneEntry({
  id: "agent-pane.background-command-runs",
  title: "Background command runs fold into one line",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/foldPolicy.ts",
    "agent-session/acpmux/conversation/backgroundRuns.ts",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  variants: {
    after: variant(
      "Leo's turn, its Worked for opened: 14 background commands that finished, with the thoughts, sends, 9 received messages and the subagent's end between them, are one line with the command glyph, 14 background commands finished, sent 2 messages, received 9 messages.",
      leosTurn(),
      openWorked,
    ),
    before: variant(
      "Before: the same rows one by one, as they drew until now. Here the line is opened, which draws each row in its place under it.",
      leosTurn(),
      openWorkedAndRun,
    ),
    failed: variant(
      "The 7th command failed: it stays in sight on its own row and splits the run into two lines, 6 and 8 commands.",
      leosTurn({ failAt: 7 }),
      openWorked,
    ),
    stopped: variant(
      "A stopped command among them: the line counts updates, 14 background updates.",
      leosTurn({ stopAt: 3 }),
      openWorked,
    ),
    tail: variant(
      "Commands that finished after the turn's answer (the bottom of Leo's screenshot) fold into one line in sight, 3 background commands finished; the thought between them goes with it.",
      tail(),
    ),
  },
});
