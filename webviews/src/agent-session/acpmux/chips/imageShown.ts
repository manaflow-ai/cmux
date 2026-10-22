// The images one agent message's strip has shown (ReplyImage.tsx `strip`). The message shows an
// image once (Leo 2026-10-21: "why is there those 2 cards???"): as a thumbnail under its text,
// while its mention in the text is a quiet link (LinkChips.tsx), not a second chip beside the
// picture. Until the thumbnail shows, and when it never does, the mention stays a chip. Each card
// keeps its own (IncomingMessageCard.tsx): another card's thumbnail says nothing about this one.
import { useEffect, useSyncExternalStore } from "react";

export type ShownImages = {
  readonly has: (src: string) => boolean;
  readonly mark: (src: string) => void;
  readonly subscribe: (listener: () => void) => () => void;
};

/// A card's empty record of shown images.
export function shownImages(): ShownImages {
  const shown = new Set<string>();
  const listeners = new Set<() => void>();
  return {
    has: (src) => shown.has(src),
    mark: (src) => {
      if (shown.has(src)) return;
      shown.add(src);
      for (const listener of listeners) listener();
    },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
  };
}

const NOTHING = () => () => {};

/// Whether `src` has shown in `store` (none outside a message's card).
export function useImageShown(store: ShownImages | undefined, src: string): boolean {
  const shown = () => store?.has(src) ?? false;
  // A server render (tests, the gallery's first paint) reads the same snapshot.
  return useSyncExternalStore(store?.subscribe ?? NOTHING, shown, shown);
}

/// Records in `store` that `src` drew, once it has (after the draw, never during it).
export function useMarkShown(store: ShownImages | undefined, src: string, shown: boolean): void {
  useEffect(() => {
    if (shown) store?.mark(src);
  }, [store, src, shown]);
}
