// Key presses of the `app.keyStyle` tests (ui/keyStyle.ts), as a US keyboard's DOM reports them:
// Vim's j, k, g, G (Shift-G), l, h, / and Esc, and Emacs' Ctrl-N, Ctrl-P, Ctrl-A, Ctrl-E and Ctrl-G.
export type StyleKey = "j" | "k" | "g" | "G" | "l" | "h" | "/" | "Escape" | "C-n" | "C-p" | "C-a" | "C-e" | "C-g";

export function styleKeyInit(key: StyleKey): KeyboardEventInit {
  if (key === "Escape") return { key: "Escape", code: "Escape" };
  if (key === "/") return { key: "/", code: "Slash" };
  if (key === "G") return { key: "G", code: "KeyG", shiftKey: true };
  if (key.startsWith("C-")) {
    const letter = key.slice(2);
    return { key: letter, code: `Key${letter.toUpperCase()}`, ctrlKey: true };
  }
  return { key, code: `Key${key.toUpperCase()}` };
}

/// Presses `keys` on `target` in order (keydown, bubbling, cancelable); the last event back.
export function pressStyleKeys(
  view: { KeyboardEvent: typeof KeyboardEvent },
  target: Element,
  keys: readonly StyleKey[],
  run: (dispatch: () => void) => void = (dispatch) => dispatch(),
): KeyboardEvent | undefined {
  let last: KeyboardEvent | undefined;
  for (const key of keys) {
    const event = new view.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...styleKeyInit(key) });
    run(() => void target.dispatchEvent(event));
    last = event;
  }
  return last;
}
