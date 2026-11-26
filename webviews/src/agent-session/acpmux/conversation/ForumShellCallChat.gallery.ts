// l10n-allow-file: gallery fixtures (sample prompts, thread titles and CLI output), not shipped UI.
// An agent's `agent-forum` calls in a chat: today's shell rows (the default) beside the forum rows the
// Settings > Customize "Forum Tool Calls" switch draws (experiment forum-call-card). Leo, 2026-11-22
// 07:44Z: "you guys are also using the forum? or not as much? i wonder if that's also grounds for a
// new type of tool call appearance in the gui". The same card a cmux-forum MCP call draws
// (agent-pane.forum-call).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, user } from "../../../gallery/fixtures/acpmux";
import { forumCallLook } from "./forumCall.experiment";
import { chainedCall, postCall, searchCall, showCall } from "./forumShellCalls.fixtures";

const snapshot = () =>
  chat(
    [
      user("The compile pool stalls when I push twice. Has anyone seen this?", 4),
      activity([searchCall(), showCall()], 3.6),
      assistant("Thread #24871 describes it; I'll add what I saw.", 3.2),
      activity([postCall(), chainedCall()], 3),
      assistant("Posted my repro as a finding.", 2.8),
    ],
    { title: "Compile pool stall", branch: "lane/compile-pool" },
  );

export default agentPaneEntry({
  id: "agent-pane.forum-shell-call",
  title: "Forum commands (agent-forum) in a chat",
  area: "Agent pane",
  experimental: true,
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/ForumCallCard.tsx",
    "agent-session/acpmux/conversation/forumShellCalls.ts",
    "agent-session/acpmux/conversation/toolGroups.ts",
  ],
  variants: {
    off: {
      note: "Default (switch off): each agent-forum call is a shell row, as today.",
      snapshot: snapshot(),
      experiments: { [forumCallLook.id]: "off" },
    },
    card: {
      note: "Forum Tool Calls on: a search, a read and a post draw as forum rows with thread links; the call chained with git log keeps its shell row.",
      snapshot: snapshot(),
      experiments: { [forumCallLook.id]: "card" },
    },
    quote: {
      note: "The quote arm: the same rows with the snippet, opening lines or words posted under each title.",
      snapshot: snapshot(),
      experiments: { [forumCallLook.id]: "quote" },
    },
  },
});
