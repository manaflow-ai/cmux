// A paste anywhere in the agent pane goes into the composer (Leo 2026-10-21: "pastes need to be able
// to paste even when the composer isn't literally focused", "ME PASTING IT DOESNT JUST PASTE RIGHT IN
// THE COMPOSER IMMEDIATELY"). With the keyboard on the transcript, a message, a button or nothing at
// all, Cmd-V focuses the prompt with its caret at the end, so the paste lands there and takes the
// prompt's own path: an image is a chip (composer/attachmentIntake.tsx), text goes in as typed. A
// paste the page still gets outside any field (Edit > Paste from the menu bar, an engine that pastes
// before the focus moves) is put into the prompt the same way. A text field or an editor elsewhere in
// the pane (a prompt being edited, a search, a question's answer) keeps its own paste, and so does
// a modal dialog.
import { useEffect, useRef } from "react";

/// Elements that take a paste themselves.
const EDITABLE =
  'textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]';
/// Inputs that hold no text: a paste on one is the pane's.
const TEXTLESS_INPUTS = new Set([
  "button",
  "checkbox",
  "color",
  "file",
  "hidden",
  "image",
  "radio",
  "range",
  "reset",
  "submit",
]);
/// A modal dialog keeps the keyboard: nothing in it hands a paste to the composer behind it.
const MODAL = 'dialog[open], [role="dialog"][aria-modal="true"], [role="alertdialog"]';

function elementOf(target: EventTarget | null): Element | null {
  if (!target || typeof (target as Node).nodeType !== "number") return null;
  const node = target as Node;
  return node.nodeType === 1 ? (node as Element) : node.parentElement;
}

/// Whether a paste with `target` focused belongs there rather than to the composer: a text field, an
/// editor, or anything in a modal dialog.
export function ownsPaste(target: EventTarget | null): boolean {
  const element = elementOf(target);
  if (!element) return false;
  if (element.closest(EDITABLE) || element.closest(MODAL)) return true;
  const input = element.closest("input");
  return input !== null && !TEXTLESS_INPUTS.has(input.type);
}

/// Cmd-V, and its Shift and Option forms (Paste and Match Style, Paste as Plain Text).
export function isPasteKey(
  event: Pick<KeyboardEvent, "key" | "code" | "metaKey" | "ctrlKey" | "isComposing">,
): boolean {
  if (!event.metaKey || event.ctrlKey || event.isComposing) return false;
  return event.code === "KeyV" || event.key.toLowerCase() === "v";
}

/// Focuses the prompt (or the shell field) with its caret at the end; false when none shows.
export type TakePaste = () => boolean;

/// Hands `data` to the focused field `target` as its own paste, so the paste takes the field's whole
/// path (an image a chip, a huge text a Pasted chip, text at the caret); a plain text field whose
/// paste nothing took gets the clipboard's text.
function pasteInto(target: Element, data: DataTransfer) {
  const view = target.ownerDocument.defaultView;
  if (!view) return;
  const event = new view.ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data });
  // An engine whose constructor drops the clipboard (or no ClipboardEvent init support) still hands it on.
  if (event.clipboardData !== data) Object.defineProperty(event, "clipboardData", { value: data });
  target.dispatchEvent(event);
  if (event.defaultPrevented) return;
  if (!(target instanceof view.HTMLTextAreaElement || target instanceof view.HTMLInputElement)) return;
  const text = data.getData("text/plain");
  if (!text || target.ownerDocument.execCommand?.("insertText", false, text)) return;
  const end = target.value.length;
  target.setRangeText(text, target.selectionStart ?? end, target.selectionEnd ?? end, "end");
  target.dispatchEvent(new view.Event("input", { bubbles: true }));
}

/// Installs the pane's paste route on `doc`: Cmd-V outside a field moves the keyboard into the
/// prompt first (`take`), and a paste event that still lands outside one is handed to the prompt.
export function installPasteAnywhere(take: () => TakePaste | undefined, doc: Document = document): () => void {
  const key = (event: KeyboardEvent) => {
    if (event.defaultPrevented || !isPasteKey(event) || ownsPaste(event.target)) return;
    // Not prevented: the key goes on to the app's Paste, which now pastes into the focused prompt.
    take()?.();
  };
  // WebKit enables Paste outside editable content only when `beforepaste` is cancelled
  // (Editor::canDHTMLPaste); then the paste event fires here and goes to the prompt.
  const before = (event: Event) => {
    if (!ownsPaste(event.target) && take()) event.preventDefault();
  };
  const paste = (event: ClipboardEvent) => {
    const data = event.clipboardData;
    if (event.defaultPrevented || !data || ownsPaste(event.target)) return;
    if (!take()?.()) return;
    const field = doc.activeElement;
    if (!field || !ownsPaste(field)) return;
    event.preventDefault();
    pasteInto(field, data);
  };
  doc.addEventListener("keydown", key);
  doc.addEventListener("beforepaste", before);
  doc.addEventListener("paste", paste);
  return () => {
    doc.removeEventListener("keydown", key);
    doc.removeEventListener("beforepaste", before);
    doc.removeEventListener("paste", paste);
  };
}

/// `installPasteAnywhere` for a component's lifetime, with the newest `take`.
export function usePasteAnywhere(take: TakePaste | undefined) {
  const latest = useRef(take);
  latest.current = take;
  useEffect(() => installPasteAnywhere(() => latest.current), []);
}
