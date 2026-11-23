// l10n-allow-file: gallery-only sample chats, not shipped UI.
// The chat header's rolling summary (ChatSummaryLine.tsx): where the chat stands and its next
// action, muted beside the chat's name, from acpmux's `rollingSummary` after each turn a person
// started.
import { componentEntry } from "../../../gallery/format";
import { ChatSummaryLine, type ChatSummary } from "./ChatSummaryLine";
import { ThreadTitle } from "./ThreadTitle";

type Props = { title: string; summary: ChatSummary | null; chat?: string };

function SummaryHeaderGallery({ title, summary, chat }: Props) {
  return (
    <div className="acpmux-shell">
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">
          <span className="acpmux-header-status-content">
            <ThreadTitle title={title} onRename={() => undefined} />
            <ChatSummaryLine summary={summary} chat={chat} />
          </span>
        </div>
      </header>
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.chat-summary",
  title: "Chat summary and next action",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 720, wide: 960 },
  anchors: [{ selector: ".acpmux-header" }],
  covers: ["agent-session/acpmux/header/ChatSummaryLine.tsx#ChatSummaryLine"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => SummaryHeaderGallery,
  variants: {
    "with-next": {
      props: {
        title: "Parser fix",
        chat: "gallery-chat-summary-with-next",
        summary: {
          text: "Fixed the parser and pushed it. CI is still running.",
          next: "Merge the PR once CI is green",
        },
      },
      note: "The summary, an arrow, then the next action a step brighter; the whole text is the tooltip. Its × hides the line for that chat on this device (https://github.com/manaflow-ai/cmux/issues/51749).",
    },
    "no-next": {
      props: {
        title: "Picnic menu",
        chat: "gallery-chat-summary-no-next",
        summary: { text: "The vegetarian picnic menu is final." },
      },
      note: "Nothing left to do: no arrow.",
    },
    long: {
      props: {
        title: "Investigate the flaky reconnect path",
        chat: "gallery-chat-summary-long",
        summary: {
          text: "Found the reconnect race in the link controller: a retry starts before the old socket closes, so two sessions fight.",
          next: "Review the fix and run the fleet reconnect suite",
        },
      },
      note: "A long summary ellipsizes before the next action does; the name keeps its room.",
    },
  },
});
