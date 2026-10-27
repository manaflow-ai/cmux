// What a page keeps across a discard (plans/cmux-next/chrome-parity/p13-webui.md, task 082): its
// route, the scroll of its scrollers and its unsent inputs, saved when it hides and given back to
// the next document before its first paint.
//
// This is Chrome's PageState for cmux pages. Chrome keeps a tab's NavigationEntry PageState (URL,
// scroll offset, form control state) across a discard (content/public/common/page_state.h,
// third_party/blink/renderer/core/loader/history_item.h) and gives it back only to a load of the
// same entry: a new navigation starts fresh. Blink restores the scroll offset as soon as the layout
// is tall enough, and stops when the person scrolls first
// (third_party/blink/renderer/core/loader/document_loader.cc `RestoreScrollPositionAndViewState`,
// `initial_scroll_state_.was_scrolled_by_user`). Here the host keeps the text
// (pageLifecycle.ts `savePageStateOnHide`), and a page's store reads its inputs back from
// `restoredPageInputs` when it is made.
//
// ```ts
// const state = openPageState(client, "history"); // puts the saved route back
// const store = new HistoryStore(client);          // reads restoredPageInputs(client, "history")
// state.keep(() => store.pageInputs());            // saves on hide, puts the scroll back
// ```

import type { PageClient } from "./pageClient";
import { savePageStateOnHide, windowPageStateHost, type PageStateHost } from "./pageLifecycle";

/** The format of `SavedPageState`; a state of another version is not read back. */
export const PAGE_STATE_VERSION = 1;

/** The attribute that names a scroller whose scroll the page keeps: `data-page-scroll="list"`. */
export const PAGE_SCROLL_ATTRIBUTE = "data-page-scroll";

/** The scroll key of the document's own scroller. */
export const DOCUMENT_SCROLL_KEY = "document";

/**
 * How many layout changes a scroll restore waits through for its scroller to be tall enough. A
 * page's first screen commits in a few; a list that never grows that far keeps the nearest scroll.
 */
export const SCROLL_RESTORE_ATTEMPTS = 64;

/** The input events that mean the person moved the page first, so the restore leaves it alone. */
const USER_SCROLL_EVENTS = ["wheel", "touchstart", "pointerdown", "keydown"] as const;

/** What one page saves when it hides. */
export interface SavedPageState {
  v: typeof PAGE_STATE_VERSION;
  /** The page's name (its `data-cmux-page`): a state is read back only by the page that saved it. */
  page: string;
  /** The fragment the host showed the document with (`PageClient.entryRoute`). */
  entryRoute: string;
  /** The fragment when the page hid; the page may have moved on by itself. */
  route: string;
  /** Each kept scroller's offset by its `data-page-scroll` key; only offsets above 0. */
  scroll: Record<string, number>;
  /** The page's unsent inputs, in the form its store reads back. */
  inputs: unknown;
}

/** One scroller the state reads and sets. */
export interface PageScroller {
  scrollTop: number;
  readonly scrollHeight: number;
  readonly clientHeight: number;
}

/** The DOM the page state uses (the window's by default, a fake in tests). */
export interface PageStateDom {
  /** The fragment the document shows now. */
  route(): string;
  /** Shows `route` without a new history entry and without a `hashchange`. */
  replaceRoute(route: string): void;
  /** The kept scrollers by key, the document's under `DOCUMENT_SCROLL_KEY`. */
  scrollers(): Map<string, PageScroller>;
  /** Calls `changed` after each change of the page's content; returns the stop function. */
  observeLayout(changed: () => void): () => void;
  /** Calls `moved` on the person's first input that may scroll; returns the stop function. */
  observeUserScroll(moved: () => void): () => void;
  /** Where the state is written when the page hides. */
  readonly host: PageStateHost;
}

/** The window's DOM. */
export function windowPageStateDom(): PageStateDom {
  return {
    route: () => location.hash,
    replaceRoute: (route) => history.replaceState(history.state, "", route),
    scrollers: () => {
      const found = new Map<string, PageScroller>();
      if (document.scrollingElement) found.set(DOCUMENT_SCROLL_KEY, document.scrollingElement);
      for (const element of document.querySelectorAll<HTMLElement>(`[${PAGE_SCROLL_ATTRIBUTE}]`)) {
        const key = element.getAttribute(PAGE_SCROLL_ATTRIBUTE);
        if (key && !found.has(key)) found.set(key, element);
      }
      return found;
    },
    observeLayout: (changed) => {
      const observer = new MutationObserver(changed);
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      return () => observer.disconnect();
    },
    observeUserScroll: (moved) => {
      const listener = () => moved();
      for (const type of USER_SCROLL_EVENTS)
        document.addEventListener(type, listener, { capture: true, passive: true });
      return () => {
        for (const type of USER_SCROLL_EVENTS) document.removeEventListener(type, listener, { capture: true });
      };
    },
    host: windowPageStateHost(),
  };
}

/** The state `client`'s restore holds for `page`; null when there is none or it is another page's. */
export function savedPageState(client: PageClient | null, page: string): SavedPageState | null {
  const state = client?.restore?.state as Partial<SavedPageState> | null | undefined;
  if (!state || typeof state !== "object" || state.v !== PAGE_STATE_VERSION || state.page !== page) return null;
  return {
    v: PAGE_STATE_VERSION,
    page,
    entryRoute: typeof state.entryRoute === "string" ? state.entryRoute : "",
    route: typeof state.route === "string" ? state.route : "",
    scroll: scrollOffsets(state.scroll),
    inputs: state.inputs ?? null,
  };
}

