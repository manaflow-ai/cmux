// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The reply the agent writes after it read a steer draws below the steer (Leo, 2026-11-17: "and the
// message you sent after my steer... shot up. instead of landing after my steer prompt"). The reply
// that was streaming when the steer went keeps its words above it; once acpmux says the agent read
// the steer (`steer_read`), the text after it starts a row of its own below the steer, even when the
// agent's chunks carry no message id to say a new message began (direct.ts, the `steer_read`
// handler); carriedSteerOrder.test.ts.
//
// - `before`: what Leo saw. The answer ran on in the row above the steer, which still said Send now.
// - `below-steer`: shipped, live. The steer is read; its answer streams below it.
// - `below-steer-ended`: shipped, once the turn ends: the same order, the steer landed.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const PRE = "Looking at the list now.";
const STEER = "and the flicker when it reloads?";
const ANSWER = "On the flicker: the list remounts on every reload. Keeping its key stable stops it.";

const opened = [
  user("Fix the session list ordering", 3, { seq: 1 }),
  activity([tool("Read SessionList.tsx", "read", "completed")], 2.8),
];

const before = chat(
  [...opened, assistant(`${PRE}${ANSWER}`, 2.5, { streaming: true }), user(STEER, 2, { steer: "waiting" })],
  { title: "Session list", isWorking: true },
);

const belowSteer = chat(
  [...opened, assistant(PRE, 2.5), user(STEER, 2, { steer: "landed" }), assistant(ANSWER, 1.5, { streaming: true })],
  { title: "Session list", isWorking: true },
);

const belowSteerEnded = chat(
  [
    ...opened,
    assistant(PRE, 2.5),
    user(STEER, 2, { steer: "landed" }),
    assistant(ANSWER, 1.5),
    summary(1.4, { status: "completed" }),
  ],
  { title: "Session list" },
);

export default agentPaneEntry({
  id: "agent-pane.steer-reply-below",
  title: "A reply after a read steer draws below the steer",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/direct.ts", "agent-session/acpmux/conversation/turns.ts"],
  variants: {
    before: {
      note: "Before: the answer ran on in the reply's row above the steer, which still offered Send now.",
      snapshot: before,
    },
    "below-steer": {
      note: "Shipped, live: the words before the read stay above; the answer streams below the read steer.",
      snapshot: belowSteer,
    },
    "below-steer-ended": {
      note: "Shipped, the turn ended: the same order, the steer landed.",
      snapshot: belowSteerEnded,
    },
  },
});
