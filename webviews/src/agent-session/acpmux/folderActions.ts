// The chat's folder one click away on every surface the pane draws (the chat's ··· menu, the header,
// Session Info, the changed-files card, the worktree pill): Open in Editor (the person's default
// editor by name, "Open in Zed"), Open In ▸ (the other editors installed), Reveal in Finder, Open
// Terminal Here and Copy Path; and for one changed file, Open in Editor, Reveal in Finder and Copy Path.
//
// The app runs them: the folder's through `action.run { id, session, app? }` (the chat's own actions,
// AgentPaneModel+Actions.swift), bound to the chat the surface was drawn for, a file's through
// `file.open { path, where: "editor" | "finder" }`. Copy Path copies in the page. The editors come from
// `editors.list` (`{ default: {id, name} | null, others: [{id, name}] }`), read once and again when a
// menu opens. A chat that does not run on this Mac (a peer, an SSH host, a Cloud machine) gets none
// of these: the App provides no FolderHost for it.
import { createContext, useContext, useSyncExternalStore } from "react";
import type { ContextMenuItem } from "../../ui/ContextMenu";
import type { Translate } from "./i18n";
import type { ChatMenuChild } from "./header/chatHeaderToolsModel";

/// The app actions a folder row runs (cmux-action-catalog).
export const FOLDER_ACTIONS = {
  openInEditor: "agentPane.openCwdInEditor",
  openInApp: "agentPane.openCwdInApp",
  reveal: "agentPane.revealCwdInFinder",
  terminal: "agentPane.openCwdInTerminal",
} as const;
export type FolderActionId = (typeof FOLDER_ACTIONS)[keyof typeof FOLDER_ACTIONS];

export type Editor = { id: string; name: string };
/// The editors installed on this Mac: the default one (the setting's, else the first installed) and
/// the others, in the app's order. `default` is null when none is installed.
export type EditorList = { default: Editor | null; others: readonly Editor[] };

/// An editor id the app takes as `app` (the editor table's ids).
const EDITOR_ID = /^[a-z0-9-]{1,32}$/;

function readEditor(value: unknown): Editor | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { id, name } = value as { id?: unknown; name?: unknown };
  if (typeof id !== "string" || !EDITOR_ID.test(id) || typeof name !== "string" || !name.trim()) return undefined;
  return { id, name: name.trim() };
}

/// `editors.list`'s answer, or undefined when it is not one (an older app answers null).
export function readEditorList(value: unknown): EditorList | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as { default?: unknown; others?: unknown };
  const first = readEditor(raw.default) ?? null;
  const seen = new Set(first ? [first.id] : []);
  const others: Editor[] = [];
  for (const entry of Array.isArray(raw.others) ? raw.others : []) {
    const editor = readEditor(entry);
    if (!editor || seen.has(editor.id)) continue;
    seen.add(editor.id);
    others.push(editor);
  }
  return { default: first, others };
}

let editors: EditorList | undefined;
let reading: Promise<void> | undefined;
const listeners = new Set<() => void>();
const sameList = (a: EditorList | undefined, b: EditorList | undefined) => JSON.stringify(a) === JSON.stringify(b);

/// Sets the editor list the surfaces read (the app's answer; a test or gallery's fixture).
export function setEditors(next: EditorList | undefined): void {
  if (sameList(next, editors)) return;
  editors = next;
  for (const listener of listeners) listener();
}

