// The theme's personality decorations (ThemeDecorations.swift): named slots a look fills with something
// playful, the first step toward ricing. The host sends the filled ones with the theme
// (WebTheme `decorations`), which the bootstrap writes as `data-cmux-decoration-<slot>="<name>"` on
// <html>; an empty slot has no attribute, and the page draws what it drew before slots. An external
// store, read with useSyncExternalStore (no effects).
import { useSyncExternalStore } from "react";

/** A place a decoration can fill (ThemeDecorations.Slot). */
export type DecorationSlot = "updated-card";

/** The decoration filling `slot` now, or null. */
export function readDecoration(slot: DecorationSlot): string | null {
  return globalThis.document?.documentElement.getAttribute(`data-cmux-decoration-${slot}`) ?? null;
}

function subscribe(listener: () => void): () => void {
  const win = globalThis.window;
  if (!win) return () => undefined;
  win.addEventListener("cmux-theme", listener);
  return () => win.removeEventListener("cmux-theme", listener);
}

/** The decoration filling `slot`, following theme pushes. */
export function useDecoration(slot: DecorationSlot): string | null {
  return useSyncExternalStore(
    subscribe,
    () => readDecoration(slot),
    () => null,
  );
}
