// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// A coordinator's tagged ask in the whole agent pane (turns.ts NEXT_STEP, NextStepCard.tsx): the
// turn's answer ends on `[outward] ...?` with its answers listed, so the transcript draws the card
// under the prose; once the person answers, the card folds to the question and the answer, and an
// ordinary closing question draws no card.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const ASK =
  "The lane wasn't foregrounded by acpmux or cmux NEXT. It ran about 40 slow Bash calls in the foreground itself, and they stalled the turn. Separately, the activity-row timer bug went to the timer helper.\n\n[outward] Add a hook that pushes known-slow commands to the background?\n- Yes, add the hook\n- Not now\n- Fix CI first";

const turn = (answer: string, reply?: string) =>
  chat([
    user("Why did the lane stall?", 6),
    activity(
      [
        tool("Read lane log", "read", "completed"),
        tool("acpmux ls --status running", "execute", "completed", {
          command: "acpmux ls --status running",
          output: "ultras running 41m\n",
          exitCode: 0,
        }),
      ],
      5,
    ),
    assistant(answer, 4),
    summary(4, { status: "completed", durationMs: 52_000, toolCount: 2 }),
    ...(reply ? [user(reply, 2)] : []),
  ]);

export default agentPaneEntry({
  id: "agent-pane.next-step-in-pane",
  title: "Tagged ask in the transcript",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/NextStepCard.tsx#NextStepCard"],
  variants: {
    waiting: {
      note: "The turn ends on a tagged ask: the card under the prose, three answers, ⌘↩ on the first.",
      snapshot: turn(ASK),
    },
    answered: {
      note: "The person clicked Not now: the card folds to the question and the answer.",
      snapshot: turn(ASK, "Not now"),
    },
    "ordinary-question": {
      note: "An untagged closing question: no card, the prose as it was.",
      snapshot: turn("All 14 tests pass. Should I open a PR for this?"),
    },
  },
});
