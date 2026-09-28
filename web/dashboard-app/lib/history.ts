import { createBrowserHistory, type RouterHistory } from "@tanstack/react-router";

type HistoryWrite = typeof window.history.pushState;

/**
 * Browser history for the SPA inside the Next app router.
 *
 * Both routers patch `history.pushState`/`replaceState`. Next mirrors every
 * external write into its own state, then re-asserts the URL from a
 * `useInsertionEffect` with a state object marked `__NA`. TanStack's patch
 * would treat that echo as a navigation and schedule a React update inside
 * the insertion effect. Next's `__NA` writes never change the URL TanStack
 * already holds, so they skip TanStack's subscribers.
 */
export function createDashboardHistory(win: Window = window): RouterHistory {
  const history = createBrowserHistory({ window: win });
  const tanstackPush = win.history.pushState;
  const tanstackReplace = win.history.replaceState;
  const skipNextEcho = (write: HistoryWrite): HistoryWrite =>
    function (this: History, data, unused, url) {
      if (!isNextInternalState(data)) return write.call(win.history, data, unused, url);
      history._ignoreSubscribers = true;
      try {
        return write.call(win.history, data, unused, url);
      } finally {
        history._ignoreSubscribers = false;
      }
    };
  win.history.pushState = skipNextEcho(tanstackPush);
  win.history.replaceState = skipNextEcho(tanstackReplace);
  // `history.destroy()` restores the functions TanStack wrapped (Next's
  // patch), which also removes this wrapper.
  return history;
}

function isNextInternalState(data: unknown): boolean {
  return typeof data === "object" && data !== null && (data as { __NA?: unknown }).__NA === true;
}
