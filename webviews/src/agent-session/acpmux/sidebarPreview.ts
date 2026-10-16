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

const initialVariant = (): SidebarPreviewVariant => {
  if (typeof window === "undefined") return DEFAULT_VARIANT;
  const query = new URLSearchParams(window.location.search).get("sidebarPreview");
  return readSidebarPreviewVariant(query ?? document.documentElement.dataset.acpmuxSidebarPreview);
};

let current = initialVariant();
const listeners = new Set<() => void>();

/** Applies `layout.sidebarPreviewVariant` from the host's customization bridge. */
export function configureSidebarPreviewVariant(value: unknown): void {
  const next = readSidebarPreviewVariant(value);
  if (next === current) return;
  current = next;
  if (typeof document !== "undefined") {
    if (next === DEFAULT_VARIANT) delete document.documentElement.dataset.acpmuxSidebarPreview;
    else document.documentElement.dataset.acpmuxSidebarPreview = next;
  }
  for (const listener of listeners) listener();
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
