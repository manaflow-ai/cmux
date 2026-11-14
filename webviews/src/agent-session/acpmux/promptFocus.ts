import { createContext, createElement, useCallback, useContext, useLayoutEffect, useRef, type ReactNode } from "react";

// After a model pick the keyboard is in the prompt (Lawrence 2026-10-22: "after selecting a model my
// keyboard should be focused in text area"). A composer hands its chips the way to focus its prompt
// (the chat's Markdown field or shell line, the New Tab's field); the model picker calls it once a
// pick closes it, where a menu would otherwise hand focus back to the model button.
export const PromptFocus = createContext<(() => void) | null>(null);

/// Hands the chips under it `focus`, as one function for the provider's whole life: the composer
/// builds `focus` again on each of its renders, every keystroke among them, and a new context value
/// drew each chip that reads it (the model picker and its menus) again on every key (CMUX-571).
/// The function calls the latest `focus` passed.
export function PromptFocusProvider({ focus, children }: { focus: () => void; children?: ReactNode }) {
  const latest = useRef(focus);
  useLayoutEffect(() => {
    latest.current = focus;
  });
  const stable = useCallback(() => latest.current(), []);
  return createElement(PromptFocus, { value: stable }, children);
}

/// Focuses the prompt of the composer around the caller, as its latest render handed it; returns
/// false when there is none (the picker on its own in the gallery), so the caller keeps its own focus.
export function usePromptFocus(): () => boolean {
  const focus = useContext(PromptFocus);
  const latest = useRef(focus);
  latest.current = focus;
  return useCallback(() => {
    if (!latest.current) return false;
    latest.current();
    return true;
  }, []);
}
