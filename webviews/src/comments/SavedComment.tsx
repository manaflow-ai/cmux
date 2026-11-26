import { useState } from "react";
import { CommentComposer } from "./CommentComposer";
import { commentDisplayName } from "./format";
import type { DiffCommentLabels } from "./labels";
import type { DiffCommentRecord } from "./types";

export function SavedComment({
  comment,
  labels,
  onDelete,
  onSaveMessage,
}: {
  comment: DiffCommentRecord;
  labels: DiffCommentLabels;
  onDelete: () => void;
  onSaveMessage: (message: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  if (editing) {
    return (
      <CommentComposer
        initialMessage={comment.message}
        labels={labels}
        onCancel={() => setEditing(false)}
        onSave={(message) => {
          onSaveMessage(message);
          setEditing(false);
        }}
      />
    );
  }
  return (
    <div className="comment-card" data-comment-id={comment.id}>
      <div className="comment-card-header">
        <span className="comment-card-location">{commentDisplayName(comment)}</span>
        <span className="comment-card-actions">
          <button type="button" className="comment-card-action" onClick={() => setEditing(true)}>
            {labels.editComment}
          </button>
          <button type="button" className="comment-card-action" onClick={onDelete}>
            {labels.deleteComment}
          </button>
        </span>
      </div>
      <div className="comment-card-message">{comment.message}</div>
    </div>
  );
}
