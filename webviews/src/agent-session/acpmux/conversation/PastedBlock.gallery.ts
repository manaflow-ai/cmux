// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A paste in the person's message (ask-42dfdea96c, ask-48544d7525; Leo, 2026-11-07: "it says pasted
// text, but this is just the normal text that I had" ... "this is not that long to, like,
// necessitate the sort of folding"): one of ordinary size reads as the message's own text, with no
// label and no card; only one too long to read in place folds, as one quiet region of the bubble
// that opens in place. Compare the arms (`pasted-block-look`: quiet, rule, divider).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { pastedBlockLook } from "./pastedBlockLook.experiment";

/// Leo's own message from the report, 515 characters: a paste of it reads as plain text.
const ORDINARY =
  "I also think there's, like, a fundamental fix we can have for some of these things where it's, like, okay, if a user recently—I mean, this might be a bit too cute, but it's, like, okay, you know how the transcript, the agent chat, like it jumps down every now and then, right? Let's have it so that, like, when a user recently scrolled up, potentially don't try to, like, hijack that. But I don't know. This is maybe a bit too cute. Like, you can think of, like, the scenarios that we would want or not want things.";
const LOG = Array.from(
  { length: 140 },
  (_, index) => `[12:0${index % 10}] worker ${index}: retry budget at ${index}%`,
).join("\n");

const message = (typed: string, paste: string) => {
  const text = typed ? `${typed}\n${paste}` : paste;
  const start = typed ? typed.length + 1 : 0;
  return chat([
    user(text, 9, { seq: 1, pasted: [{ start, end: text.length }] }),
    assistant("Got it.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
  ]);
};

const drawn = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user"));
};

export default agentPaneEntry({
  id: "agent-pane.pasted-block",
  title: "Pasted text in a message",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/conversation/PromptText.tsx", "agent-session/acpmux/pastedText.ts"],
  keywords: ["paste", "pasted", "fold", "pasted text", "dictation"],
  variants: {
    "ordinary-paste": {
      note: "A 515-character paste (Leo's own words from the report): plain text in the bubble, no label, no fold, no card.",
      snapshot: message("", ORDINARY),
      play: drawn,
    },
    "oversized-paste": {
      note: "A 140-line log under the person's question: one quiet region that opens in place to the raw text.",
      snapshot: message("Why does the worker run out of retries?", LOG),
      play: drawn,
    },
  },
  experiment: {
    definition: pastedBlockLook,
    script: [{ name: "Draw the message", run: drawn }],
  },
});
