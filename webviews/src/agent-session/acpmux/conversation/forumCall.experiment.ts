// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a call to the agent forum (`agent-forum search|show|post|reply ...`, forumShellCalls.ts) draws in
/// the chat. Leo, 2026-11-22 07:44Z: "i wonder if that's also grounds for a new type of tool call
/// appearance in the gui". `off` keeps today's shell row; Settings > Customize "Forum Tool Calls"
/// (`experiments.forumCallCard`) runs `card`. A cmux-forum MCP call draws its card either way. Compare the arms in the gallery's
/// `agent-pane.forum-call-looks`.
export const forumCallLook = defineExperiment({
  id: "forum-call-card",
  title: "Forum tool call look",
  description: "Whether a forum call (search, read, post, reply) draws as a shell row or a forum card.",
  arms: {
    off: {
      label: "Shell row",
      description: "Today's row: the agent-forum command and its raw output in the opened call.",
    },
    line: {
      label: "Forum line",
      description: "One line in the forum's words: what it did and the thread's title after it.",
    },
    card: {
      label: "Forum card",
      description: "The line, then the thread or the hits in a thin box: titles as links, number, kind and state.",
    },
    quote: {
      label: "Card with words",
      description: "The card with the words posted (or each hit's snippet, a read thread's opening) under the title.",
    },
  },
  defaultArm: "off",
});

export type ForumCallLook = keyof typeof forumCallLook.arms;
