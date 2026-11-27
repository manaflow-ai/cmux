import { createContext, useCallback, useContext } from "react";
import { frameNotification } from "./frameNotifications";

/** A retained, offscreen subtree keeps its DOM and state but needs no live UI subscriptions.
 * Consumers read their current source again when the row is revealed. */
export const LiveUpdatesContext = createContext(true);
export const useLiveUpdates = () => useContext(LiveUpdatesContext);

/** Keep source updates synchronous, but deliver visible consumers together on the next frame. */
export function useLiveSubscription(subscribe: (notify: () => void) => () => void) {
  const active = useLiveUpdates();
  return useCallback(
    (notify: () => void) => {
      if (!active) return () => {};
      const frame = frameNotification(notify);
      const stop = subscribe(frame.schedule);
      return () => {
        stop();
        frame.cancel();
      };
    },
    [active, subscribe],
  );
}

type Visibility = {
  observer: IntersectionObserver;
  listeners: Map<Element, (visible: boolean) => void>;
};
const visibility = new WeakMap<Document, Visibility>();

/** One observer per page, with no overscan. Clipping ancestors are included by the browser, so
 * a retained row stops live work as soon as it leaves its scroll pane, even after its first paint. */
export function observeLiveVisibility(node: HTMLElement, notify: (visible: boolean) => void): () => void {
  const doc = node.ownerDocument;
  const Observer = doc.defaultView?.IntersectionObserver;
  if (!Observer) return () => {};
  let shared = visibility.get(doc);
  if (!shared) {
    const listeners = new Map<Element, (visible: boolean) => void>();
    const observer = new Observer((entries) => {
      for (const entry of entries) listeners.get(entry.target)?.(entry.isIntersecting);
    });
    shared = { observer, listeners };
    visibility.set(doc, shared);
  }
  shared.listeners.set(node, notify);
  shared.observer.observe(node);
  return () => {
    shared.listeners.delete(node);
    shared.observer.unobserve(node);
    if (shared.listeners.size === 0) {
      shared.observer.disconnect();
      visibility.delete(doc);
    }
  };
}
