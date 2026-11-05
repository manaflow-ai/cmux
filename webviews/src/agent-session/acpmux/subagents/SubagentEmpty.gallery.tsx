// l10n-allow-file: gallery fixture names and recorded messages, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS } from "./subagentFold";
import { childView } from "./subagentRows";

type Props = { state: string; populated?: boolean; parent?: string };
const at = Date.UTC(2026, 9, 29, 12);

export default componentEntry<Props>({
  id: "agent-pane.subagent-empty",
  title: "Empty agent conversation",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: ["agent-session/acpmux/subagents/subagentRows.ts#childView"],
  load: () =>
    import("../App").then(
      ({ VirtualTranscript }) =>
        function GallerySubagent(props: Props) {
          const group: AcpmuxRow = {
            id: "group",
            kind: SUBAGENTS,
            version: 1,
            at,
            subagents: [{ id: "reviewer", parent: null, name: "Reviewer", state: props.state, startedAt: at }],
          };
          const reply: AcpmuxRow = {
            id: "reply",
            kind: "assistant",
            version: 1,
            at: at + 1000,
            text: "The review is complete.",
          };
          const rows = childView(
            "reviewer",
            [group],
            props.populated ? { reviewer: [reply] } : {},
            new Set(),
            props.parent ?? "Release review",
          )!;
          return (
            <div className="acpmux-main" style={{ height: "100%", position: "relative" }}>
              <VirtualTranscript
                rows={rows}
                sessionId="gallery-child"
                expanded={new Set()}
                onToggleActivity={() => undefined}
              />
            </div>
          );
        },
    ),
  variants: {
    empty: {
      props: { state: "completed" },
      note: "A known child without recorded content keeps its parent breadcrumb and explains the empty transcript.",
    },
    running: {
      props: { state: "running" },
      note: "No child content has arrived. Missing rows are not a separate loading request.",
    },
    loaded: { props: { state: "completed", populated: true } },
    "long-parent": {
      props: { state: "completed", parent: "Release review for the very long project name with several components" },
    },
  },
});
