// l10n-allow-file: gallery fixture names and recorded messages, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS } from "./subagentFold";
import { foldOwnLog, subagentPaneView } from "./subagentOwnLog";
import { childView } from "./subagentRows";

/// `pending`: a pane opened on a subagent the chat's rows no longer hold, while its own records are
/// read (`loading`) or after they came back empty (`missing`), drawn by `subagentPaneView`.
/// `look`: the loading designs weighed for it (ask-d066640281); `words` ships.
type Props = {
  state: string;
  populated?: boolean;
  parent?: string;
  pending?: "loading" | "missing";
  look?: "words" | "skeleton" | "spinner";
};

/// The loading designs not picked, drawn here only to compare: three bars of the reply's width, and
/// a small spinner beside the words. Both change the row's shape when the rows come.
function RejectedLoading({ look }: { look: "skeleton" | "spinner" }) {
  if (look === "skeleton")
    return (
      <div aria-hidden="true" style={{ display: "grid", gap: 8, padding: "12px 16px" }}>
        {[92, 78, 54].map((width) => (
          <div
            key={width}
            style={{
              height: 10,
              width: `${width}%`,
              borderRadius: "var(--ds-radius-sm)",
              background: "var(--cv-surface-raised, #8883)",
            }}
          />
        ))}
      </div>
    );
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "12px 16px", color: "var(--cv-text-muted)" }}>
      <span
        aria-hidden="true"
        style={{
          width: 12,
          height: 12,
          borderRadius: "50%",
          border: "2px solid currentColor",
          borderRightColor: "transparent",
        }}
      />
      Loading messages…
    </div>
  );
}
const at = Date.UTC(2026, 9, 29, 12);

export default componentEntry<Props>({
  id: "agent-pane.subagent-empty",
  title: "Empty agent conversation",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: [
    "agent-session/acpmux/subagents/subagentRows.ts#childView",
    "agent-session/acpmux/subagents/subagentOwnLog.ts#subagentPaneView",
  ],
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
          if (props.pending && props.look && props.look !== "words") return <RejectedLoading look={props.look} />;
          const rows = props.pending
            ? subagentPaneView(
                "reviewer",
                { rows: [reply], views: {} },
                props.pending === "loading"
                  ? { loading: true }
                  : { loading: false, log: foldOwnLog("reviewer", [], { session: "gallery" }) },
                new Set(),
                props.parent ?? "Release review",
              )
            : childView(
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
    // A pane opened on a subagent the chat's rows no longer hold (Leo, 2026-11-07: "is this your
    // sub-agent, or is this literally just a duplicate of you?"): never the chat's rows.
    "own-loading": {
      props: { state: "completed", pending: "loading", look: "words" },
      note: "Picked: the empty row's shape with its first line saying Loading, so the swap to rows or to empty moves nothing.",
    },
    "own-loading-skeleton": {
      props: { state: "completed", pending: "loading", look: "skeleton" },
      note: "Not picked: bars guess a reply's shape, and the first real row jumps.",
    },
    "own-loading-spinner": {
      props: { state: "completed", pending: "loading", look: "spinner" },
      note: "Not picked: a spinner reads as the agent working, which a finished subagent is not.",
    },
    "own-missing": {
      props: { state: "completed", pending: "missing" },
      note: "Its own records came back empty: the empty row, never the chat's rows.",
    },
    "long-parent": {
      props: { state: "completed", parent: "Release review for the very long project name with several components" },
    },
  },
});
