// Test helpers for the composer's Milkdown prompt (MarkdownField): read and drive it as the
// textarea it replaced. Tests only.
import type { MarkdownFieldElement } from "./MarkdownField";

/// The prompt in `document`: its markdown, its caret in the first paragraph, its editable element.
export function promptField(document: Document) {
  const field = document.querySelector(".acpmux-md-field") as MarkdownFieldElement | null;
  if (!field?.acpmuxMarkdownField) throw new Error("the composer's prompt is not ready");
  const handle = field.acpmuxMarkdownField;
  const element = field.querySelector<HTMLElement>(".acpmux-md")!;
  return {
    get value() {
      return handle.value();
    },
    get selectionStart() {
      return handle.caret();
    },
    getAttribute: (name: string) => element.getAttribute(name),
    dispatchEvent: (event: Event) => element.dispatchEvent(event),
    element,
    handle,
  };
}

export type PromptField = ReturnType<typeof promptField>;

/// Types into the prompt: the whole prompt becomes `value`, caret at the end.
export function typeInto(prompt: PromptField, value: string) {
  prompt.handle.type(value);
}

/// The globals ProseMirror needs from a jsdom window.
export const proseMirrorGlobals = (window: Window & typeof globalThis) => ({
  Node: window.Node,
  getSelection: window.getSelection.bind(window),
  MutationObserver: window.MutationObserver,
});
