// The page's panes at a narrow width (the docked Home, about 600 px): below NARROW_PAGE of the
// page's own width it shows ONE pane, the list or the open conversation, never both squeezed side
// by side. The page URL's hash says which: `#/conversation/<id>[/...]` is the conversation (and
// what is open in it), anything else (`#/`, no hash) the list. A row opens its conversation by
// setting the hash; Back, Escape and Cmd-[ return to `#/` (backToList). Above the width both panes show as before.
import { useEffect, useState, useSyncExternalStore, type RefObject } from "react";

/** Below this page width (px, the page's own box, not the window) one pane shows at a time. */
export const NARROW_PAGE = 720;

export type Pane = "list" | "conversation";

const CONVERSATION = /^#\/conversation\/[A-Za-z0-9_]+(?:\/|$)/;
/** New Chief and Edit Chief draw a page where the conversation is (routes.ts). */
const CHIEF_PAGE = /^#\/(?:new\/chief|chief\/[A-Za-z0-9_-]+\/edit)\/?$/;

/** The pane a page hash names. */
export function paneOf(hash: string): Pane {
  return CONVERSATION.test(hash) || CHIEF_PAGE.test(hash) ? "conversation" : "list";
}

export const conversationHash = (id: string) => `#/conversation/${id}`;

/** The id of a conversation the hash names, if any. */
export function hashConversation(hash: string): string | undefined {
  return /^#\/conversation\/([A-Za-z0-9_]+)\/?$/.exec(hash)?.[1];
}

/** The history entry's mark: the entry before it is this page's list (`#/`), so Back may go
 * back in history instead of adding an entry. */
const FROM_LIST = "cmuxHomeFromList";

const isListHash = (hash: string) => hash === "" || hash === "#" || hash === "#/";

const url = (hash: string) => `${window.location.pathname}${window.location.search}${hash}`;

/** Sets the page hash. `replace` keeps one history entry (a keyboard move) and its mark; a new
 * entry is marked when it leaves the list. The page's hash listeners hear it either way. */
export function setHash(hash: string, replace = false): void {
  if (typeof window === "undefined" || window.location.hash === hash) return;
  if (replace) window.history.replaceState(window.history.state, "", url(hash));
  else window.history.pushState({ [FROM_LIST]: isListHash(window.location.hash) }, "", url(hash));
  window.dispatchEvent(new HashChangeEvent("hashchange"));
}

/** Back to the list: back in history when the entry before is the list (`#/`), else the current
 * entry becomes `#/` (a direct link never leaves the page). */
export function backToList(): void {
  if (typeof window === "undefined" || isListHash(window.location.hash)) return;
  const state: unknown = window.history.state;
  if (typeof state === "object" && state !== null && (state as Record<string, unknown>)[FROM_LIST] === true)
    window.history.back();
  else setHash("#/", true);
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

/** Whether the element is narrower than NARROW_PAGE (its own width, through a ResizeObserver);
 * undefined until the first measurement, so a first render is not taken for a pane change. */
export function useNarrow(element: RefObject<HTMLElement | null>): boolean | undefined {
  const [narrow, setNarrow] = useState<boolean | undefined>(undefined);
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
