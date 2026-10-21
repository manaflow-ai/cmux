import { useSyncExternalStore } from "react";

/** Opt-in visual treatments for a session's latest-reply hover card. */
export type SidebarPreviewVariant = "card" | "quiet" | "outline";

const DEFAULT_VARIANT: SidebarPreviewVariant = "card";
const isVariant = (value: unknown): value is SidebarPreviewVariant =>
  value === "card" || value === "quiet" || value === "outline";

/** Reads a Debug layout value or the prototype's `?sidebarPreview=` query. */
export function readSidebarPreviewVariant(value: unknown): SidebarPreviewVariant {
  return isVariant(value) ? value : DEFAULT_VARIANT;
}

const queryVariant = (): SidebarPreviewVariant | undefined => {
  if (typeof window === "undefined") return undefined;
  const query = new URLSearchParams(window.location.search).get("sidebarPreview");
  return isVariant(query) ? query : undefined;
};

const queryOverride = queryVariant();
let nativeVariant =
  typeof document === "undefined"
    ? DEFAULT_VARIANT
    : readSidebarPreviewVariant(document.documentElement.dataset.acpmuxSidebarPreview);
let customizationOverride: SidebarPreviewVariant | undefined;
let current = queryOverride ?? nativeVariant;
const listeners = new Set<() => void>();

const publish = (next: SidebarPreviewVariant): void => {
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === DEFAULT_VARIANT) delete document.documentElement.dataset.acpmuxSidebarPreview;
    else document.documentElement.dataset.acpmuxSidebarPreview = next;
  }
  for (const listener of listeners) listener();
};

/** Applies `layout.sidebarPreviewVariant` from the host's customization bridge. Passing no value
 * removes the customization override and restores the native Debug Settings baseline. */
export function configureSidebarPreviewVariant(value: unknown): void {
  customizationOverride = value === undefined ? undefined : readSidebarPreviewVariant(value);
  publish(queryOverride ?? customizationOverride ?? nativeVariant);
}

/** Applies the native Debug Settings baseline without clearing a user's explicit layout override. */
export function configureNativeSidebarPreviewVariant(value: unknown): void {
  nativeVariant = readSidebarPreviewVariant(value);
  if (customizationOverride === undefined) publish(queryOverride ?? nativeVariant);
}

/** Reads the page-level debug choice, unless a gallery/prototype passes an explicit prop. */
export function useSidebarPreviewVariant(override?: SidebarPreviewVariant): SidebarPreviewVariant {
  const configured = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current,
    () => DEFAULT_VARIANT,
  );
  return override ?? configured;
}
