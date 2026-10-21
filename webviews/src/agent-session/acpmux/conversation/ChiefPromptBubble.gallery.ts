// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt the Chief sent a subagent (ChiefPromptBubble.tsx): "From the Chief" above it, and a long
// task on its first lines with Show all (Lawrence 2026-10-19).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const longTask = [
  "ACP missing user prompt",
  "",
  "When an agent starts through acpmux, its chat shows the replies but not the first prompt.",
  "1. Find why: the open page, the replay, or the composer.",
  "2. Fix it so every prompt shows as a bubble, live and after reload.",
  "3. Mark prompts the Chief sent, and keep long ones collapsed with a way to open them.",
  "4. Failing tests first, then the fix.",
  "5. Push to the feature branch, no pull request.",
  "Short report: cause, fix, commits, tests.",
].join("\n");

/** A Chief subagent's first message (chiefEnvelope.ts): the Chief's view in `<chat>`, then the task. */
const envelope = [
  "<chat>",
  ...Array.from({ length: 89 }, (_, index) => `chief: step ${index + 1} of the plan, as the Chief saw it`),
  "</chat>",
  "",
  "Your task:",
  "",
  "Fix the Home header fade so the transcript under it stays legible.",
].join("\n");

export default agentPaneEntry({
  id: "agent-pane.chief-prompt",
  title: "Prompt from the Chief",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/ChiefPromptBubble.tsx"],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    long: {
      note: "A subagent's long task opens on its first lines; Show all opens the rest.",
      snapshot: chat([
        user(longTask, 9, { seq: 1, from: "chief" }),
        assistant("Found it: the open page starts mid-turn, so the prompt never drew.", 8),
        summary(8, { seq: 3, status: "completed" }),
      ]),
    },
    context: {
      note: "The Chief's view as one collapsed line with its Copy at the trailing end; a narrow pane truncates the label, never covers it.",
      snapshot: chat([
        user(envelope, 9, { seq: 1 }),
        assistant("On it.", 8),
        summary(8, { seq: 3, status: "completed" }),
      ]),
    },
    "follow-up": {
      note: "A short follow-up the Chief told it, under a prompt typed in the pane.",
      snapshot: chat([
        user("Check the reload case too", 9, { seq: 1 }),
        assistant("Reload shows it as well.", 8.5),
        summary(8.5, { seq: 3, status: "completed" }),
        user("Rebase and push when the tests pass.", 6, { seq: 4, from: "chief" }),
      ]),
    },
  },
});
