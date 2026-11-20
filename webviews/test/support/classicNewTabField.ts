// The classic New Tab page's field (NewTabPage.tsx) is the chat composer's prompt editor
// (MarkdownField), as on the New Tab screen: tests drive it as the screen's tests drive `.nt-field`.
import { act } from "react";
import type { MarkdownFieldElement } from "../../src/agent-session/acpmux/MarkdownField";

/// The classic page's field in `root`, once its editor is up: its handle, its editable element, and
/// typing that replaces the whole prompt, caret at the end.
export async function classicField(root: ParentNode) {
  const field = root.querySelector<MarkdownFieldElement>(".acpmux-newtab-field");
  if (!field) throw new Error("the classic New Tab page has no field");
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField;
  const editor = field.querySelector<HTMLElement>("[contenteditable]");
  if (!handle || !editor) throw new Error("the classic New Tab field's editor never came up");
  return {
    field,
    handle,
    editor,
    /// What the field holds, as typed.
    value: () => handle.plainText().replace(/\n$/, ""),
    async type(text: string) {
      await act(async () => {
        handle.writeText(text, text.length, text.length);
        editor.focus();
        handle.setCaret(text.length);
      });
    },
  };
}
