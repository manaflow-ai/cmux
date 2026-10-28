// l10n-allow-file: gallery fixtures (sample transcript timestamps), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, user } from "../../../gallery/fixtures/acpmux";

const reply = [
  "The first worker finished since about 04:50Z, and the follow-up landed at 04:38:12Z.",
  "The release event was 2026-10-24T05:21:28Z (local time is shown on hover), with the handoff at 05:22 UTC.",
  "Inline code stays literal: `05:23Z`. A fenced example stays literal too:",
  "```text\n2026-10-24T05:24:00Z\n```",
].join("\n\n");

export default agentPaneEntry({
  id: "agent-pane.time-hover",
  title: "Hoverable transcript times",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/Markdown.tsx", "agent-session/acpmux/conversation/timeHover.tsx"],
  variants: {
    transcript: {
      note: "Assistant Markdown timestamps become keyboard-focusable local-time tooltips; hover or focus the dotted-underlined times. The same state is readable in the gallery's light and dark themes.",
      snapshot: chat([user("Summarize the worker handoff and call out the exact times.", 4), assistant(reply, 2)]),
    },
  },
});
