import { useCallback, useState } from "react";
import { attachTargetOptionLabels } from "./format";
import type { DiffCommentLabels } from "./labels";
import type { AttachTargets } from "./types";

const noAttachValue = "__none__";

export function CommentComposer({
  attachOnSave = false,
  attachTargets = null,
  initialMessage = "",
  labels,
  onAttachOnSaveChange,
  onCancel,
  onSave,
  showAttachToggle,
}: {
  attachOnSave?: boolean;
  attachTargets?: AttachTargets | null;
  initialMessage?: string;
  labels: DiffCommentLabels;
  onAttachOnSaveChange?: (value: boolean) => void;
  onCancel: () => void;
  onSave: (message: string, targetSurfaceId: string | null) => void;
  showAttachToggle: boolean;
}) {
  const [message, setMessage] = useState(initialMessage);
  // Targets load async after the composer mounts, so the selection is derived
  // until the user explicitly picks one.
  const [chosenTarget, setChosenTarget] = useState<string | null>(null);
  const candidates = attachTargets?.candidates ?? [];
  const defaultTarget = attachTargets?.defaultSurfaceId ?? candidates[0]?.surfaceId ?? noAttachValue;
  const target = chosenTarget ?? (attachOnSave ? defaultTarget : noAttachValue);
  const focusOnMount = useCallback((node: HTMLTextAreaElement | null) => {
    node?.focus();
  }, []);
  const showTargetSelect = showAttachToggle && candidates.length > 0;
  const targetLabels = attachTargetOptionLabels(candidates);
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
        {showTargetSelect ? (
          <label className="comment-attach-target">
            <span className="comment-attach-target-label">{labels.attachTo}</span>
            <select
              className="comment-attach-target-select"
              aria-label={labels.attachTo}
              value={target}
              onChange={(event) => {
                const value = event.currentTarget.value;
                setChosenTarget(value);
                onAttachOnSaveChange?.(value !== noAttachValue);
              }}
            >
              {candidates.map((candidate, index) => (
                <option key={candidate.surfaceId} value={candidate.surfaceId}>
                  {targetLabels[index]}
                </option>
              ))}
              <option value={noAttachValue}>{labels.dontAttach}</option>
            </select>
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
            onClick={() => onSave(message, showTargetSelect && target !== noAttachValue ? target : null)}
          >
            {labels.saveComment}
          </button>
        </span>
      </div>
    </div>
  );
}
