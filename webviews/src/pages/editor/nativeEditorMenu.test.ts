// The editor's right-click menu in the app is the native one, with the rows Monaco's own menu shows
// here: Change All Occurrences, Cut, Copy, Paste and the Command Palette, Monaco's labels, groups
// split by separators, an unsupported action left out.
import { expect, test } from "bun:test";
import { editorMenuRows } from "./nativeEditorMenu";

const labels: Record<string, string> = {
  "editor.action.changeAll": "Change All Occurrences",
  "editor.action.clipboardCutAction": "Cut",
  "editor.action.clipboardCopyAction": "Copy",
  "editor.action.clipboardPasteAction": "Paste",
  "editor.action.quickCommand": "Command Palette",
};

function editor(unsupported: string[] = []) {
  return {
    getAction: (id: string) =>
      labels[id]
        ? { id, label: labels[id]!, isSupported: () => !unsupported.includes(id), run: async () => undefined }
        : null,
  } as never;
}

test("the editor menu lists Monaco's own rows, grouped", () => {
  expect(editorMenuRows(editor()).map((row) => (row.separator ? "-" : row.label))).toEqual([
    "Change All Occurrences",
    "-",
    "Cut",
    "Copy",
    "Paste",
    "-",
    "Command Palette",
  ]);
  expect(editorMenuRows(editor())[0]).toEqual({
    id: "editor.action.changeAll",
    label: "Change All Occurrences",
    symbol: "pencil",
  });
});

test("an unsupported action and its empty group are left out", () => {
  expect(editorMenuRows(editor(["editor.action.changeAll"])).map((row) => row.label)).toEqual([
    "Cut",
    "Copy",
    "Paste",
    "",
    "Command Palette",
  ]);
});
