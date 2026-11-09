import { useSyncExternalStore } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { MINIMAP_MIN_PANE } from "./paint";
import { chatMinimapPlaceholder } from "./placeholder.experiment";

/// While the rows keep changing, the picture follows at most this often.
export const REDRAW_MS = 250;
/// The placeholder's look: the shimmer, except in the gallery, which compares the others. Only the
/// gallery sets an arm in globalThis.cmuxExperiments; a stored cmux.experiments override is ignored.
export const placeholderLook = () => experimentArm(chatMinimapPlaceholder, { stored: {} });

const roomQuery = `(min-width: ${MINIMAP_MIN_PANE}px)`;
const subscribeRoom = (listener: () => void) => {
  if (typeof window === "undefined" || !window.matchMedia) return () => undefined;
  const query = window.matchMedia(roomQuery);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
};
const hasRoom = () => typeof window === "undefined" || !window.matchMedia || window.matchMedia(roomQuery).matches;

/// Whether the pane is wide enough for the column to keep the minimap's room (the page is the pane).
export function useChatMinimapRoom(): boolean {
  return useSyncExternalStore(subscribeRoom, hasRoom, hasRoom);
}
