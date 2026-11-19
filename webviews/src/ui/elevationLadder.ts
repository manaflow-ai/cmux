// experiments.elevationLadder: one elevation ladder for every floating surface (tooltip, menu and
// popover, sheet, fullscreen; elevationLadder.css). The host sets `data-elevation-ladder` on the root
// while the setting is on; the CSS reads the attribute itself, and React code that changes behavior
// with it (the inline rename form, the popover's notch) reads it here. One observer for the whole
// page, whatever number of components follow it.
import { useSyncExternalStore } from "react";
import "./elevationLadder.css";

export const ELEVATION_LADDER_ATTRIBUTE = "data-elevation-ladder";

/** Whether the elevation ladder is on in this page now. */
export function elevationLadderOn(): boolean {
  return typeof document !== "undefined" && document.documentElement.hasAttribute(ELEVATION_LADDER_ATTRIBUTE);
}

const listeners = new Set<() => void>();
let observer: MutationObserver | undefined;

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (!observer && typeof MutationObserver !== "undefined") {
    observer = new MutationObserver(() => {
      for (const each of listeners) each();
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: [ELEVATION_LADDER_ATTRIBUTE] });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      observer?.disconnect();
      observer = undefined;
    }
  };
}

/** The elevation ladder's switch, re-rendering when the host turns it on or off. */
export function useElevationLadder(): boolean {
  return useSyncExternalStore(subscribe, elevationLadderOn, () => false);
}
