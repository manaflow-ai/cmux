// A page on the shared page host shows a small transient surface with no room in the page past the
// window's edge (cx-6k6cg): `cmux.app.popup.show/update/hide` and the `cmux.page.popup` stream
// (PageRouter). Settings passes no host: its pop-ups fit and scroll in the window.
import { createPopupHost, type PopupEvent, type PopupHost } from "../../ui/popupHost";
import { findReplyHandler, type PageClient } from "./pageClient";

export function pagePopupHost(client: PageClient): PopupHost {
  const listeners = new Set<(event: PopupEvent) => void>();
  // One subscription for the page, open before any surface escapes, so no early pick is lost.
  void client
    .subscribe<PopupEvent>("cmux.page.popup", (event) => listeners.forEach((listener) => listener(event)))
    .catch(() => undefined);
  return createPopupHost(
    (call, params) => client.call(`cmux.app.popup.${call}`, params),
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  );
}

/** The page's popup host in the app; null for a mock client (the dev loop, the gallery) or none. */
export function appPopupHost(client: PageClient | null): PopupHost | null {
  return client && findReplyHandler() ? pagePopupHost(client) : null;
}
