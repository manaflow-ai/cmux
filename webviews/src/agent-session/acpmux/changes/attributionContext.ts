// Where a chat's edit diffs read who wrote their lines (changes/attribution.ts). The pane sets it
// (`useProvideAttribution`), with no provider around the transcript; without it (a gallery, a test,
// a page with no daemon) the diffs show no markers.
import { useEffect, useSyncExternalStore } from "react";
import type { AttributionRepo, AttributionStore } from "./attribution";

export type AttributionSource = {
  /// The chat the pane shows: its own turns read as "This chat".
  sessionId: string | undefined;
  store: AttributionStore;
  /// The shown chat's repository and commit; undefined when there is nothing to ask.
  repo(): Promise<AttributionRepo | undefined>;
  /// Scrolls the shown chat to one of its turns (App.tsx `reveal`, the path a turn link takes).
  reveal(turnId: string): void;
};

let current: AttributionSource | undefined;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const read = () => current;

/// Makes `source` the page's attribution source while the calling pane is mounted.
export function useProvideAttribution(source: AttributionSource): void {
  useEffect(() => {
    current = source;
    for (const listener of listeners) listener();
    return () => {
      if (current !== source) return;
      current = undefined;
      for (const listener of listeners) listener();
    };
  }, [source]);
}

/// The page's attribution source, or undefined where no pane set one.
export function useAttributionSource(): AttributionSource | undefined {
  return useSyncExternalStore(subscribe, read, read);
}
