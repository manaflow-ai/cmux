// The Set Up cmux page's one view: the React card in its shipped look, sized to by the host.
import { useCallback, useEffect, useLayoutEffect, useRef, useSyncExternalStore } from "react";
import { cardStrings } from "../home-messages/cards/strings";
import { SetupCard } from "../home-messages/cards/setup/SetupCard";
import { SETUP_OPS } from "./ops";
import type { SetupCardStore } from "./store";

export function SetupCardPage({ store }: { store: SetupCardStore }) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const strings = cardStrings();
  const frame = useRef<HTMLDivElement>(null);
  // The host sizes its view to the card: measured after each render (a state change) and after each
  // layout change. A hidden page gets no ResizeObserver callbacks, so the render's own report is
  // what makes a card the host has not sized yet appear.
  const last = useRef(-1);
  const report = useCallback(() => {
    const node = frame.current;
    if (!node) return;
    const height = Math.ceil(node.getBoundingClientRect().height);
    if (height === last.current) return;
    last.current = height;
    store.send(SETUP_OPS.size, { height });
  }, [store]);
  useLayoutEffect(report);
  useEffect(() => {
    const node = frame.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(report);
    observer.observe(node);
    return () => observer.disconnect();
  }, [report]);
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
