// A reply as it streams: the text flows in over display frames (StreamReveal) instead of in
// bursts, one per acpmux delta. The same element shows the reply before and after the stream
// ends, so nothing remounts when it settles.
import { useLayoutEffect, useRef, useState } from "react";
import { StreamReveal } from "../streamReveal";
import { Markdown } from "./Markdown";

/// The display frames the reveal runs on (tests drive their own).
export const revealFrames = {
  request: (callback: (now: number) => void): number => requestAnimationFrame(callback),
  cancel: (handle: number): void => cancelAnimationFrame(handle),
};

const reducedMotion = () =>
  typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;

/// The part of `text` to show this frame.
export function useStreamReveal(text: string, streaming: boolean): string {
  const reveal = useRef<StreamReveal | null>(null);
  // Text there when the row mounts shows at once; only what arrives after it flows in.
  reveal.current ??= new StreamReveal({ initial: text, reduceMotion: reducedMotion() });
  const [shown, setShown] = useState(text.length);
  const latest = useRef({ text, streaming });
  latest.current = { text, streaming };
  useLayoutEffect(() => {
    const current = reveal.current!;
    if (current.settled && shown >= text.length) return;
    let handle = 0;
    const tick = (now: number) => {
      const length = current.advance(latest.current.text, now, !latest.current.streaming);
      setShown(length);
      if (!current.settled) handle = revealFrames.request(tick);
    };
    // The first frame only starts the clock; text moves from the next one.
    current.advance(text, 0, !streaming);
    handle = revealFrames.request(tick);
    return () => revealFrames.cancel(handle);
    // `shown` is read only to skip a loop that has nothing to do.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, streaming]);
  return text.slice(0, Math.min(shown, text.length));
}

/// An assistant reply, revealed over frames while it streams.
export function RevealedMarkdown({ text, streaming }: { text: string; streaming: boolean }) {
  const visible = useStreamReveal(text, streaming);
  return <Markdown streaming={streaming}>{visible}</Markdown>;
}
