import { useState } from "react";
import { CommentComposer } from "./CommentComposer";
import { commentDisplayName } from "./format";
import type { DiffCommentLabels } from "./labels";
import type { DiffCommentRecord } from "./types";

export function SavedComment({
  comment,
  labels,
  onDelete,
  onReply,
  onSaveMessage,
}: {
  comment: DiffCommentRecord;
  labels: DiffCommentLabels;
  onDelete: () => void;
  /** With a host that keeps threads: saves `message` as a new comment on this anchor and sends it. */
  onReply?: (message: string) => void;
  onSaveMessage: (message: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [replying, setReplying] = useState(false);
  const thread = comment.thread;
  if (editing && thread == null) {
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
    <div className="comment-card" data-comment-id={comment.id} data-thread-state={thread?.state}>
      <div className="comment-card-header">
        <span className="comment-card-location">{commentDisplayName(comment)}</span>
        <span className="comment-card-actions">
          {thread == null ? (
            <>
              <button type="button" className="comment-card-action" onClick={() => setEditing(true)}>
                {labels.editComment}
              </button>
              <button type="button" className="comment-card-action" onClick={onDelete}>
                {labels.deleteComment}
              </button>
            </>
          ) : (
            <>
              {onReply != null && thread.state !== "sent" ? (
                <button type="button" className="comment-card-action" onClick={() => setReplying(true)}>
                  {labels.threadReply}
                </button>
              ) : null}
              <button type="button" className="comment-card-action" onClick={onDelete}>
                {labels.threadResolve}
              </button>
            </>
          )}
        </span>
      </div>
      <div className="comment-card-message">{comment.message}</div>
      {thread?.state === "sent" ? <div className="comment-thread-status">{labels.threadSent}</div> : null}
      {thread?.state === "failed" ? (
        <div className="comment-thread-status" data-failed="true">
          {labels.threadFailed}
        </div>
      ) : null}
      {thread?.state === "answered" && thread.reply != null ? (
        <div className="comment-thread-reply">{thread.reply.text}</div>
      ) : null}
      {replying && onReply != null ? (
        <CommentComposer
          labels={{ ...labels, commentPlaceholder: labels.threadReplyPlaceholder, saveComment: labels.threadReply }}
          onCancel={() => setReplying(false)}
          onSave={(message) => {
            onReply(message);
            setReplying(false);
          }}
        />
      ) : null}
    </div>
  );
}
