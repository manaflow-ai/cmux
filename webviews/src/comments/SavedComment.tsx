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
  onReply,
  onResolve,
  replyOpen = false,
  threads = false,
}: {
  comment: DiffCommentRecord;
  labels: DiffCommentLabels;
  onDelete: () => void;
  onSaveMessage: (message: string) => void;
  onReply?: (message: string) => void;
  onResolve?: (resolved: boolean) => void;
  replyOpen?: boolean;
  threads?: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const [replying, setReplying] = useState(replyOpen);
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
  const resolved = threads && comment.resolved === true;
  return (
    <div className={`comment-card${resolved ? " comment-card-resolved" : ""}`} data-comment-id={comment.id}>
      <div className="comment-card-header">
        <span className="comment-card-location">{commentDisplayName(comment)}</span>
        <span className="comment-card-actions">
          <button type="button" className="comment-card-action" onClick={() => setEditing(true)}>
            {labels.editComment}
          </button>
          <button type="button" className="comment-card-action" onClick={onDelete}>
            {labels.deleteComment}
          </button>
          {threads && onResolve ? (
            <button type="button" className="comment-card-action" onClick={() => onResolve(!resolved)}>
              {resolved ? labels.reopenComment : labels.resolveComment}
            </button>
          ) : null}
        </span>
      </div>
      <div className="comment-card-message">{comment.message}</div>
      {threads ? (
        <div className="comment-thread" data-resolved={resolved || undefined}>
          {(comment.replies ?? []).map((reply) => (
            <div className="comment-thread-reply" key={reply.id}>
              <div className="comment-thread-reply-header">
                <span>{reply.author === "agent" ? labels.agent : labels.you}</span>
              </div>
              <div className="comment-thread-reply-text">{reply.text}</div>
            </div>
          ))}
          {onReply ? (
            replying ? (
              <CommentComposer
                labels={labels}
                inputLabel={labels.replyComment}
                placeholder={labels.replyPlaceholder}
                saveLabel={labels.replyComment}
                onCancel={() => setReplying(false)}
                onSave={(message) => {
                  onReply(message);
                  setReplying(false);
                }}
              />
            ) : (
              <button
                type="button"
                className="comment-card-action comment-thread-reply-button"
                onClick={() => setReplying(true)}
              >
                {labels.replyComment}
              </button>
            )
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
