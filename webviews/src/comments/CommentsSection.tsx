import { commentDisplayName } from "./format";
import type { SidebarCommentEntry } from "./annotations";
import type { DiffCommentLabels } from "./labels";
import type { CommentsSendState } from "./types";

/**
 * The sidebar's saved comments. With a host that sends to the diff's chat (`onSend`), the header's
 * trailing button sends them all as one prompt; it keeps its width while sending, so nothing in
 * the header moves, and a refusal shows under the header with the comments still listed.
 */
export function CommentsSidebarSection({
  entries,
  hasDraft,
  labels,
  onSelect,
  onSend,
  sendState = "idle",
}: {
  entries: SidebarCommentEntry[];
  hasDraft: boolean;
  labels: DiffCommentLabels;
  onSelect: (entry: SidebarCommentEntry) => void;
  onSend?: () => void;
  sendState?: CommentsSendState;
}) {
  if (entries.length === 0 && !hasDraft) {
    return null;
  }
  return (
    <div id="comments-section" aria-label={labels.comments}>
      <div id="comments-header">
        <span id="comments-title">{`${labels.comments} (${entries.length})`}</span>
        {onSend ? (
          <button
            type="button"
            id="comments-send"
            className="comment-button comment-button-primary"
            data-state={sendState}
            disabled={entries.length === 0 || sendState === "sending"}
            onClick={onSend}
          >
            {/* Both labels are laid out in one cell, so the button is as wide as the longer. */}
            <span aria-hidden={sendState === "sending"}>{labels.sendComments}</span>
            <span aria-hidden={sendState !== "sending"}>{labels.sendingComments}</span>
          </button>
        ) : null}
      </div>
      {sendState === "failed" ? <output id="comments-send-error">{labels.sendCommentsFailed}</output> : null}
      <div id="comments-list">
        {entries.length === 0 ? (
          <div className="comments-empty">{labels.noComments}</div>
        ) : (
          entries.map((entry) => (
            <button key={entry.comment.id} type="button" className="comment-entry" onClick={() => onSelect(entry)}>
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
