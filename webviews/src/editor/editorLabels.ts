const DEFAULT_EDITOR_LABELS = {
  conflictChanged: "The file changed on disk after it was opened.",
  conflictMissing: "The file no longer exists on disk.",
  dismiss: "Dismiss",
  modified: "Modified",
  overwrite: "Overwrite",
  readOnly: "Read-only",
  saved: "Saved",
  saveFailed: "Could not save the file.",
  savePermissionDenied: "You don't have permission to save this file.",
  saveUnavailable: "Saving is unavailable for this editor.",
  saving: "Saving…",
  useDiskVersion: "Use disk version",
} as const;

export type EditorLabelKey = keyof typeof DEFAULT_EDITOR_LABELS;
export type EditorLabelResolver = (key: EditorLabelKey) => string;

/**
 * Resolves editor surface labels from the localized map injected by the CLI
 * (`cmux edit` looks the strings up in the app's string catalog), falling back
 * to the English defaults when a key is missing.
 */
export function createEditorLabelResolver(
  labels: Record<string, string> | undefined,
): EditorLabelResolver {
  return (key) => {
    const localizedValue = labels?.[key];
    if (typeof localizedValue === "string" && localizedValue.trim() !== "") {
      return localizedValue;
    }
    return DEFAULT_EDITOR_LABELS[key];
  };
}
