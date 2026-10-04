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

/// Text revealed `count` characters at a time; each step fades in for FADE_MS from `born`.
export type Reveal = { id: number; count: number; born: number };
/// How long newly revealed text fades in (acp-streaming.md "Reveal animation").
export const FADE_MS = 160;

type Shown = { length: number; fresh: Reveal[]; now: number };

/// The part of `text` to show this frame, and the steps still fading in.
export function useStreamReveal(text: string, streaming: boolean): { visible: string; fresh: Reveal[]; now: number } {
  const reveal = useRef<StreamReveal | null>(null);
  const reduce = useRef<boolean | null>(null);
  reduce.current ??= reducedMotion();
  // Text there when the row mounts shows at once; only what arrives after it flows in.
  reveal.current ??= new StreamReveal({ initial: text, reduceMotion: reduce.current });
  const [shown, setShown] = useState<Shown>(() => ({ length: text.length, fresh: [], now: 0 }));
  const latest = useRef({ text, streaming, shown });
  latest.current = { text, streaming, shown };
  const nextId = useRef(0);
  useLayoutEffect(() => {
    const current = reveal.current!;
    if (current.settled && shown.length >= text.length && !shown.fresh.length) return;
    let handle = 0;
    const tick = (now: number) => {
      // Text that arrived while the page was hidden shows at once; nobody watched it arrive.
      if (typeof document !== "undefined" && document.visibilityState === "hidden") current.flush();
      const before = latest.current.shown;
      const length = current.advance(latest.current.text, now, !latest.current.streaming);
      const fresh = before.fresh.filter((step) => now - step.born < FADE_MS);
      if (length > before.length && !reduce.current)
        fresh.push({ id: (nextId.current += 1), count: length - before.length, born: now });
      const next = { length, fresh, now };
      latest.current.shown = next;
      setShown(next);
      if (!current.settled || fresh.length) handle = revealFrames.request(tick);
    };
    handle = revealFrames.request(tick);
    return () => revealFrames.cancel(handle);
    // `shown` is read only to skip a loop that has nothing to do.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, streaming]);
  return { visible: text.slice(0, Math.min(shown.length, text.length)), fresh: shown.fresh, now: shown.now };
}

/// An assistant reply, revealed over frames while it streams.
export function RevealedMarkdown({ text, streaming }: { text: string; streaming: boolean }) {
  const { visible, fresh, now } = useStreamReveal(text, streaming);
  return (
    <Markdown streaming={streaming} fresh={fresh} now={now}>
      {visible}
    </Markdown>
  );
}
