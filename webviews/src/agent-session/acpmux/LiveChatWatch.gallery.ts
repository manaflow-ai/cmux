// l10n-allow-file: gallery fixtures (sample transcript and commands), not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, noChat, user } from "../../gallery/fixtures/acpmux";

const choice = { canFork: true, command: "claude --resume 3f2b9c1e-6d4a-4f7e-9b2a-8c1d5e0f7a64" };
const transcript = [
  user("Why does the build cache miss on CI?", 12),
  assistant(
    "The cache key hashes the whole lockfile, and CI rewrites it on install. Keying on the resolved versions keeps hits across those rewrites.",
    11,
  ),
];

/// Opening a Claude Code chat a terminal still runs (`claude --resume`): acpmux refuses to resume
/// it in a second place (`adopt.live`). "there's frequently nothing wrong with showing the same
/// session but in two different places" (Leo, 2026-10-29).
export default agentPaneEntry({
  id: "agent-pane.live-chat-watch",
  title: "Chat another app runs",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/direct.ts#AcpmuxDirectClient"],
  variants: {
    "choice-alone": {
      note: "Before, and still for a chat that cannot be watched: the choice over an empty pane",
      snapshot: noChat([], { liveChat: choice }),
    },
    "view-only": {
      note: "Now: the chat View Only, following the terminal, asking nothing until the person replies or takes over",
      snapshot: chat(transcript, {
        summary: { ...chat(transcript).summary!, watching: "claude" },
      }),
    },
    "take-over-refused": {
      note: "A reply or Take Over that acpmux refuses as live: Fork It and Open Anyway over the watched chat",
      snapshot: chat(transcript, {
        summary: { ...chat(transcript).summary!, watching: "claude" },
        liveTakeOver: choice,
      }),
    },
  },
});
