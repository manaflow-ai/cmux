import { useState } from "react";
import { CommentComposer } from "./CommentComposer";
import { commentDisplayName } from "./format";
import type { DiffCommentLabels } from "./labels";
import type { CommentAttachState, CommentTarget, DiffCommentRecord } from "./types";

export function SavedComment({
  attachState,
  bridgeAvailable,
  comment,
  labels,
  onAttach,
  onDelete,
  onSaveMessage,
}: {
  attachState: CommentAttachState;
  bridgeAvailable: boolean;
  comment: DiffCommentRecord;
  labels: DiffCommentLabels;
  onAttach: (target: CommentTarget | undefined, explicit: boolean) => void;
  onDelete: () => void;
  onSaveMessage: (message: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  if (editing) {
    return (
      <CommentComposer
        initialMessage={comment.message}
        labels={labels}
        showAttachToggle={false}
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
      {bridgeAvailable ? (
        <CommentAttachArea attachState={attachState} labels={labels} onAttach={onAttach} />
      ) : null}
    </div>
  );
}

function CommentAttachArea({
  attachState,
  labels,
  onAttach,
}: {
  attachState: CommentAttachState;
  labels: DiffCommentLabels;
  onAttach: (target: CommentTarget | undefined, explicit: boolean) => void;
}) {
  switch (attachState.phase) {
  case "idle":
    return (
      <div className="comment-attach-area">
        <button type="button" className="comment-button" onClick={() => onAttach(undefined, false)}>
          {labels.attachComment}
        </button>
      </div>
    );
  case "attaching":
    return (
      <div className="comment-attach-area">
        <button type="button" className="comment-button" disabled>
          {labels.attachComment}
        </button>
      </div>
    );
  case "attached":
    return (
      <div className="comment-attach-area">
        <span className="comment-attach-status">
          {labels.attachedComment} · {attachState.terminal.title}
        </span>
      </div>
    );
  case "failed":
    return (
      <div className="comment-attach-area">
        <span className="comment-attach-muted">{labels.attachFailed}</span>
        <button type="button" className="comment-button" onClick={() => onAttach(undefined, false)}>
          {labels.attachComment}
        </button>
      </div>
    );
  case "picker":
    return (
      <div className="comment-attach-area comment-attach-picker">
        <span className="comment-attach-muted">{labels.chooseTerminal}</span>
        {attachState.candidates.map((candidate) => (
          <button
            key={candidate.surfaceId}
            type="button"
            className="comment-picker-item"
            onClick={() => onAttach({ surfaceId: candidate.surfaceId }, true)}
          >
            <span className="comment-picker-title">{candidate.title}</span>
            {candidate.directory ? (
              <span className="comment-picker-directory">{candidate.directory}</span>
            ) : null}
            {candidate.hasActiveTextBox ? (
              <span className="comment-picker-badge" aria-hidden="true" />
            ) : null}
          </button>
        ))}
      </div>
    );
  case "unavailable":
    return (
      <div className="comment-attach-area">
        <span className="comment-attach-muted">{labels.noTerminalForAttach}</span>
      </div>
    );
  }
}
