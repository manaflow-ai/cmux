// The editor's right-click menu is the app's standard macOS menu (ui/nativeMenu.ts; Lawrence
// 2026-10-23: "we don't want ANYTHING custom besides the icons"), not Monaco's page-drawn one. Its
// rows are the Monaco actions Monaco's own menu shows here (the page registers no language
// providers, so no Go to Definition or Format): Change All Occurrences, Cut, Copy, Paste and the
// Command Palette, each run by Monaco. Without a host (the dev loop) Monaco's menu stays.
import type * as monaco from "monaco-editor/editor/editor.api.js";
import { nativeMenu, pickedId, type NativeMenuRow } from "../../ui/nativeMenu";
import { MONACO_QUICK_COMMAND } from "./keys";

/** Monaco's context menu groups, in its order. */
export const EDITOR_MENU_GROUPS: readonly (readonly string[])[] = [
  ["editor.action.changeAll"],
  ["editor.action.clipboardCutAction", "editor.action.clipboardCopyAction", "editor.action.clipboardPasteAction"],
  [MONACO_QUICK_COMMAND],
];

const SYMBOLS: Readonly<Record<string, string>> = {
  "editor.action.changeAll": "pencil",
  "editor.action.clipboardCutAction": "scissors",
  "editor.action.clipboardCopyAction": "doc.on.doc",
  "editor.action.clipboardPasteAction": "doc.on.clipboard",
  [MONACO_QUICK_COMMAND]: "command",
};

/** The menu's rows: each supported action with its Monaco label, a separator between groups. */
export function editorMenuRows(editor: Pick<monaco.editor.ICodeEditor, "getAction">): NativeMenuRow[] {
  const rows: NativeMenuRow[] = [];
  for (const group of EDITOR_MENU_GROUPS) {
    const actions = group.flatMap((id) => {
      const action = editor.getAction(id);
      return action?.isSupported() ? [action] : [];
    });
    if (actions.length === 0) continue;
    if (rows.length > 0) rows.push({ id: `separator:${actions[0]!.id}`, label: "", separator: true });
    for (const action of actions) rows.push({ id: action.id, label: action.label, symbol: SYMBOLS[action.id] });
  }
  return rows;
}

/**
 * Opens the app's menu on a right-click in the editor, before Monaco sees it. As Monaco does, a
 * right-click outside the selection moves the caret there first.
 *
 * `commands`: rows the page replaces in Monaco's command registry (the Command Palette is the app's
 * palette, view.ts). Monaco's own menu runs a row through that registry; `getAction(id).run()` runs
 * Monaco's original action and would skip the replacement, so a replaced row runs its command here.
 */
export function installNativeEditorMenu(
  editor: monaco.editor.ICodeEditor,
  container: HTMLElement,
  commands: Readonly<Record<string, () => void>> = {},
): { dispose(): void } {
  const open = (event: MouseEvent) => {
    const native = nativeMenu();
    if (!native) return;
    const rows = editorMenuRows(editor);
    if (rows.length === 0) return;
    event.preventDefault();
    event.stopPropagation();
    const position = editor.getTargetAtClientPoint(event.clientX, event.clientY)?.position;
    const selection = editor.getSelection();
    if (position && !selection?.containsPosition(position)) editor.setPosition(position);
    editor.focus();
    native({ items: rows, point: { x: event.clientX, y: event.clientY } }).then(
      (reply) => {
        const id = pickedId(reply);
        editor.focus();
        if (!id) return;
        const command = commands[id];
        if (command) command();
        else void editor.getAction(id)?.run();
      },
      () => undefined,
    );
  };
  container.addEventListener("contextmenu", open, true);
  return { dispose: () => container.removeEventListener("contextmenu", open, true) };
}
