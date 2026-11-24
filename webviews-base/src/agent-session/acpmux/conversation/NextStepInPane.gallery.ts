// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// A coordinator's tagged ask in the whole agent pane (turns.ts NEXT_STEP, NextStepCard.tsx): the
// turn's answer ends on `[outward] ...?` with its answers listed, so the transcript draws the card
// under the prose; once the person answers, the card folds to the question and the answer, and an
// ordinary closing question draws no card. `wrap-up-code-mode` is a real chat's turn: the agent
// called `cmux.acpmux_wrap_up` from a `cmux_exec` script, and the call_log below is what that DEV
// chat recorded (code_mode.rs keeps the shown box as `shown`).
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

// The call_log a real SR2 Claude chat recorded on a DEV build (2026-11-03).
const SHOWN = {
  recap: "Checked the folder: it is empty.",
  ask: "Should I add a README here?",
  actions: ["Yes, add README", "No thanks"],
};
const codeModeTurn = chat([
  user("What's in this folder?", 6),
  activity(
    [
      tool("mcp__cmux__cmux_exec", "other", "completed", {
        inputSummary: JSON.stringify({ script: `await cmux.acpmux_wrap_up(${JSON.stringify(SHOWN)})` }),
        output: JSON.stringify({ calls: 1, call_log: [{ name: "acpmux_wrap_up", ok: true, shown: SHOWN }] }),
      }),
    ],
    5,
  ),
  assistant("The folder is empty. I asked in the wrap-up box whether to add a README.", 4),
  summary(4, { status: "completed", durationMs: 9_000, toolCount: 1 }),
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
    "wrap-up-code-mode": {
      note: "A real chat's wrap-up from a cmux_exec script: the recap, the question and its two answers.",
      snapshot: codeModeTurn,
    },
    "wrap-up-click": {
      note: "The same turn on the in-page mock acpmux, so a click on an answer sends it as the next prompt.",
      ready: { transport: "mock", sessionId: "mock-wrap-up-code-mode" },
      // The mock's session of the same turn, so the box's answer reaches its chat.
      snapshot: { ...codeModeTurn, sessionId: "mock-wrap-up-code-mode" },
    },
  },
});
