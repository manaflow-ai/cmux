import { useSyncExternalStore } from "react";

/// Below this pane width the side panel covers the whole pane instead of sitting beside the chat
/// (conversation.css `@media (max-width: 720px)`): the chat's header, and the Inspector's toggle in
/// it, are under it, so the Inspector steps aside while it is open (App.tsx `covered`).
export const ARTIFACT_COVERS_PANE = "(max-width: 720px)";
const subscribeCovers = (change: () => void) => {
  const query = globalThis.matchMedia?.(ARTIFACT_COVERS_PANE);
  query?.addEventListener("change", change);
  return () => query?.removeEventListener("change", change);
};
const coversNow = () => globalThis.matchMedia?.(ARTIFACT_COVERS_PANE).matches ?? false;
/// Whether an open side panel would cover the whole pane at its current width.
export const useArtifactCoversPane = (): boolean => useSyncExternalStore(subscribeCovers, coversNow, () => false);
