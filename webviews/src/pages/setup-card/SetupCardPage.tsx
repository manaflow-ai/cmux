// The Set Up cmux page's one view: the React card in its shipped look, sized to by the host.
import { useEffect, useRef, useSyncExternalStore } from "react";
import { cardStrings } from "../home-messages/cards/strings";
import { SetupCard } from "../home-messages/cards/setup/SetupCard";
import { SETUP_OPS } from "./ops";
import type { SetupCardStore } from "./store";

export function SetupCardPage({ store }: { store: SetupCardStore }) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const strings = cardStrings();
  const frame = useRef<HTMLDivElement>(null);
  // The host sizes its view to the card: each height change, measured after layout.
  useEffect(() => {
    const node = frame.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    let last = -1;
    const observer = new ResizeObserver(() => {
      const height = Math.ceil(node.getBoundingClientRect().height);
      if (height !== last) {
        last = height;
        store.send(SETUP_OPS.size, { height });
      }
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [store]);
  useEffect(() => {
    const onFocus = () => store.send(SETUP_OPS.focused, {});
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [store]);
  return (
    <div ref={frame} className="setup-card-frame">
      {state && (
        <SetupCard
          strings={strings}
          state={state}
          look="rows"
          onAction={(action) => store.send(SETUP_OPS.run, { action })}
          onHide={() => store.send(SETUP_OPS.hide, {})}
        />
      )}
    </div>
  );
}
