// The local images the pane has shown (ReplyImage.tsx). Another agent's message shows an image
// once (Leo 2026-10-21: "why is there those 2 cards???"): as a thumbnail in the strip under its
// text, while its mention in the text is a quiet link (LinkChips.tsx), not a second chip beside the
// picture. Until the thumbnail shows, and when it never does, the mention stays a chip.
import { useSyncExternalStore } from "react";

const shown = new Set<string>();
const listeners = new Set<() => void>();

/// Records that `src` drew; called when its load answers, never while drawing.
export function markImageShown(src: string): void {
  if (shown.has(src)) return;
  shown.add(src);
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Whether `src` (undefined: none) has drawn.
export function useImageShown(src: string | undefined): boolean {
  return useSyncExternalStore(subscribe, () => (src === undefined ? false : shown.has(src)));
}
