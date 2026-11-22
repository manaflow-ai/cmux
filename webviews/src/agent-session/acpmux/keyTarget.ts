/// Single-key actions inside a focused panel (a permission ask, a picker) run only on keys that
/// are not typing: no modifier, no input method composing, and not in a text field. The prompt
/// is editable content (Milkdown), so it never loses a letter to a panel.

const TEXT_ENTRY = 'input, textarea, select, [contenteditable]:not([contenteditable="false"])';

/// Whether `target` is, or sits inside, somewhere typing goes.
export function isTextEntry(target: EventTarget | null): boolean {
  const element = target as Element | null;
  return typeof element?.closest === "function" && element.closest(TEXT_ENTRY) !== null;
}

type KeyEventLike = Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "target"> & {
  isComposing?: boolean;
  nativeEvent?: { isComposing?: boolean };
};

/// The bare key `event` presses ("y", "3"), or undefined when it is typing or carries a modifier.
export function bareKey(event: KeyEventLike): string | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return undefined;
  if (event.isComposing || event.nativeEvent?.isComposing) return undefined;
  if (event.key.length !== 1 || isTextEntry(event.target)) return undefined;
  return event.key.toLowerCase();
}
