// Every string key the editor page uses. Values live in `Localizable.xcstrings` next to this file;
// scripts/pages/gen-strings.mjs writes `generated/strings.json`.
export const L = {
  title: "page.title",
  loading: "page.loading",
  failed: "page.failed",
  disconnected: "page.disconnected",
  retry: "page.retry",
  saved: "status.saved",
  edited: "status.edited",
  saving: "status.saving",
  statusFailed: "status.failed",
  readOnly: "status.readOnly",
  readOnlyOutside: "readOnly.outside",
  readOnlyEncoding: "readOnly.encoding",
  readOnlyBinary: "readOnly.binary",
  readOnlyPermission: "readOnly.permission",
  conflictChanged: "conflict.changed",
  conflictDeleted: "conflict.deleted",
  reload: "conflict.reload",
  keep: "conflict.keep",
  largeNotice: "large.notice",
  wordWrap: "toolbar.wordWrap",
  minimap: "toolbar.minimap",
  position: "status.position",
  spaces: "status.spaces",
  tabs: "status.tabs",
  utf8Bom: "status.utf8Bom",
  mixed: "status.mixed",
  plainText: "language.plain",
  editorLabel: "editor.label",
} as const;

/** The editor's empty state and its file picker (viewer-empty/EditorEmptyState.tsx). */
export const EMPTY = {
  title: "empty.title",
  subtitle: "empty.subtitle",
  choose: "empty.choose",
  drop: "empty.drop",
  recents: "empty.recents",
  pickerTitle: "picker.title",
  pickerEmpty: "picker.empty",
} as const;
