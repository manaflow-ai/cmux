// The editor's keys. Monaco handles plain typing, navigation and its own editing chords inside the
// editor; the app's single key dispatcher resolves every chord first (keybindings.md 4.2), so a chord
// bound in the app (Cmd-S, Cmd-P, Cmd-W ...) never reaches Monaco, except the app chords that yield
// to the editor (Cmd-D, Shift-Cmd-L, Cmd-L ...). App actions the
// editor should run arrive as page commands (`cmux.page.command`), mapped here to Monaco actions:
// the shared ones (`find`, `save`) and `editorAction` with a Monaco action id from `EDITOR_ACTIONS`,
// so the Keys lead can bind any of them under an editor context without a page change.
// README.md lists the Monaco chords that collide with app shortcuts and how each resolves.

export type EditorCommand =
  | "save"
  | "find"
  | "findNext"
  | "findPrevious"
  | "useSelectionForFind"
  | "hideFind"
  | "replace"
  | "gotoLine"
  | "zoomIn"
  | "zoomOut"
  | "zoomReset"
  | "editorAction";

/** The Monaco action each page command runs (`save` and `editorAction` are handled apart). */
const COMMAND_ACTIONS: Record<Exclude<EditorCommand, "save" | "editorAction">, string> = {
  find: "actions.find",
  findNext: "editor.action.nextMatchFindAction",
  findPrevious: "editor.action.previousMatchFindAction",
  useSelectionForFind: "actions.findWithSelection",
  hideFind: "closeFindWidget",
  replace: "editor.action.startFindReplaceAction",
  gotoLine: "editor.action.gotoLine",
  zoomIn: "editor.action.fontZoomIn",
  zoomOut: "editor.action.fontZoomOut",
  zoomReset: "editor.action.fontZoomReset",
};

/**
 * Monaco actions the dispatcher may run with `editorAction` (the ones whose default chord the app
 * takes, plus the common editing commands a user may want to rebind).
 */
export const EDITOR_ACTIONS: ReadonlySet<string> = new Set([
  "editor.action.addSelectionToNextFindMatch",
  "editor.action.moveSelectionToNextFindMatch",
  "editor.action.selectHighlights",
  "editor.action.changeAll",
  "editor.action.insertCursorAbove",
  "editor.action.insertCursorBelow",
  "editor.action.insertCursorAtEndOfEachLineSelected",
  "editor.action.copyLinesUpAction",
  "editor.action.copyLinesDownAction",
  "editor.action.moveLinesUpAction",
  "editor.action.moveLinesDownAction",
  "editor.action.deleteLines",
  "editor.action.insertLineAfter",
  "editor.action.insertLineBefore",
  "editor.action.indentLines",
  "editor.action.outdentLines",
  "editor.action.commentLine",
  "editor.action.blockComment",
  "editor.action.formatDocument",
  "editor.action.formatSelection",
  "editor.action.trimTrailingWhitespace",
  "editor.action.transformToUppercase",
  "editor.action.transformToLowercase",
  "editor.action.sortLinesAscending",
  "editor.action.sortLinesDescending",
  "editor.action.joinLines",
  "editor.action.jumpToBracket",
  "editor.action.selectToBracket",
  "editor.action.smartSelect.expand",
  "editor.action.smartSelect.shrink",
  "editor.action.expandLineSelection",
  "editor.action.triggerSuggest",
  "editor.action.gotoLine",
  "editor.action.startFindReplaceAction",
  "editor.fold",
  "editor.unfold",
  "editor.foldAll",
  "editor.unfoldAll",
  "editor.foldRecursively",
  "editor.unfoldRecursively",
  "editor.toggleFold",
  "editor.action.toggleWordWrap",
  "editor.action.toggleStickyScroll",
  "editor.action.toggleScreenReaderAccessibilityMode",
  "editor.action.accessibilityHelp",
  "editor.action.fontZoomIn",
  "editor.action.fontZoomOut",
  "editor.action.fontZoomReset",
  "cursorUndo",
  "cursorRedo",
]);

/**
 * Monaco's own command palette. It is not an `EDITOR_ACTIONS` id: the editor hands it to the app's
 * native command palette (view.ts), and no page command may open Monaco's widget.
 */
export const MONACO_QUICK_COMMAND = "editor.action.quickCommand";

export function isEditorAction(id: string): boolean {
  return EDITOR_ACTIONS.has(id);
}

/** The Monaco action id a page command runs, or null (`save` is the store's, not Monaco's). */
export function editorAction(command: EditorCommand, text?: string): string | null {
  if (command === "editorAction") return typeof text === "string" && isEditorAction(text) ? text : null;
  if (command === "save") return null;
  return COMMAND_ACTIONS[command] ?? null;
}

/** A place in the file, 1-based; the column counts UTF-16 code units (Monaco's). */
export interface RevealPosition {
  line: number;
  column: number;
}

/**
 * The position of the `reveal` page command's `text`, "line:column" or "line" (a Find result opened
 * in a tab that already shows its file), or null when it is malformed.
 */
export function revealPosition(text: string | undefined): RevealPosition | null {
  const match = typeof text === "string" ? /^(\d+)(?::(\d+))?$/.exec(text.trim()) : null;
  if (!match) return null;
  const line = Number(match[1]);
  const column = match[2] === undefined ? 1 : Number(match[2]);
  return line >= 1 && column >= 1 ? { line, column } : null;
}

/** The config's `reveal` (`{line, column}`), or null when absent or malformed. */
export function revealOf(value: unknown): RevealPosition | null {
  const position = value as Partial<RevealPosition> | null | undefined;
  const line = position?.line;
  const column = position?.column ?? 1;
  return typeof line === "number" &&
    Number.isInteger(line) &&
    line >= 1 &&
    typeof column === "number" &&
    Number.isInteger(column) &&
    column >= 1
    ? { line, column }
    : null;
}

export function isEditorCommand(value: unknown): value is EditorCommand {
  return typeof value === "string" && (value === "save" || value === "editorAction" || value in COMMAND_ACTIONS);
}
