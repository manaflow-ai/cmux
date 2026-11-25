// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A message the person sends while a reply streams never cuts the reply (Leo, 2026-11-05, on a reply
// split mid-sentence at "Its owner, `", its Copy/Speak row and a gap under the first half and the
// rest below: "If your text is streaming, I shouldn't be able to interrupt it or, like, break it in
// between."). The reducer keeps the reply's row open for its own text when a steer, a prompt or a
// notice lands (direct.ts `holdAssistantSegment`); test/transcript-stream-not-cut.test.ts.
//
// Where the person's message sits while the reply goes on:
// - `split`: before, what Leo saw.
// - `below-reply`: shipped. The reply streams on whole above, with no action row until it ends; the
//   steer's bubble waits under it, then the answer starts below the bubble. It keeps the transcript
//   in the order things happened, and mid-turn-messages.md's waiting bubble (clock, Send now, X).
// - `held-in-composer`: the message waits as a composer queue row until the reply ends. Rejected: a
//   steer is accepted at once and must show in the transcript as sent (mid-turn-messages.md), and
//   a queue row reads as "not sent" (Leo, on the paused queue the same day: "don't show these kinds
//   of things").
// - `after-turn`: the bubble moves under the turn's end. Rejected: the agent reads a steer at its
//   next step, so its answer would draw above the message it answers.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const ASK = "Where do G2 and item A stand?";
const HEAD = "- **G2 exists only on studio-mac**, not on GitHub, and nothing has pushed it. Its owner, `";
const TAIL =
  "build-box/prebuilt-ci` in `ci-apply-to-prebuilt`, ran it before.\n- **Item A** (`build-box/quit-no-alert`) is in review.";
const STEER = "skip G2, just tell me about item A";

const opened = [
  user("Check the fleet's open items", 30, { seq: 1 }),
  assistant("All three lanes reported; nothing needs you.", 29),
  summary(29, { status: "completed" }),
  user(ASK, 2, { seq: 4 }),
  activity([tool("Read the lanes' reports", "read", "completed")], 1.8),
];

const split = chat(
  [...opened, assistant(HEAD, 1.5), user(STEER, 1.2, { steer: "waiting" }), assistant(TAIL, 1.1, { streaming: true })],
  { title: "Fleet items", isWorking: true },
);

const belowReply = chat(
  [...opened, assistant(`${HEAD}${TAIL}`, 1.5, { streaming: true }), user(STEER, 1.2, { steer: "waiting" })],
  { title: "Fleet items", isWorking: true },
);

const heldInComposer = chat([...opened, assistant(`${HEAD}${TAIL}`, 1.5, { streaming: true })], {
  title: "Fleet items",
  isWorking: true,
  queue: [{ id: "steer-1", prompt: STEER }],
});

const answered = [
  ...opened,
  assistant(`${HEAD}${TAIL}`, 1.5),
  user(STEER, 1.2, { steer: "landed" }),
  assistant("Item A is in review at its exact head; it lands once the review passes.", 0.5),
];

const afterTurn = chat(
  [
    ...opened,
    assistant(`${HEAD}${TAIL}`, 1.5),
    assistant("Item A is in review at its exact head; it lands once the review passes.", 0.5),
    summary(0.4, { status: "completed" }),
    user(STEER, 1.2),
  ],
  { title: "Fleet items" },
);

export default agentPaneEntry({
  id: "agent-pane.streaming-reply-whole",
  title: "A streaming reply stays whole when a message lands",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/turns.ts"],
  variants: {
    split: {
      note: "Before: the steer's record ended the reply mid-sentence; its action row, the bubble and the rest of the sentence below.",
      snapshot: split,
    },
    "below-reply": {
      note: "Shipped: the reply streams on whole, no action row until it ends; the waiting steer sits under it.",
      snapshot: belowReply,
    },
    "below-reply-answered": {
      note: "Shipped, after the agent's next step: the reply above the read steer, the answer below it.",
      snapshot: chat(answered, { title: "Fleet items", isWorking: true }),
    },
    "held-in-composer": {
      note: "Rejected: the message waits in the composer queue until the reply ends, reading as not sent.",
      snapshot: heldInComposer,
    },
    "after-turn": {
      note: "Rejected: the bubble under the turn's end puts the answer above the message it answers.",
      snapshot: afterTurn,
    },
  },
});
