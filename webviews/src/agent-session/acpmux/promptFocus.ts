import { createContext, useCallback, useContext, useRef } from "react";

// After a model pick the keyboard is in the prompt (Lawrence 2026-10-22: "after selecting a model my
// keyboard should be focused in text area"). A composer hands its chips the way to focus its prompt
// (the chat's Markdown field or shell line, the New Tab's field); the model picker calls it once a
// pick closes it, where a menu would otherwise hand focus back to the model button.
export const PromptFocus = createContext<(() => void) | null>(null);

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
