// The agent pane's tool rows (`ToolRows` and the cards it draws) as their own chunk for Home's tool
// groups (HomeToolGroup.tsx): about 260 KB of JS no first frame of Home needs. Loaded once, then held
// here, so every group draws its rows synchronously from then on (no Suspense, no second paint).
import { useSyncExternalStore } from "react";
import type { ToolRows as ToolRowsComponent } from "../../agent-session/acpmux/conversation/TurnRows";

let loaded: typeof ToolRowsComponent | null = null;
let loading: Promise<void> | null = null;
let idleAsked = false;
const listeners = new Set<() => void>();

function load(): Promise<void> {
  loading ??= import("../../agent-session/acpmux/conversation/TurnRows").then(
    (module) => {
      loaded = module.ToolRows;
      for (const listener of listeners) listener();
    },
    () => {
      // A failed fetch (the page went offline) is asked again by the next group that needs it.
      loading = null;
      idleAsked = false;
    },
  );
  return loading;
}

/** Asks for the rows: `now` for a group the person sees open, `idle` for a folded one. */
export function toolRowsLoaded(when: "now" | "idle"): void {
  if (loaded) return;
  if (when === "now") {
    void load();
    return;
  }
  if (idleAsked) return;
  idleAsked = true;
  if (typeof requestIdleCallback === "function") requestIdleCallback(() => void load(), { timeout: 2000 });
  else setTimeout(() => void load(), 0);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** The rows component once loaded, else null (the caller asks with `toolRowsLoaded`). */
export function useToolRows(): typeof ToolRowsComponent | null {
  return useSyncExternalStore(subscribe, () => loaded);
}
