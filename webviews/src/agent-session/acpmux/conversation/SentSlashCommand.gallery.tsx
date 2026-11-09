// l10n-allow-file: gallery fixtures (sample prompts and command descriptions), not shipped UI.
// A slash command sent as the prompt's first word keeps the composer's command rendering in the
// transcript (Leo 2026-11-09: "these commands after i send them off should preserve their special
// rendering"): the composer lights a `/name` that names any command at the prompt's start
// (composer/slashTokens.ts), and the sent row lights the same word with SkillWord's blue
// (skillWords.ts leadCommand). Mid-prompt, a built-in stays plain, as in the composer.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const commands = [
  { name: "compact", description: "Clear the history but keep a summary", source: "agent" as const },
  { name: "goal", description: "Set a goal for the chat", source: "agent" as const },
  { name: "loop", description: "Run a prompt on an interval", source: "agent" as const },
  { name: "review-pr", description: "Review a pull request", source: "skill" as const },
];

const sending = (id: string) => ({ state: "sending" as const, promptId: id, sessionId: "gallery", sentAt: 0 });

export default agentPaneEntry({
  id: "agent-pane.sent-slash-command",
  title: "Sent prompts: slash commands",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/SkillWord.tsx#SkillWord",
    "agent-session/acpmux/conversation/PromptText.tsx#PromptTyped",
    "agent-session/acpmux/conversation/PromptText.tsx#PromptText",
    "agent-session/acpmux/conversation/InlinePromptContent.tsx#InlinePromptContent",
    "agent-session/acpmux/conversation/SentUIPick.tsx#SentUIPicks",
    "agent-session/acpmux/ComposerQueue.tsx#ComposerQueue",
  ],
  variants: {
    "compact-sent": {
      note: "/compact sent on its own: the bubble draws it in the composer's command blue, not plain text.",
      snapshot: chat([user("Fix the flaky retry test", 9), assistant("Fixed and pushed.", 8), user("/compact", 1)], {
        harness: "claude",
        commands,
      }),
    },
    "goal-with-args": {
      note: "/goal with arguments: only /goal is blue; the words after it stay text. /review-pr later is a skill, so it lights too.",
      snapshot: chat(
        [user("/goal ship the nightly with the retry fix, then /review-pr", 3), assistant("Goal set.", 2)],
        { harness: "claude", commands },
      ),
    },
    "loop-pending": {
      note: "/loop still sending (the optimistic row) and /loop waiting in the queue: both draw the command as the sent row will.",
      snapshot: chat(
        [
          user("Check the deploy", 6),
          assistant("Deploy is green.", 5),
          user("/loop 5m check the deploy", 0, { delivery: sending("loop-1") }),
        ],
        { harness: "claude", commands, queue: [{ id: "q-1", prompt: "/loop 10m check the logs" }] },
      ),
    },
    "markdown-led": {
      note: "A prompt written in Markdown that starts with /goal: /goal lights, the code span stays code.",
      snapshot: chat([user("/goal make `fetchWithRetry` pass on **every** run", 2), assistant("On it.", 1)], {
        harness: "claude",
        commands,
      }),
    },
    "not-first-word": {
      note: "A command that is not the first word stays plain, as in the composer (please /compact now, /nope).",
      snapshot: chat([user("please /compact now", 4), assistant("Compacting.", 3), user("/nope is no command", 1)], {
        harness: "claude",
        commands,
      }),
    },
  },
});
