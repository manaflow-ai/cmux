// The page's panes at a narrow width (the docked Home, about 600 px): below NARROW_PAGE of the
// page's own width it shows ONE pane, the list or the open conversation, never both squeezed side
// by side. The page URL's hash says which: `#/conversation/<id>[/...]` is the conversation (and
// what is open in it), anything else (`#/`, no hash) the list. A row opens its conversation by
// setting the hash; Back, Escape and Cmd-[ set `#/`. Above the width both panes show as before.
import { useEffect, useState, useSyncExternalStore, type RefObject } from "react";

/** Below this page width (px, the page's own box, not the window) one pane shows at a time. */
export const NARROW_PAGE = 720;

export type Pane = "list" | "conversation";

const CONVERSATION = /^#\/conversation\/[A-Za-z0-9_]+(?:\/|$)/;

/** The pane a page hash names. */
export function paneOf(hash: string): Pane {
  return CONVERSATION.test(hash) ? "conversation" : "list";
}

export const conversationHash = (id: string) => `#/conversation/${id}`;

/** The id of a conversation the hash names, if any. */
export function hashConversation(hash: string): string | undefined {
  return /^#\/conversation\/([A-Za-z0-9_]+)\/?$/.exec(hash)?.[1];
}

/** Sets the page hash. `replace` keeps one history entry (a keyboard move); the page's hash
 * listeners hear it either way. */
export function setHash(hash: string, replace = false): void {
  if (typeof window === "undefined" || window.location.hash === hash) return;
  if (!replace) {
    window.location.hash = hash;
    return;
  }
  window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}${hash}`);
  window.dispatchEvent(new HashChangeEvent("hashchange"));
}

const subscribe = (listener: () => void) => {
  window.addEventListener("hashchange", listener);
  window.addEventListener("popstate", listener);
  return () => {
    window.removeEventListener("hashchange", listener);
    window.removeEventListener("popstate", listener);
  };
};

/** The pane the page URL's hash names, kept current. */
export function useHashPane(): Pane {
  return useSyncExternalStore<Pane>(
    subscribe,
    () => paneOf(window.location.hash),
    () => "list",
  );
}

/** Whether the element is narrower than NARROW_PAGE (its own width, through a ResizeObserver). */
export function useNarrow(element: RefObject<HTMLElement | null>): boolean {
  const [narrow, setNarrow] = useState(false);
  useEffect(() => {
    const node = element.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setNarrow(entry.contentRect.width < NARROW_PAGE);
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [element]);
  return narrow;
}
