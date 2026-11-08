// Escape closes a subagent's view to the chat's, as the "Subagent of" pill's × does
// (SubagentGroup.tsx SubagentOfRow). Leo, 2026-11-03: "this opened subagent has no close button".
import { useEffect, useRef } from "react";
import { escapeSurfaceOpen } from "../paneSurface";

const EDITABLE = "input, textarea, select, [contenteditable]:not([contenteditable=false])";
const SESSION_INFO_OWNS = "aside.acpmux-session-info, button.acpmux-session-info-toggle";

/// Whether an Escape keydown may close the subagent's view. Not one with a modifier or inside an IME
/// composition, not one a control already took, not one typed in a text field (the composer's first
/// Escape lets go of the caret, composerFocus.ts), and not while a menu, popover or dialog that owns
/// Escape is open.
export function escapeClosesSubagent(event: KeyboardEvent, document: Document): boolean {
  if (event.key !== "Escape" || event.defaultPrevented) return false;
  if (event.isComposing || event.keyCode === 229) return false;
  if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return false;
  const target = event.target;
  const element = target && (target as Node).nodeType === 1 ? (target as Element) : undefined;
  if (element?.closest(EDITABLE)) return false;
  // Session Info owns Escape while the keyboard is in it or on its toggle (SessionInfo.tsx), whichever
  // listener was added first.
  const focus = document.activeElement;
  if (focus?.closest(SESSION_INFO_OWNS)) return false;
  return !escapeSurfaceOpen(document);
}

/// While a subagent's view is shown (`enabled`), an Escape nothing else took calls `onClose`. The
/// decision waits a microtask, past the listeners that run before it, and claims the key: with a turn
/// running, the composer's page-level double press (escapeStop.ts, which waits a task) then leaves it
/// alone, so the press closes the view and stops nothing.
export function useEscapeClosesSubagent(enabled: boolean, onClose: () => void) {
  const latest = useRef(onClose);
  latest.current = onClose;
  useEffect(() => {
    if (!enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (!escapeClosesSubagent(event, document)) return;
      queueMicrotask(() => {
        if (event.defaultPrevented) return;
        event.preventDefault();
        latest.current();
      });
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [enabled]);
}
