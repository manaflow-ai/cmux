import { useCallback, useState } from "react";
import type { DiffCommentLabels } from "./labels";

export function CommentComposer({
  attachOnSave = false,
  initialMessage = "",
  labels,
  onAttachOnSaveChange,
  onCancel,
  onSave,
  showAttachToggle,
}: {
  attachOnSave?: boolean;
  initialMessage?: string;
  labels: DiffCommentLabels;
  onAttachOnSaveChange?: (value: boolean) => void;
  onCancel: () => void;
  onSave: (message: string) => void;
  showAttachToggle: boolean;
}) {
  const [message, setMessage] = useState(initialMessage);
  const focusOnMount = useCallback((node: HTMLTextAreaElement | null) => {
    node?.focus();
  }, []);
  return (
    <div className="comment-composer">
      <textarea
        ref={focusOnMount}
        className="comment-composer-input"
        placeholder={labels.commentPlaceholder}
        aria-label={labels.addComment}
        rows={3}
        value={message}
        onChange={(event) => setMessage(event.currentTarget.value)}
      />
      <div className="comment-composer-footer">
        {showAttachToggle ? (
          <label className="comment-attach-toggle">
            <input
              type="checkbox"
              aria-label={labels.attachOnSave}
              checked={attachOnSave}
              onChange={(event) => onAttachOnSaveChange?.(event.currentTarget.checked)}
            />
            <span>{labels.attachOnSave}</span>
          </label>
        ) : (
          <span />
        )}
        <span className="comment-composer-buttons">
          <button type="button" className="comment-button" onClick={onCancel}>
            {labels.cancelComment}
          </button>
          <button
            type="button"
            className="comment-button comment-button-primary"
            disabled={message.trim() === ""}
            onClick={() => onSave(message)}
          >
            {labels.saveComment}
          </button>
        </span>
      </div>
    </div>
  );
}
