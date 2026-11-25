import { useSyncExternalStore } from "react";
import { diffPageFontZoom } from "./fontZoom";

const subscribe = (listener: () => void) => diffPageFontZoom().subscribe(listener);
const lineHeight = () => diffPageFontZoom().lineHeight;

/** The diff page's code line height at its zoom (fontZoom.ts), re-read after Cmd-= / Cmd-- / Cmd-0. */
export function useDiffCodeLineHeight(): number {
  return useSyncExternalStore(subscribe, lineHeight, lineHeight);
}
