// A list's `app.keyStyle` keys (keyStyle.ts): attach the returned handler as `onKeyDown` to the
// list or listbox container, and to a search field that drives the list. The style and layout
// come from the host's settings (configureKeyStyle, fed by the `display` event in chatDisplay.ts)
// unless the surface passes its own (the Settings page passes its rows' values).
import { useCallback, useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import {
  createListKeys,
  isEditableTarget,
  keyEventFromDom,
  keyStyleSnapshot,
  subscribeKeyStyle,
  type KeyStyle,
  type KeyStyleSettings,
  type ListCommand,
  type ShortcutLayout,
} from "./keyStyle";

/// How long the first key of a sequence (vim's g of gg) waits for its second.
export const LIST_KEYS_PENDING_MS = 1000;

/// Keys pressed on their own (the Shift of G): they leave a pending first key as it is.
export const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn", "AltGraph"]);

export type UseListKeysOptions = {
  /// Runs a command; `false` when this surface has nothing for it, so the key goes on unchanged
  /// (Vim's Esc in a list with no Esc of its own still reaches the popup that closes on it).
  /// `pressed` is the event as the handler got it (React's, for asPlainKey).
  onCommand: (
    command: ListCommand,
    event: KeyboardEvent,
    pressed: ReactKeyboardEvent | KeyboardEvent,
  ) => boolean | void;
  style?: KeyStyle;
  layout?: ShortcutLayout;
};

/// The page's current `app.keyStyle` and `app.shortcutLayout`.
export function useKeyStyleSettings(): KeyStyleSettings {
  return useSyncExternalStore(subscribeKeyStyle, keyStyleSnapshot, keyStyleSnapshot);
}

export function useListKeys({
  onCommand,
  style,
  layout,
}: UseListKeysOptions): (event: ReactKeyboardEvent | KeyboardEvent) => void {
  const settings = useKeyStyleSettings();
  const keyStyle = style ?? settings.keyStyle;
  const shortcutLayout = layout ?? settings.shortcutLayout;
  const keys = useMemo(() => createListKeys(keyStyle, shortcutLayout), [keyStyle, shortcutLayout]);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(
    () => () => {
      clearTimeout(timer.current);
      keys.reset();
    },
    [keys],
  );
  return useCallback(
    (event: ReactKeyboardEvent | KeyboardEvent) => {
      const native: KeyboardEvent = "nativeEvent" in event ? event.nativeEvent : event;
      // A key a control already took, an input method's, or a modifier pressed on its own
      // (the Shift of G) leaves a pending g as it is.
      if (native.defaultPrevented || native.isComposing || MODIFIER_KEYS.has(native.key)) return;
      const outcome = keys.feed(keyEventFromDom(native), isEditableTarget(native.target));
      clearTimeout(timer.current);
      timer.current = undefined;
      if (outcome === "pass") return;
      if (outcome === "pending") {
        event.preventDefault();
        event.stopPropagation();
        timer.current = setTimeout(() => keys.reset(), LIST_KEYS_PENDING_MS);
        return;
      }
      if (onCommand(outcome, native, event) === false) return;
      event.preventDefault();
      event.stopPropagation();
    },
    [keys, onCommand],
  );
}

/// For a surface whose own key handler already does a command for a plain key (ArrowDown for
/// list.next, Return for list.open): `event` as if that key had been pressed alone, to hand to
/// that handler. Its preventDefault and stopPropagation still reach the real event.
export function asPlainKey<E extends ReactKeyboardEvent>(event: E, key: string): E {
  const plain = { value: false };
  return Object.create(event, {
    key: { value: key },
    code: { value: key },
    metaKey: plain,
    ctrlKey: plain,
    altKey: plain,
    shiftKey: plain,
    repeat: plain,
  }) as E;
}
