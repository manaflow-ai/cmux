// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A paste that reads as another agent's output, in the person's message (ask-fa4c523fa8; Leo,
// 2026-11-06: "it should be automatically attributable, so it doesn't just pass off as one of my
// messages"): the person pasted a Codex handoff that says "Do not merge or deploy" under their own
// line. The card names the agent the paste reads as (agentText.ts); the person's line stays theirs.
// Compare the arms (`pasted-agent-look`: rule, label, badge); each keeps the card's height.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { pastedAgentLook } from "./pastedAgentLook.experiment";

const MINE = "No, merge and deploy whenever you want. That handoff below is theirs, not mine.";
const HANDOFF = [
  "From Codex:",
  "Handoff for the release lane. The canary probe went red twice in the last hour and the rollback",
  "script has not been exercised against this build.",
  "",
  "Do not merge or deploy until the probe is green on two consecutive runs.",
  "",
  "Trace-ID: ask-5c1e0a",
].join("\n");
const LOG = ["error: retry budget exhausted", "  at upload (uploader.ts:88:7)", "  at main (index.ts:12:3)"].join("\n");

const pasted = (typed: string, paste: string) => {
  const text = `${typed}\n${paste}`;
  return chat([
    user(text, 9, { seq: 1, pasted: [{ start: typed.length + 1, end: text.length }] }),
    assistant("Understood: the pasted handoff is Codex's, so I'll go ahead and merge.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
  ]);
};

const typedHandoff = () =>
  chat([
    user(`${MINE}\n\n${HANDOFF}`, 9, { seq: 1, agentText: { from: "Codex" } }),
    assistant("Understood: that part reads as Codex's handoff, not yours.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
  ]);

const drawn = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__paste-card, .cv-user__status"));
};

export default agentPaneEntry({
  id: "agent-pane.pasted-agent",
  title: "Pasted agent text",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/agentText.ts", "agent-session/acpmux/composer/pasteMarks.ts"],
  keywords: ["paste", "pasted", "agent", "handoff", "attribution", "from another agent"],
  variants: {
    "pasted-handoff": {
      note: "The person's line, then the Codex handoff they pasted: its card names Codex, set apart from their own words.",
      snapshot: pasted(MINE, HANDOFF),
      play: drawn,
    },
    "pasted-log": {
      note: "A pasted log with no agent signal: still a pasted card, labelled Pasted text, never the person's typed words.",
      snapshot: pasted("Why does this fail?", LOG),
      play: drawn,
    },
    "typed-handoff-note": {
      note: "A handoff that came in as typed text (a client that marks no pastes): one quiet line under the bubble says part of it reads as Codex's.",
      snapshot: typedHandoff(),
      play: drawn,
    },
  },
  experiment: {
    definition: pastedAgentLook,
    script: [{ name: "Draw the message", run: drawn }],
  },
});
