import { commentDisplayName } from "./format";
import type { SidebarCommentEntry } from "./annotations";
import type { DiffCommentLabels } from "./labels";

export function CommentsSidebarSection({
  entries,
  hasDraft,
  labels,
  onSelect,
}: {
  entries: SidebarCommentEntry[];
  hasDraft: boolean;
  labels: DiffCommentLabels;
  onSelect: (entry: SidebarCommentEntry) => void;
}) {
  if (entries.length === 0 && !hasDraft) {
    return null;
  }
  return (
    <div id="comments-section" aria-label={labels.comments}>
      <div id="comments-header">
        <span id="comments-title">{`${labels.comments} (${entries.length})`}</span>
      </div>
      <div id="comments-list">
        {entries.length === 0 ? (
          <div className="comments-empty">{labels.noComments}</div>
        ) : (
          entries.map((entry) => (
            <button
              key={entry.comment.id}
              type="button"
              className="comment-entry"
              onClick={() => onSelect(entry)}
            >
              <span className="comment-entry-header">
                <span className="comment-entry-location">{commentDisplayName(entry.comment)}</span>
                {!entry.pending && entry.anchor.state === "outdated" ? (
                  <span className="comment-entry-badge">{labels.outdatedComment}</span>
                ) : null}
              </span>
              <span className="comment-entry-message">{entry.comment.message}</span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}
