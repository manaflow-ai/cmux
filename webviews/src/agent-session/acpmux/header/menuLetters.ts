// A menu row's letter (the chat title menu's R, F, A and D, #25661; the ··· menu has none, so its
// typeahead keeps every letter). Every
// letter key goes through `menuLetter`, the one place that decides whether it is a row's letter or
// text: a key typed into a text field, an editor or an IME composition is text, and so is every key
// of the menu's own typeahead once it has started (typing "tr" for Transcript view never renames).

/// How long a typeahead sequence lasts after its last key (Base UI's typeahead resets after ~500 ms).
export const TYPEAHEAD_MS = 600;

/// What the menu remembers of the keys typed into it: when the last one was.
export type MenuTyping = { last: number };

/// Whether `element` takes typed text: a text input, a textarea or a content-editable element.
export function takesText(element: Element | null | undefined): boolean {
  if (!element) return false;
  if (element.tagName === "TEXTAREA") return true;
  if (element.tagName === "INPUT")
    return /^(text|search|url|tel|email|password|number|)$/.test((element as HTMLInputElement).type ?? "");
  if ((element as HTMLElement).isContentEditable === true) return true;
  const editable = element.getAttribute("contenteditable");
  return editable === "" || editable === "true" || editable === "plaintext-only";
}

type LetterKey = {
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  target: EventTarget | null;
  nativeEvent?: { isComposing?: boolean };
  isComposing?: boolean;
};

/**
 * The upper-case row letter `event` types, or undefined when it is text. `typing` is updated for
 * every printable key, so a letter that continues a typeahead sequence stays the typeahead's.
 */
export function menuLetter(event: LetterKey, typing: MenuTyping, now = Date.now()): string | undefined {
  if (event.metaKey || event.ctrlKey || event.altKey || event.key.length !== 1) return undefined;
  const continues = now - typing.last < TYPEAHEAD_MS;
  typing.last = now;
  if (event.isComposing || event.nativeEvent?.isComposing) return undefined;
  const focused = (event.target as Element | null) ?? null;
  const active = focused?.ownerDocument?.activeElement ?? null;
  if (takesText(focused) || takesText(active)) return undefined;
  if (continues || !/^[a-z]$/i.test(event.key)) return undefined;
  return event.key.toUpperCase();
}
