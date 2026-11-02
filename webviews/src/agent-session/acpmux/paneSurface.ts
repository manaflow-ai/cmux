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
  /// Return (Start Agent): the chat has started; put it in the sidebar and hide the panel.
  startInBackground: "quick.startInBackground",
  /// The floating chat's keep-on-top (cx-b9qi): `{onTop}`.
  setOnTop: "quick.setOnTop",
  /// The floating chat's compact bar: `{collapsed}`.
  setCollapsed: "quick.setCollapsed",
  /// Include focused tab: what the user is looking at in cmux, `{name, text}` or null.
  context: "quick.context",
} as const;

/// Calls `onDismiss` for an Escape no open menu, picker, palette or panel took. Those handle Escape
/// on their own element and stop it there (preventDefault or stopPropagation), so only an Escape
/// that nothing claimed reaches the document. The decision is deferred until the event has bubbled
/// through the page: a panel may own Escape from a window listener. Off while `enabled` is false.
type EscapeDismissOptions = {
  /**
   * A surface such as the status card can sit above the composer. Capture its Escape before the
   * composer consumes it, but let an already-open menu or popover answer first.
   */
  capture?: boolean;
};

function escapeSurfaceOpen(document: Document): boolean {
  return [
    ...document.querySelectorAll<HTMLElement>(
      '[role="menu"], [role="listbox"], [role="dialog"], .ui-popup, [aria-haspopup][data-popup-open], ' +
        '.acpmux-summary-card[data-placement="popover"], .acpmux-minimap__card:focus-within',
    ),
  ].some((element) => {
    // Summary is a popover only in its narrow placement; the minimap claims Escape only while
    // its preview has focus. Their inline or hover-only forms must not block status dismissal.
    // Base UI keeps closing surfaces mounted for their fade after their Escape owner has stopped.
    // They must not defer the next press to the composer or Quick Composer behind the card.
    if (element.closest('[hidden], [inert], [aria-hidden="true"], [data-closed], [data-ending-style]')) return false;
    for (let current: HTMLElement | null = element; current; current = current.parentElement) {
      const style = document.defaultView?.getComputedStyle(current);
      if (style?.display === "none" || style?.visibility === "hidden") return false;
    }
    return true;
  });
}

export function useEscapeToDismiss(enabled: boolean, onDismiss: () => void, options: EscapeDismissOptions = {}) {
  const latest = useRef(onDismiss);
  latest.current = onDismiss;
  useEffect(() => {
    if (!enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      // During IME composition Escape cancels the composition, and closes nothing.
      if (event.isComposing || event.keyCode === 229) return;
      if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
      if (options.capture) {
        // Menus and popovers own Escape. Their portalled surface or open trigger is present by
        // the time this event is dispatched, so the card waits for them instead of stealing it.
        if (escapeSurfaceOpen(document)) return;
        event.preventDefault();
        event.stopPropagation();
        latest.current();
        return;
      }
      queueMicrotask(() => {
        if (event.defaultPrevented) return;
        event.preventDefault();
        latest.current();
      });
    };
    document.addEventListener("keydown", onKey, options.capture);
    return () => document.removeEventListener("keydown", onKey, options.capture);
  }, [enabled, options.capture]);
}
