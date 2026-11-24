// l10n-allow-file: gallery fixtures (sample prompts, notices and replies), not shipped UI.
// One fold rule for every turn (hq#18554 ask 4; Leo, 2026-11-22: "the notices/etc, they dont properly
// fold in when your turn ends"): once a turn has ended, its work sits under its one closed "Worked
// for", whatever started it. Each variant is a shape from the coordinator chat in Leo's screenshots,
// the texts replaced. Before, (a), (b) and (d) drew their thought and send as rows beside the reply.
// The turn-view test is conversation/turnEndLooseRows.test.ts.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const line = (id: string, minutes: number, background: Record<string, unknown>): AcpmuxRow =>
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: { id, running: false, hasRows: true, quiet: false, reason: "result", ...background },
  } as Partial<AcpmuxRow>);
const send = () => tool("SendMessage", "other", "completed");
const notice = (text: string, minutes: number, id: string) =>
  user(text, minutes, {
    id,
    incoming: {
      kind: "inbox",
      notice: {
        threads: [
          {
            threadId: `topic:${id}`,
            label: "pr/manaflow-ai/cmux/50201",
            from: ["merge-queue"],
            count: 1,
            blocker: true,
            promptIds: [`${id}-prompt`],
          },
        ],
      },
    },
  } as Partial<AcpmuxRow>);

/// (a) and (b): a notice's turn, then two turns the agent ran on its own.
const wakes = (): AcpmuxRow[] => [
  notice("[notice from merge-queue] merge queue: cmux#50201 merged", 12, "gallery-loose-notice-a"),
  assistant("cmux#50201 merged. Nothing else needs you.", 11.8),
  summary(11.8, { status: "completed", durationMs: 9_000 }),
  // (a) A wake with no cause: one thought, then its reply.
  line("gallery-loose-a", 9, { trigger: "system" }),
  activity([thought("I already asked the helper about the header summary; its PR is in review.")], 8.9, {
    inBackground: "gallery-loose-a",
  }),
  assistant("The header summary fix is in review; I'll tell you when it lands.", 8.8, {
    inBackground: "gallery-loose-a",
  }),
  // (b) A failed subagent step woke it: a thought and a send.
  line("gallery-loose-b", 6, {
    trigger: "task_notification",
    cause: { kind: "subagent_step", status: "failed", weight: "failure", summary: "sed -n 480,490p src/lib.rs" },
  }),
  activity([thought("The runner pool's cost after the change looks high; asking its helper."), send()], 5.9, {
    inBackground: "gallery-loose-b",
  }),
  assistant("The runner pool fix hasn't merged yet; I asked its helper for the after numbers.", 5.8, {
    inBackground: "gallery-loose-b",
  }),
  summary(5.8, { status: "completed", durationMs: 14_000, toolCount: 1, inBackground: "gallery-loose-b" }),
];

/// (c): a steer carried into its own turn, its thought, then a second steer landing in that turn.
const steered = (): AcpmuxRow[] => [
  user("clearly there's still improper folds and stuff", 14),
  activity([thought("Three loose folds in the screenshot."), send()], 13.9),
  assistant("I see three loose folds in your screenshot and gave them to a helper.", 13.6),
  summary(13.6, { status: "completed", durationMs: 40_000, toolCount: 1 }),
  user("you guys also need to be testing flicks of extremely fast input", 13.5),
  activity([thought("I'm thinking about which helper to route this to.")], 13.4),
  user("the make cmux yours UI, we need to hill climb it", 13, { steer: "landed" } as Partial<AcpmuxRow>),
  activity(
    [thought("Make cmux yours is the welcome card."), tool("rg -n welcome webviews/src", "execute", "failed")],
    12.9,
  ),
  assistant("I started two helpers for your last two messages.", 12.4),
  summary(12.4, { status: "completed", durationMs: 69_000, toolCount: 1 }),
];

/// (d): a person's turn, a background task's end with a thought and a send, then a notice's turn.
const bgDone = (): AcpmuxRow[] => [
  user("when did we decide to omit the agent icon", 10),
  assistant("I've given this to the helper already auditing icons.", 9.8),
  summary(9.8, { status: "completed", durationMs: 29_000 }),
  line("bg-done-gallery-loose-d", 9, {
    trigger: "task_notification",
    cause: { kind: "shell", status: "completed", weight: "result", summary: "Wait for PR CI in background" },
  }),
  activity([thought("Checks on the PR are failing: four of them on base."), send()], 8.9, {
    inBackground: "bg-done-gallery-loose-d",
  }),
  assistant("I sent both PRs to the helper that owns them.", 8.7, { inBackground: "bg-done-gallery-loose-d" }),
  summary(8.7, { status: "completed", durationMs: 12_000, toolCount: 2, inBackground: "bg-done-gallery-loose-d" }),
  notice("[notice from merge-queue] merge queue: cmux#50202 stopped, head moved", 8.5, "gallery-loose-notice-d"),
  activity([thought("I'm still not sure who owns that PR.")], 8.4),
  assistant("Nothing new for you: cmux#50202 got a new commit, so its land stopped.", 8.3),
  summary(8.3, { status: "completed", durationMs: 6_000 }),
];

export default agentPaneEntry({
  id: "agent-pane.turn-end-loose-rows",
  title: "Every ended turn folds its work",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/backgroundTurns.ts"],
  variants: {
    "a-wake-thought": {
      note: "(a) A notice's turn, then a wake with no cause: one thought and a reply. The thought sits under its own closed Worked for, the reply in sight.",
      snapshot: chat(wakes()),
    },
    "b-failed-step-send": {
      note: "(b) A failed subagent step woke the agent: its line heads the turn, the thought and SendMessage sit under one closed Worked for, the reply and footer in sight.",
      snapshot: chat(wakes()),
    },
    "c-steer-thought": {
      note: "(c) A steer carried into its own turn, its thought, then a second steer: at rest every thought and call is under a closed Worked for. The loose thought in Leo's shot was that Worked for held open at the turn's end while he was scrolled up (App.tsx heldWorked).",
      snapshot: chat(steered()),
    },
    "d-bg-done-then-notice": {
      note: "(d) A background task's end whose turn is a thought, a send and a reply, then a turn an inbox notice started: both fold their work.",
      snapshot: chat(bgDone()),
    },
  },
});
