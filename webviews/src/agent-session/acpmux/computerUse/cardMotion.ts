// The live preview card's two pieces of motion state (ComputerUsePreviewCard.tsx).
//
// `useLeavingCard` keeps the last card drawn while it plays its exit: the host takes the card away
// with a push (auto-hide after done, a close), and the card fades and scales down before it goes.
// The exit is the card's own CSS transitions (computerUsePreview.css, `data-leaving`); the hook
// waits for those to finish (the Web Animations API), never a timer. With motion off or reduced the
// card has no transition, so it goes at once.
//
// `useLoadedFrame` keeps the frame on screen until the next one has decoded, so a stream of frames
// (about 6 a second) never shows a blank one between two.
import { useEffect, useLayoutEffect, useRef, useState } from "react";

export interface LeavingCard<T> {
  /// The card to draw: the current one, or the last one while it leaves.
  card: T | null;
  /// The card is playing its exit (it takes no input then).
  leaving: boolean;
}

/// `element` is the card's root: its own transitions are the exit.
export function useLeavingCard<T>(value: T | null, element: Element | null): LeavingCard<T> {
  const [last, setLast] = useState<T | null>(value);
  // Follow the value during render, so the first frame after a push already draws it.
  if (value !== null && value !== last) setLast(value);
  const leaving = value === null && last !== null;

  useLayoutEffect(() => {
    if (!leaving) return;
    // The leaving style is committed: reading the animations resolves it, so the exit's
    // transitions are there. None (motion off, reduced, a test document): gone at once.
    const animations = element?.getAnimations?.() ?? [];
    if (animations.length === 0) {
      setLast(null);
      return;
    }
    let current = true;
    // A canceled transition (a style change under it) settles too: the card still goes.
    void Promise.allSettled(animations.map((animation) => animation.finished)).then(() => {
      if (current) setLast(null);
    });
    // A card that comes back during the exit stays: its transitions reverse from where they are.
    return () => {
      current = false;
    };
  }, [leaving, element]);

  return { card: value ?? last, leaving };
}

/// The newest frame that has decoded: a new `src` shows once its image is ready, and the one before
/// stays until then. A frame that fails to decode is skipped. With no image decoder (a test
/// document, the server render) the new frame shows at once.
export function useLoadedFrame(src: string | undefined): string | undefined {
  const [shown, setShown] = useState(src);
  // Frames decode out of order at times: an older frame that finishes later never replaces a newer one.
  const issued = useRef(0);
  const applied = useRef(0);
  useEffect(() => {
    if (!src) return;
    const order = ++issued.current;
    const apply = () => {
      if (order <= applied.current) return;
      applied.current = order;
      setShown(src);
    };
    if (typeof Image !== "function") {
      apply();
      return;
    }
    const image = new Image();
    image.src = src;
    if (typeof image.decode !== "function") {
      apply();
      return;
    }
    image.decode().then(apply, () => undefined);
  }, [src]);
  return shown ?? src;
}