/**
 * The inputs `page` saved before its document was discarded; undefined when none came back. A
 * store reads them once, when it is made, and checks every field itself.
 */
export function restoredPageInputs(client: PageClient | null, page: string): unknown {
  return savedPageState(client, page)?.inputs ?? undefined;
}

/** Only finite offsets above 0, by key. */
function scrollOffsets(value: unknown): Record<string, number> {
  const offsets: Record<string, number> = {};
  if (!value || typeof value !== "object") return offsets;
  for (const [key, offset] of Object.entries(value as Record<string, unknown>))
    if (typeof offset === "number" && Number.isFinite(offset) && offset > 0) offsets[key] = offset;
  return offsets;
}

/** One page's state: the saved route is back already; `keep` saves it on each hide. */
export interface PageStateSession {
  /** The saved state that came back with the document; null when it was not discarded. */
  readonly saved: SavedPageState | null;
  /**
   * Saves the route, the scrollers and `inputs()` each time the page hides, and puts the saved
   * scroll back as the page's content lays out. Returns the stop function.
   */
  keep(inputs: () => unknown): () => void;
}

/**
 * Opens `page`'s state, before the page's store is made. The restored document is the same entry
 * when the host loads it at the route the old one was shown with, or at the route it hid at (the
 * host moved it there itself, `PageWebView.open(route:)`): the route the page had moved on to
 * comes back now, so the store reads it, and so does the scroll. A host that sent the page
 * somewhere else meanwhile wins, and the old scroll is not put back on the new route.
 */
export function openPageState(
  client: PageClient | null,
  page: string,
  dom: PageStateDom = windowPageStateDom(),
): PageStateSession {
  const saved = savedPageState(client, page);
  // The document's own entry, for a client that does not track its claim (a mock).
  const loadedRoute = dom.route();
  const sameEntry = saved !== null && (saved.entryRoute === loadedRoute || saved.route === loadedRoute);
  if (sameEntry && saved.route !== loadedRoute) dom.replaceRoute(saved.route);
  return {
    saved,
    keep(inputs) {
      // A hide does not end the restore: content that lays out while hidden still takes its
      // offset, and an offset not reached yet is saved as it came, not as the short list's top.
      const restore = sameEntry ? restoreScroll(saved.scroll, dom) : null;
      const stopSave = savePageStateOnHide(() => {
        const state: SavedPageState = {
          v: PAGE_STATE_VERSION,
          page,
          entryRoute: client?.entryRoute ?? loadedRoute,
          route: dom.route(),
          scroll: { ...currentScroll(dom), ...restore?.pending() },
          inputs: inputs() ?? null,
        };
        return state;
      }, dom.host);
      return () => {
        restore?.stop();
        stopSave();
      };
    },
  };
}

/** Every kept scroller's offset above 0. */
function currentScroll(dom: PageStateDom): Record<string, number> {
  const offsets: Record<string, number> = {};
  for (const [key, scroller] of dom.scrollers()) if (scroller.scrollTop > 0) offsets[key] = scroller.scrollTop;
  return offsets;
}

/** A scroll restore in progress (`restoreScroll`). */
export interface ScrollRestore {
  /** Ends the restore; the offsets not reached are dropped. */
  stop(): void;
  /**
   * The saved offsets not reached yet, by key: what a save during the restore keeps, as Blink keeps
   * the history item's offset until its restore completes. Empty once the restore has ended.
   */
  pending(): Record<string, number>;
}

/**
 * Puts `offsets` back as the content lays out: a scroller takes its offset once it is tall enough
 * for it, in the layout change that made it so, before that frame paints. The restore ends when
 * every offset is back, when the person scrolls first, or after `SCROLL_RESTORE_ATTEMPTS` changes,
 * leaving each short scroller at its nearest offset.
 */
export function restoreScroll(offsets: Record<string, number>, dom: PageStateDom): ScrollRestore {
  const pending = new Map(Object.entries(offsets));
  let attempts = 0;
  let stopped = false;
  let stopLayout: () => void = () => undefined;
  let stopUser: () => void = () => undefined;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    pending.clear();
    stopLayout();
    stopUser();
  };
  const restore: ScrollRestore = { stop, pending: () => Object.fromEntries(pending) };
  if (pending.size === 0) return restore;
  const attempt = () => {
    if (stopped) return;
    attempts += 1;
    const scrollers = dom.scrollers();
    for (const [key, offset] of pending) {
      const scroller = scrollers.get(key);
      if (!scroller) continue;
      const reachable = Math.min(offset, Math.max(0, scroller.scrollHeight - scroller.clientHeight));
      if (scroller.scrollTop !== reachable) scroller.scrollTop = reachable;
      if (reachable === offset) pending.delete(key);
    }
    if (pending.size === 0 || attempts >= SCROLL_RESTORE_ATTEMPTS) stop();
  };
  stopUser = dom.observeUserScroll(stop);
  stopLayout = dom.observeLayout(attempt);
  attempt();
  return restore;
}
