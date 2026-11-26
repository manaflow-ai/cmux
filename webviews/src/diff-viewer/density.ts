// The diff viewer's chrome follows the app density (Lawrence, 2026-11-20: Compact looked the same as
// Comfortable on the diff page). The host writes the density on the root (DesignSettings.interfaceScaleScript:
// `--cmux-density-scale`, the density's chrome row over Default's) and dispatches `cmux-ui-scale-change`. CSS
// follows it through the shared density tokens (pages/shared/pageDensity.css, which the root's
// `data-page-density` opts into); the two rows the virtualizers must know in pixels follow it here: a file's
// header bar (pierre's `diffHeaderHeight` metric) and a files list row (the tree's `itemHeight`). The code keeps
// its size at every density, as the chat's text does (fontZoom.ts).
import { useSyncExternalStore } from "react";
import { onInterfaceScaleChange } from "../ui/interfaceScale";

/** A file's header bar at the default density, in pixels; also the virtualizer's header metric. */
export const DIFF_FILE_HEADER_HEIGHT = 38;
/** A files list row at the default density, in pixels (the classic viewer's 29). */
export const FILE_TREE_ITEM_HEIGHT = 29;

/** The host's density scale on `root` (`--cmux-density-scale`); 1 with no host or no valid value. */
export function diffDensityScale(root: HTMLElement | null = globalThis.document?.documentElement ?? null): number {
  const value = Number.parseFloat(root?.style?.getPropertyValue?.("--cmux-density-scale") ?? "");
  return Number.isFinite(value) && value > 0 ? value : 1;
}

/** The header bar and files list row at `scale`, in whole pixels, so the drawn rows and the metrics agree. */
export function diffChromeRows(scale: number): { header: number; treeItem: number } {
  return {
    header: Math.round(DIFF_FILE_HEADER_HEIGHT * scale),
    treeItem: Math.round(FILE_TREE_ITEM_HEIGHT * scale),
  };
}

const subscribe = (listener: () => void) => onInterfaceScaleChange(listener);
const serverScale = () => 1;

/** The host's density scale, read again each time the host writes new scale tokens. */
export function useDiffDensityScale(): number {
  return useSyncExternalStore(subscribe, diffDensityScale, serverScale);
}
