// The page side of the hide-time save (plans/cmux-next/chrome-parity/p13-webui.md 3.C, task 088): a
// page saves its state when it hides, on `visibilitychange`, never when the host discards it. A hidden
// page may be frozen by then and cannot answer, so the host's discard asks the page for nothing. This is
// Chrome's Page Lifecycle rule: `visibilitychange` to hidden is the last event a page is sure to get
// before it is frozen or discarded (https://developer.chrome.com/docs/web-platform/page-lifecycle-api).
//
// The state goes to two places: sessionStorage, which an in-place Chromium discard keeps
// (`WebContents::Discard` keeps session storage), and the host (`PAGE_STATE_HANDLER`), which keeps it
// for a page whose engine page is closed (WebKit, or Chromium on an older fork). The host gives it back
// through sessionStorage before the page's scripts run, so `readPageState` is the one way back.

/** The `window.webkit.messageHandlers` name the host takes the state on (PageWebView.pageStateHandler). */
export const PAGE_STATE_HANDLER = "cmuxPageState";
/** The sessionStorage key of the saved state. */
export const PAGE_STATE_KEY = "cmux.page.state";
/** The most a page may save, in bytes of UTF-8 (PageHideState.maxStateBytes). */
export const PAGE_STATE_MAX_BYTES = 64 * 1024;

/** Returns the page's state, as JSON can hold it. Called once per hide; keep it fast. */
export type PageStateSaver = () => unknown;

/** Where the save reads visibility and writes the state (the window by default, a fake in tests). */
export interface PageStateHost {
  readonly document: Pick<Document, "visibilityState" | "addEventListener" | "removeEventListener">;
  readonly storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null;
  /** Posts the JSON to the host; null when the page has no host (a browser preview). */
  readonly post: ((json: string) => void) | null;
}

interface MessageHandlers {
  [name: string]: { postMessage(body: unknown): unknown } | undefined;
}

/** The window's host: its document, its sessionStorage and the host's state handler. */
export function windowPageStateHost(): PageStateHost {
  const handlers = (globalThis as { webkit?: { messageHandlers?: MessageHandlers } }).webkit?.messageHandlers;
  const handler = handlers?.[PAGE_STATE_HANDLER];
  let storage: Storage | null = null;
  try {
    storage = globalThis.sessionStorage ?? null;
  } catch {
    storage = null; // storage refused (a sandboxed document)
  }
  return {
    document,
    storage,
    post: handler ? (json) => void handler.postMessage(json) : null,
  };
}

/**
 * Saves `save()`'s state each time the page hides. One per document; returns the function that
 * stops it.
 *
 * ```ts
 * savePageStateOnHide(() => ({ scroll: list.scrollTop, query }));
 * const restored = readPageState<{ scroll: number; query: string }>();
 * ```
 */
export function savePageStateOnHide(save: PageStateSaver, host: PageStateHost = windowPageStateHost()): () => void {
  const onVisibility = () => {
    if (host.document.visibilityState === "hidden") writePageState(save(), host);
  };
  host.document.addEventListener("visibilitychange", onVisibility);
  return () => host.document.removeEventListener("visibilitychange", onVisibility);
}

/**
 * Writes `state` where a discard keeps it. A state over `PAGE_STATE_MAX_BYTES` is not kept: the
 * older one is cleared too, so the page never comes back to a state older than the one it had.
 *
 * @returns Whether the state was kept.
 */
export function writePageState(state: unknown, host: PageStateHost): boolean {
  const json = JSON.stringify(state ?? null);
  const fits = new TextEncoder().encode(json).length <= PAGE_STATE_MAX_BYTES;
  try {
    if (fits) host.storage?.setItem(PAGE_STATE_KEY, json);
    else host.storage?.removeItem(PAGE_STATE_KEY);
  } catch {
    // Over the storage quota: the host's copy still holds it.
  }
  host.post?.(fits ? json : "null");
  return fits;
}

/** The state the page saved before it was discarded or reloaded; undefined when there is none. */
export function readPageState<T>(host: PageStateHost = windowPageStateHost()): T | undefined {
  let json: string | null = null;
  try {
    json = host.storage?.getItem(PAGE_STATE_KEY) ?? null;
  } catch {
    return undefined;
  }
  if (json === null) return undefined;
  try {
    const value = JSON.parse(json) as T | null;
    return value === null ? undefined : value;
  } catch {
    return undefined;
  }
}
