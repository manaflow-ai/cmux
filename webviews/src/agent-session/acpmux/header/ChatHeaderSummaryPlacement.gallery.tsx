// l10n-allow-file: gallery-only sample chats and summaries, not shipped UI.
// Where a chat's rolling summary goes, if anywhere, in the chat header. Leo, 2026-11-22, on the line beside the
// chat's name: "why do we have this subheading here? im not sure if this is useful. well, at least for 1, it's
// overlapping. it's not good. idk why this was put in." The shipped header is `name-only`: the summary stays in the
// sidebar's hover card, Expanded rows and the iPhone's Chats list, where scanning many chats is the point. The other
// two are the ones weighed against it, drawn with the same chat so they can be compared side by side.
import { componentEntry } from "../../../gallery/format";
import { ThreadTitle } from "./ThreadTitle";

type Placement = "name-only" | "name-tooltip" | "beside-name";
type Props = { placement: Placement; title: string; summary: string; next: string };

const muted = { color: "var(--agent-muted)", fontSize: "var(--text-detail)" } as const;

function SummaryPlacementGallery({ placement, title, summary, next }: Props) {
  const full = `${summary}\nNext: ${next}`;
  return (
    <div className="acpmux-shell">
      <header className="acpmux-header">
        <div className="acpmux-header-status-slot">
          <span
            className="acpmux-header-status-content"
            /* tooltip-allow: gallery-only comparison of a tooltip placement */
            title={placement === "name-tooltip" ? full : undefined}
          >
            <ThreadTitle title={title} onRename={() => undefined} />
            {placement === "beside-name" && (
              <span
                style={{
                  ...muted,
                  minWidth: 0,
                  padding: "0 var(--ds-space-1)",
                  whiteSpace: "nowrap",
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  lineHeight: "var(--acpmux-header-control-height, 26px)",
                }}
              >
                {summary} → <span style={{ color: "var(--agent-text)" }}>{next}</span>
              </span>
            )}
          </span>
        </div>
      </header>
      <main style={{ padding: "var(--ds-space-2) var(--ds-space-3)", ...muted }}>
        {placement === "name-only" && "Shipped: the name alone; the summary is in the sidebar's hover card."}
        {placement === "name-tooltip" && "Weighed: the summary only as the name's tooltip. Hidden until hovered."}
        {placement === "beside-name" && "Before (removed): the summary beside the name, competing with it for room."}
      </main>
    </div>
  );
}

const CHAT = {
  title: "release-coordinator",
  summary: "I posted build-box's 14-day permission-stall history on the tracking issue",
  next: "Wait for the owner's read",
};

export default componentEntry<Props>({
  id: "agent-pane.chat-header-summary-placement",
  title: "Chat header: where the rolling summary goes",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 720, wide: 960 },
  anchors: [{ selector: ".acpmux-header" }],
  covers: ["agent-session/acpmux/header/ThreadTitle.tsx#ThreadTitle"],
  styles: () => Promise.all([import("../styles.css"), import("./header.css")]),
  load: async () => SummaryPlacementGallery,
  variants: {
    "name-only": {
      props: { placement: "name-only", ...CHAT },
      note: "Shipped. The header names the chat and nothing else; nothing can overlap the name or move the tools.",
    },
    "name-tooltip": {
      props: { placement: "name-tooltip", ...CHAT },
      note: "Not taken: a tooltip nobody hovers on purpose, and it repeats the sidebar's hover card.",
    },
    "beside-name": {
      props: { placement: "beside-name", ...CHAT },
      note: "The line that was removed, for comparison: at narrow widths it squeezes the name and reads as a second title.",
    },
  },
});
