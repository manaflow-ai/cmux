// l10n-allow-file: gallery goal fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { NoticeRow } from "./NoticeRow";

export default componentEntry<{ goal: string }>({
  id: "agent-pane.shadow-review",
  title: "Stalled goal review",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 320, normal: 640, wide: 820 },
  covers: ["agent-session/acpmux/rows/NoticeRow.tsx"],
  styles: () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]),
  load:
    async () =>
    ({ goal }) => (
      <div className="acpmux-shell">
        <NoticeRow
          row={{ id: "review", version: 1, at: 1, kind: "shadowReview", text: goal }}
          expanded={false}
          onToggleActivity={() => {}}
        />
      </div>
    ),
  variants: {
    short: { note: "A quiet notice using the existing transcript style.", props: { goal: "Repair the parser" } },
    long: {
      note: "A long goal wraps at narrow chat widths.",
      props: {
        goal: "Resolve the blocked release check, verify the affected command, and record the exact result with the remaining dependency.",
      },
    },
    unicode: { note: "The recorded goal keeps its original language.", props: { goal: "修復解析器並驗證結果" } },
  },
});
