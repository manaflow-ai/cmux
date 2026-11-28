import { useEffect, useRef, useState, type ReactNode } from "react";
import type { HomeChannelsStore } from "./store";

/** Keep the same endpoint's last frame until the replacement connection has read the inbox and
 * selected conversation. A handshake alone must not replace a populated page with an empty store.
 * The endpoint key in DaemonGate owns isolation: a different endpoint mounts this afresh. */
export function HomeStorePresentation({
  store,
  children,
}: {
  store: HomeChannelsStore;
  children(store: HomeChannelsStore): ReactNode;
}) {
  const [shown, setShown] = useState(store);
  const displayed = useRef(store);
  useEffect(() => {
    if (store === displayed.current) return;
    let live = true;
    let started = false;
    let checking = false;
    let swapped = false;
    const selected = displayed.current.getSnapshot().selected;
    const reconsider = () => {
      const snapshot = store.getSnapshot();
      if (
        !live ||
        !started ||
        checking ||
        swapped ||
        snapshot.loading ||
        snapshot.error ||
        snapshot.connection !== "online"
      )
        return;
      checking = true;
      void (async () => {
        try {
          if (selected && snapshot.conversations.has(selected)) await store.select(selected, false);
          const ready = store.getSnapshot();
          if (live && !ready.loading && !ready.error && ready.connection === "online") {
            swapped = true;
            displayed.current = store;
            setShown(store);
          }
        } catch {
          // Keep the cached frame. A later store update may complete the failed read.
        }
        checking = false;
      })();
    };
    // Keep this subscription for this candidate's lifetime, including after it becomes visible.
    // Swapping the presentation does not stop/restart the store; the next candidate or unmount
    // releases this lease, and the visible page also owns its normal subscription.
    const stop = store.subscribe(reconsider);
    const settled = () => {
      started = true;
      reconsider();
    };
    void store.start().then(settled, settled);
    return () => {
      live = false;
      stop();
    };
  }, [store]);
  return children(shown);
}
