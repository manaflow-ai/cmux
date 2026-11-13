// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A prompt the Chief sent a subagent (ChiefPromptBubble.tsx): the Chief's avatar and "Sent from <Chief>" above it, and a long
// task on its first lines with Show more (Lawrence 2026-10-19).
import { agentPaneEntry } from "../../../gallery/format";
import { UPLOADED_AVATAR } from "../../../gallery/fixtures/agentAvatar";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

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

/** A turn still running under its prompt: "Working for" over its work, a command in flight. */
const running = (from?: "chief") =>
  chat(
    [
      user("Rebase and push when the tests pass.", 3, { seq: 1, ...(from && { from }) }),
      activity(
        [
          tool("git fetch origin", "execute", "completed", { command: "git fetch origin", exitCode: 0 }),
          tool("bun test", "execute", "in_progress", { command: "bun test" }),
        ],
        1,
      ),
    ] as AcpmuxRow[],
    { isWorking: true, turnStartedAtMs: GALLERY_NOW - 164_000 },
  );

export default agentPaneEntry({
  id: "agent-pane.chief-prompt",
  title: "Prompt from the Chief",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/ChiefPromptBubble.tsx"],
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    long: {
      note: "A subagent's long task opens on its first lines; Show more opens the rest.",
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
    "sent-from": {
      note: 'Leo 2026-11-02, beside ChatGPT\'s "Sent from dot": a prompt the Chief sent on the person\'s behalf draws the Chief\'s existing avatar and a muted "Sent from <Chief>" line right-aligned above its bubble.',
      snapshot: chat([
        user("Rebase and push when the tests pass.", 6, { seq: 1, from: "chief" }),
        assistant("Rebased; pushing once the tests finish.", 5.5),
        summary(5.5, { seq: 3, status: "completed" }),
      ]),
      native: { "chief.face": { name: "Scout", src: UPLOADED_AVATAR } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-user__from img.cv-agent-avatar"));
      },
    },
    running: {
      note: 'A Chief prompt over a running turn: "Working for" stands the turn gap under the bubble, as under a typed prompt (https://github.com/manaflow-ai/cmux/issues/42444).',
      snapshot: running("chief"),
    },
    "running-typed": {
      note: "The same running turn under a prompt typed in the pane, for comparison.",
      snapshot: running(),
    },
    waiting: {
      note: "A Chief prompt just sent, its live line under it: the block gap, its action row centred in that.",
      snapshot: chat([user("Rebase and push when the tests pass.", 0, { seq: 1, from: "chief" })] as AcpmuxRow[], {
        isWorking: true,
        turnStartedAtMs: GALLERY_NOW,
      }),
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
