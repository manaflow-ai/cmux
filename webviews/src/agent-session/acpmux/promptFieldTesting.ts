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

/// The globals ProseMirror needs from a jsdom window. jsdom lays nothing out and its Range has no
/// rects, but ProseMirror measures one whenever a transaction scrolls the caret into view (a picked
/// slash command, a paste): give the window's Range empty rects so that scroll is a no-op.
export const proseMirrorGlobals = (window: Window & typeof globalThis) => {
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  const range = (window.Range?.prototype ?? {}) as unknown as Record<string, unknown>;
  if (typeof range.getClientRects !== "function")
    Object.assign(range, { getClientRects: () => Object.assign([box()], { item: () => box() }) });
  if (typeof range.getBoundingClientRect !== "function") Object.assign(range, { getBoundingClientRect: box });
  return {
    Node: window.Node,
    getSelection: window.getSelection.bind(window),
    MutationObserver: window.MutationObserver,
  };
};
