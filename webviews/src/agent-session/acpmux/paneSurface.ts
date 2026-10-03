import { useEffect, useRef } from "react";

/// Where the page is shown. The host's `ready` reply says `"surface": "quick"` for the Quick
/// Composer panel; any other value, or none, is the agent pane in a tab.
export type PaneSurface = "pane" | "quick";

/// The surface a `ready` reply asks for.
export function readSurface(value: unknown): PaneSurface {
  return value === "quick" ? "quick" : "pane";
}

/// The bridge messages the Quick Composer posts to the host.
export const QUICK_MESSAGES = {
  /// Escape with nothing open to close: hide the panel, keeping the draft.
  dismiss: "quick.dismiss",
  /// ⌘Return: show this chat in a window.
  openInWindow: "quick.openInWindow",
} as const;

/// Calls `onDismiss` for an Escape no open menu, picker or palette took. Those handle Escape on
/// their own element and stop it there (preventDefault or stopPropagation), so only an Escape
/// that nothing claimed reaches the document. Off while `enabled` is false.
export function useEscapeToDismiss(enabled: boolean, onDismiss: () => void) {
  const latest = useRef(onDismiss);
  latest.current = onDismiss;
  useEffect(() => {
    if (!enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      // During IME composition Escape cancels the composition, and closes nothing.
      if (event.isComposing || event.keyCode === 229) return;
      if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
      event.preventDefault();
      latest.current();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [enabled]);
}
