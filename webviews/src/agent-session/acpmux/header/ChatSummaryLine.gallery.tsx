// l10n-allow-file: gallery-only sample chats, not shipped UI.
// The chat header's rolling summary (ChatSummaryLine.tsx): where the chat stands and its next
// action, muted beside the chat's name, from acpmux's `rollingSummary` after each turn a person
// started.
import { componentEntry } from "../../../gallery/format";
import { ChatSummaryLine, type ChatSummary } from "./ChatSummaryLine";
import { ThreadTitle } from "./ThreadTitle";

function SummaryHeaderGallery({
  title,
  summary,
  width,
}: {
  title: string;
  summary: ChatSummary | null;
  width?: number;
}) {
  return (
    <div className="acpmux-shell" style={width ? { width, maxWidth: "100%" } : undefined}>
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">
          <span className="acpmux-header-status-content">
            <ThreadTitle title={title} onRename={() => undefined} />
            <ChatSummaryLine summary={summary} />
          </span>
        </div>
      </header>
    </div>
  );
}

export default componentEntry<{ title: string; summary: ChatSummary | null; width?: number }>({
  id: "agent-pane.chat-summary",
  title: "Chat summary and next action",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 300, normal: 600, wide: 1100 },
  anchors: [{ selector: ".acpmux-header" }],
  covers: ["agent-session/acpmux/header/ChatSummaryLine.tsx#ChatSummaryLine"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => SummaryHeaderGallery,
  variants: {
    "with-next": {
      props: {
        title: "Parser fix",
        summary: {
          text: "Fixed the parser and pushed it. CI is still running.",
          next: "Merge the PR once CI is green",
        },
      },
      note: "One phrase (summary, arrow, next action) with one ellipsis; below ~12 characters of room it is dropped whole. The full text is the tooltip.",
    },
    "no-next": {
      props: { title: "Picnic menu", summary: { text: "The vegetarian picnic menu is final." } },
      note: "Nothing left to do: no arrow.",
    },
    "at-420": {
      props: {
        title: "Investigate the flaky reconnect path",
        width: 420,
        summary: { text: "Found the reconnect race in the link controller.", next: "Review the fix" },
      },
      note: "420px: the title keeps its room; the phrase shows 12+ characters with one ellipsis or is dropped.",
    },
    long: {
      props: {
        title: "Investigate the flaky reconnect path",
        summary: {
          text: "Found the reconnect race in the link controller: a retry starts before the old socket closes, so two sessions fight.",
          next: "Review the fix and run the fleet reconnect suite",
        },
      },
      note: "The phrase is cut once at the end; the name keeps its room and nothing shows two ellipses.",
    },
  },
});