/// Reads `editors.list` again through `read`; one read at a time. A failed read keeps the last list.
export function refreshEditors(read: () => Promise<unknown>): Promise<void> {
  reading ??= read()
    .then(
      (value) => {
        const next = readEditorList(value);
        if (next) setEditors(next);
      },
      () => undefined,
    )
    .finally(() => {
      reading = undefined;
    });
  return reading;
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => editors;

/// The editor list now (undefined until the app answered).
export const editorList = (): EditorList | undefined => editors;
/// The live editor list.
export const useEditors = (): EditorList | undefined => useSyncExternalStore(subscribe, current, current);

/// What the surfaces run the folder actions through. The App provides one only for a chat whose
/// folder is on this Mac and only inside the app.
export type FolderHost = {
  /// The chat's folder on this Mac.
  folder: string;
  /// The chat's acpmux session (none before its first message): every row runs for the chat it was
  /// drawn for, so a menu kept open across a chat switch runs nothing on the new one.
  session: string | undefined;
  /// `action.run { id, session, app? }`; a refusal shows the app's reason in a toast.
  run(id: FolderActionId, session: string | undefined, app?: string): void;
  /// `file.open { path, where }`.
  openFile(path: string, where: "editor" | "finder"): void;
  copy(text: string): void;
};

export const FolderHostContext = createContext<FolderHost | undefined>(undefined);
export const useFolderHost = (): FolderHost | undefined => useContext(FolderHostContext);

/// "Open in Zed" when the default editor is known, else "Open in Editor".
export function openInEditorLabel(list: EditorList | undefined, t: Translate): string {
  return list?.default ? t("folderMenu.openInNamed", { editor: list.default.name }) : t("folderMenu.openInEditor");
}

/// One folder action: a row on every surface, with the editors under Open In.
export type FolderAction = {
  key: "openInEditor" | "openIn" | "reveal" | "terminal" | "copyPath";
  label: string;
  icon: string;
  run?: () => void;
  editors?: readonly { key: string; label: string; run: () => void }[];
};

/// The folder's rows, in order: Open in Editor, Open In ▸ (only with other editors installed),
/// Reveal in Finder, Open Terminal Here (unless `terminal` is false), Copy Path. Each runs for the
/// session `host` names now.
export function folderActions(
  host: FolderHost,
  list: EditorList | undefined,
  t: Translate,
  options: { terminal?: boolean } = {},
): FolderAction[] {
  const { session, folder } = host;
  const rows: FolderAction[] = [
    {
      key: "openInEditor",
      label: openInEditorLabel(list, t),
      icon: "code",
      run: () => host.run(FOLDER_ACTIONS.openInEditor, session),
    },
  ];
  if (list && list.others.length > 0)
    rows.push({
      key: "openIn",
      label: t("folderMenu.openIn"),
      icon: "app.open.external",
      editors: list.others.map((editor) => ({
        key: `openIn-${editor.id}`,
        label: editor.name,
        run: () => host.run(FOLDER_ACTIONS.openInApp, session, editor.id),
      })),
    });
  rows.push({
    key: "reveal",
    label: t("folderMenu.revealInFinder"),
    icon: "folder",
    run: () => host.run(FOLDER_ACTIONS.reveal, session),
  });
  if (options.terminal !== false)
    rows.push({
      key: "terminal",
      label: t("folderMenu.openTerminalHere"),
      icon: "terminal",
      run: () => host.run(FOLDER_ACTIONS.terminal, session),
    });
  rows.push({ key: "copyPath", label: t("folderMenu.copyPath"), icon: "action.copy", run: () => host.copy(folder) });
  return rows;
}

/// The folder's rows as a chat menu submenu's rows (Open In's editors one level further in).
export function folderMenuChildren(actions: readonly FolderAction[]): ChatMenuChild[] {
  return actions.map((action) =>
    action.editors
      ? {
          key: action.key,
          label: action.label,
          onSelect: () => undefined,
          children: action.editors.map((editor) => ({ key: editor.key, label: editor.label, onSelect: editor.run })),
        }
      : { key: action.key, label: action.label, onSelect: action.run ?? (() => undefined) },
  );
}

/// A changed file's right-click rows: Open in Editor (the default editor, `file.open` `editor`),
/// Reveal in Finder (`file.open` `finder`), Copy Path.
export function fileMenuItems(
  path: string,
  host: FolderHost,
  list: EditorList | undefined,
  t: Translate,
): ContextMenuItem[] {
  return [
    { id: "openInEditor", label: openInEditorLabel(list, t), onSelect: () => host.openFile(path, "editor") },
    { id: "reveal", label: t("folderMenu.revealInFinder"), onSelect: () => host.openFile(path, "finder") },
    { id: "copyPath", label: t("folderMenu.copyPath"), onSelect: () => host.copy(path) },
  ];
}

/// `path` as the app opens it: absolute, from the first of `roots` when the agent wrote it relative.
export function absolutePath(path: string, roots: readonly (string | undefined)[]): string | undefined {
  if (path.startsWith("/")) return path;
  const root = roots.find((one) => one?.startsWith("/"));
  if (!root || !path) return undefined;
  return `${root.replace(/\/+$/, "")}/${path.replace(/^\.\//, "")}`;
}
