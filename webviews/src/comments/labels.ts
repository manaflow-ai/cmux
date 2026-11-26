const DIFF_COMMENT_LABEL_FALLBACKS = {
  comments: "Comments",
  addComment: "Add comment",
  commentPlaceholder: "Leave a comment",
  saveComment: "Comment",
  cancelComment: "Cancel",
  deleteComment: "Delete",
  editComment: "Edit",
  outdatedComment: "Outdated",
  noComments: "No comments yet",
} as const;

export type DiffCommentLabelKey = keyof typeof DIFF_COMMENT_LABEL_FALLBACKS;
export type DiffCommentLabels = Record<DiffCommentLabelKey, string>;

type LabelsPayload = { labels?: Record<string, string> } | null | undefined;

/**
 * Resolves a comments label from the payload with an inline fallback. These
 * keys are newer than the base diff viewer labels, so older payloads may not
 * carry them; unlike the main resolver this never asserts on missing keys.
 */
export function commentLabel(payload: LabelsPayload, key: DiffCommentLabelKey, fallback: string): string {
  return payload?.labels?.[key] ?? fallback;
}

export function resolveCommentLabels(payload: LabelsPayload): DiffCommentLabels {
  const labels = {} as DiffCommentLabels;
  for (const key of Object.keys(DIFF_COMMENT_LABEL_FALLBACKS) as DiffCommentLabelKey[]) {
    labels[key] = commentLabel(payload, key, DIFF_COMMENT_LABEL_FALLBACKS[key]);
  }
  return labels;
}
