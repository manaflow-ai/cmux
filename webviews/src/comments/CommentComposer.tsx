import { useCallback, useState } from "react";
import type { DiffCommentLabels } from "./labels";

export function CommentComposer({
  initialMessage = "",
  inputLabel,
  labels,
  onCancel,
  onSave,
  placeholder,
  saveLabel,
}: {
  initialMessage?: string;
  inputLabel?: string;
  labels: DiffCommentLabels;
  onCancel: () => void;
  onSave: (message: string) => void;
  placeholder?: string;
  saveLabel?: string;
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
        placeholder={placeholder ?? labels.commentPlaceholder}
        aria-label={inputLabel ?? labels.addComment}
        rows={3}
        value={message}
        onChange={(event) => setMessage(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && message.trim() !== "") {
            event.preventDefault();
            onSave(message);
          }
        }}
      />
      <div className="comment-composer-footer">
        <span />
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
            {saveLabel ?? labels.saveComment}
          </button>
        </span>
      </div>
    </div>
  );
}
