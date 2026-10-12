// The identity helpers every gallery file builds its entry with. What they return is the entry
// the gallery coverage check reads (covers, id), so editing them owns every coverage finding
// (test/gallery-coverage.test.ts); format.ts re-exports them.
import type {
  AgentPaneEntry,
  AppsPageEntry,
  ChangelogPageEntry,
  CloudPageEntry,
  CodeRouterPageEntry,
  ComponentEntry,
  DiffPageEntry,
  EditorPageEntry,
  HistoryPageEntry,
  IconPickerPageEntry,
  KeybindingsPageEntry,
  MarkdownPageEntry,
  NativeEntry,
  PasswordsPageEntry,
  SettingsPageEntry,
} from "./format";

export const settingsPageEntry = (entry: Omit<SettingsPageEntry, "host">): SettingsPageEntry => ({
  ...entry,
  host: "settings-page",
});
export const passwordsPageEntry = (entry: Omit<PasswordsPageEntry, "host">): PasswordsPageEntry => ({
  ...entry,
  host: "passwords-page",
});
/** Identity helpers that check an entry against its host's variant type. */
export const agentPaneEntry = (entry: Omit<AgentPaneEntry, "host">): AgentPaneEntry => ({
  ...entry,
  host: "agent-pane",
});
export const markdownPageEntry = (entry: Omit<MarkdownPageEntry, "host">): MarkdownPageEntry => ({
  ...entry,
  host: "markdown-page",
});
export const diffPageEntry = (entry: Omit<DiffPageEntry, "host">): DiffPageEntry => ({ ...entry, host: "diff-page" });
export const appsPageEntry = (entry: Omit<AppsPageEntry, "host">): AppsPageEntry => ({ ...entry, host: "apps-page" });
export const cloudPageEntry = (entry: Omit<CloudPageEntry, "host">): CloudPageEntry => ({
  ...entry,
  host: "cloud-page",
});
export const codeRouterPageEntry = (entry: Omit<CodeRouterPageEntry, "host">): CodeRouterPageEntry => ({
  ...entry,
  host: "coderouter-page",
});
export const changelogPageEntry = (entry: Omit<ChangelogPageEntry, "host">): ChangelogPageEntry => ({
  ...entry,
  host: "changelog-page",
});
export const iconPickerPageEntry = (entry: Omit<IconPickerPageEntry, "host">): IconPickerPageEntry => ({
  ...entry,
  host: "icon-picker-page",
});
export const editorPageEntry = (entry: Omit<EditorPageEntry, "host">): EditorPageEntry => ({
  ...entry,
  host: "editor-page",
});
export const historyPageEntry = (entry: Omit<HistoryPageEntry, "host">): HistoryPageEntry => ({
  ...entry,
  host: "history-page",
});
export const keybindingsPageEntry = (entry: Omit<KeybindingsPageEntry, "host">): KeybindingsPageEntry => ({
  ...entry,
  host: "keybindings-page",
});
export function componentEntry<P>(entry: Omit<ComponentEntry<P>, "host">): ComponentEntry<P> {
  return { ...entry, host: "component" };
}
export const nativeEntry = (entry: Omit<NativeEntry, "host">): NativeEntry => ({ ...entry, host: "native" });
