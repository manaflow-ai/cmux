// l10n-allow-file: gallery fixtures (sample review comments), not shipped UI.
// The diff viewer's Comments section with Send to agent (hq #7563): the landed design (the
// header's trailing button) in each send state, and the two placements it was chosen over.
import { componentEntry } from "../gallery/format";
import type { SidebarCommentEntry } from "./annotations";
import { CommentsSidebarSection } from "./CommentsSection";
import { commentDisplayName } from "./format";
import { resolveCommentLabels } from "./labels";
import type { CommentsSendState, DiffCommentRecord } from "./types";

const record = (id: string, filePath: string, line: number, message: string): DiffCommentRecord => ({
  id,
  filePath,
  side: "additions",
  startLine: line,
  endLine: line,
  lineText: "",
  message,
  createdAt: "2026-11-07T00:00:00.000Z",
  updatedAt: "2026-11-07T00:00:00.000Z",
});

const COMMENTS = [
  record("c1", "src/net/client.ts", 3, "Three attempts is low for uploads; take it from config."),
  record("c2", "src/net/retry.ts", 5, "Back off between attempts instead of retrying at once."),
  record("c3", "src/net/config.ts", 12, "Keep v1 as a fallback until the server rolls out."),
];

const entries = (count: number): SidebarCommentEntry[] =>
  COMMENTS.slice(0, count).map((comment) => ({
    comment,
    anchor: { state: "anchored" as const, line: comment.endLine },
    pending: false,
    itemId: comment.filePath,
  }));

type Design = "header" | "footer" | "link";
type Props = { design?: Design; count?: number; state?: CommentsSendState };

/** The sidebar's bottom, as FilesSidebar lays it out: the section under a stand-in file tree. */
function CommentsSendStage({ design = "header", count = 2, state = "idle" }: Props) {
  const labels = resolveCommentLabels(undefined);
  const list = entries(count);
  return (
    <aside style={{ position: "relative", display: "flex", flexDirection: "column", height: "100%", width: 300 }}>
      <div style={{ flex: "1 1 auto" }} />
      {design === "header" ? (
        <CommentsSidebarSection
          entries={list}
          hasDraft={false}
          labels={labels}
          onSelect={() => {}}
          onSend={() => {}}
          sendState={state}
        />
      ) : (
        <AlternativeSection design={design} list={list} labels={labels} state={state} />
      )}
    </aside>
  );
}

/** A placement not taken, drawn with the same parts so the comparison is only the placement. */
function AlternativeSection({
  design,
  list,
  labels,
  state,
}: {
  design: Exclude<Design, "header">;
  list: SidebarCommentEntry[];
  labels: ReturnType<typeof resolveCommentLabels>;
  state: CommentsSendState;
}) {
  const label = state === "sending" ? labels.sendingComments : labels.sendComments;
  return (
    <div id="comments-section" aria-label={labels.comments}>
      <div id="comments-header">
        <span id="comments-title">{`${labels.comments} (${list.length})`}</span>
        {design === "link" ? (
          <button
            type="button"
            className="comment-button"
            style={{ padding: "0 4px", color: "var(--cmux-diff-accent)" }}
          >
            {label}
          </button>
        ) : null}
      </div>
      <div id="comments-list">
        {list.map((entry) => (
          <button key={entry.comment.id} type="button" className="comment-entry">
            <span className="comment-entry-header">
              <span className="comment-entry-location">{commentDisplayName(entry.comment)}</span>
            </span>
            <span className="comment-entry-message">{entry.comment.message}</span>
          </button>
        ))}
      </div>
      {design === "footer" ? (
        <div style={{ padding: "4px 8px 8px" }}>
          <button type="button" className="comment-button comment-button-primary" style={{ width: "100%" }}>
            {label}
          </button>
        </div>
      ) : null}
    </div>
  );
}

export default componentEntry<Props>({
  id: "diff.comments-send",
  title: "Diff comments: Send to agent",
  area: "Pages",
  height: 300,
  widths: { normal: 300 },
  covers: ["comments/CommentsSection.tsx"],
  styles: () => import("../styles.css"),
  load: async () => CommentsSendStage,
  variants: {
    "header-idle": {
      props: { design: "header", count: 2 },
      note: "Landed: the header's trailing button. No extra row; the list keeps its height and place.",
    },
    "header-sending": {
      props: { design: "header", count: 2, state: "sending" },
      note: "Sending: the button keeps its width (both labels share one cell), so the header never moves.",
    },
    "header-failed": {
      props: { design: "header", count: 2, state: "failed" },
      note: "Refused: the comments stay listed and one line under the header says so.",
    },
    "header-many": {
      props: { design: "header", count: 3 },
      note: "Three comments across three files.",
    },
    "alt-footer": {
      props: { design: "footer", count: 2 },
      note: "Not taken: a full-width bar under the list adds a row and pushes the list up when it appears.",
    },
    "alt-link": {
      props: { design: "link", count: 2 },
      note: "Not taken: a text link in the header reads as secondary for the review's main action.",
    },
  },
});
