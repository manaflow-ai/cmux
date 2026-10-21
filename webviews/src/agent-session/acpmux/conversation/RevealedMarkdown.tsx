// A reply as it streams: the text flows in over display frames (StreamReveal) instead of in
// bursts, one per acpmux delta. The same element shows the reply before and after the stream
// ends, so nothing remounts when it settles.
import { useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { StreamReveal, wordEdge } from "../streamReveal";
import { Markdown } from "./Markdown";
import { MessageBoundary } from "./MessageBoundary";
import { pageAway } from "../../shared/pageReveal";

/// The display frames the reveal runs on (tests drive their own).
export const revealFrames = {
  request: (callback: (now: number) => void): number => requestAnimationFrame(callback),
  cancel: (handle: number): void => cancelAnimationFrame(handle),
};

/// The Debug toggle `agentPane.debug.streamWords` (on by default): a reply grows a whole word at a
/// time. Off, the app sets `data-stream-words="off"` on <html> and it grows a character at a time.
export const streamWords = () =>
  typeof document === "undefined" || document.documentElement.dataset.streamWords !== "off";

const reducedMotion = () =>
  typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;

/// Text revealed `count` characters at a time; each step fades in for FADE_MS from `born`.
export type Reveal = { id: number; count: number; born: number };
/// How long newly revealed text fades in (acp-streaming.md "Reveal animation").
export const FADE_MS = 160;

type Shown = { length: number; fresh: Reveal[]; now: number };
/// React commits at most this often while revealing; fades run every display frame on the
/// compositor, so 60 commits a second read the same as 120 at half the main-thread cost.
const COMMIT_MS = 1000 / 60;
/// Frames closer together than this come from a display faster than 60 Hz. Only there does a
/// frame this soon after the last commit skip its own (at 120 Hz, every other frame). A 60 Hz
/// display commits on every frame: WebKit's frame times are whole milliseconds and jitter (a 14 ms
/// frame after a 19 ms one), and timing each frame against COMMIT_MS skipped one frame in six or
/// seven there, each a frame the reply did not grow while text waited.
const FAST_FRAME_MS = COMMIT_MS * 0.75;

/// A row's reveal loop: the frame it waits for (0 when idle), and the display's frame time.
type Loop = { handle: number; lastFrame?: number; lastCommit?: number; frameMs: number };

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
  const loop = useRef<Loop>({ handle: 0, frameMs: COMMIT_MS });
  // One loop per row, running while anything is left to reveal or fade. A new snapshot (once a
  // frame while the reply streams) starts it only if it is idle; it reads the latest text itself.
  // Restarting it on every snapshot re-requested its frame each time and threw away its timing.
  useLayoutEffect(() => {
    const current = reveal.current!;
    if (loop.current.handle) return;
    if (current.settled && shown.length >= text.length && !shown.fresh.length) return;
    loop.current.lastFrame = undefined;
    const tick = (now: number) => {
      const state = loop.current;
      // Every tick is a display frame; a gap (a hidden page, a long task) counts as two at most.
      if (state.lastFrame !== undefined)
        state.frameMs = state.frameMs * 0.8 + Math.min(now - state.lastFrame, 2 * COMMIT_MS) * 0.2;
      state.lastFrame = now;
      // Text that arrived while the page was hidden shows at once, with no fade; nobody watched it
      // arrive. WebKit runs no frames while a page is hidden, so this tick usually runs as the page
      // shows again: until its first frame back has passed, the backlog counts as away too
      // (shared/pageReveal.ts), and its blocks draw in place (Markdown's awayBlocks).
      const away = pageAway();
      if (
        !away &&
        state.frameMs < FAST_FRAME_MS &&
        state.lastCommit !== undefined &&
        now - state.lastCommit < FAST_FRAME_MS
      ) {
        state.handle = revealFrames.request(tick);
        return;
      }
      state.lastCommit = now;
      const before = latest.current.shown;
      const raw = current.advance(latest.current.text, now, !latest.current.streaming);
      // A word shows once it is whole, never a letter at a time (#22339); the reveal's own count
      // runs on, so a word that completes shows at once.
      let length =
        reduce.current || !streamWords()
          ? raw
          : wordEdge(latest.current.text, raw, !latest.current.streaming, before.length);
      // After `advance`, which takes in the text received meanwhile: all of it shows.
      if (away) {
        current.flush();
        length = latest.current.text.length;
      }
      // Nothing fades in on return, including the steps that were fading as the page hid.
      const fresh = away ? [] : before.fresh.filter((step) => now - step.born < FADE_MS);
      if (length > before.length && !reduce.current && !away)
        fresh.push({ id: (nextId.current += 1), count: length - before.length, born: now });
      const next = { length, fresh, now };
      latest.current.shown = next;
      // The backlog commits in this frame, before it paints: a state update from a frame callback
      // renders in a later task, so the first frame back showed the reply as the user left it and
      // the next one grew it and moved the transcript (Leo 2026-10-20, "no layout shifts").
      if (away) flushSync(() => setShown(next));
      else setShown(next);
      state.handle = !current.settled || fresh.length ? revealFrames.request(tick) : 0;
    };
    loop.current.handle = revealFrames.request(tick);
    // `shown` is read only to skip a loop that has nothing to do.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text, streaming]);
  useLayoutEffect(() => {
    const state = loop.current;
    return () => {
      revealFrames.cancel(state.handle);
      state.handle = 0;
    };
  }, []);
  return {
    visible: text.slice(0, Math.min(shown.length, text.length)),
    fresh: shown.fresh,
    now: shown.now,
  };
}

/// An assistant reply, revealed over frames while it streams. A reply that fails to draw falls
/// back to its plain text (MessageBoundary), never taking the pane with it.
export function RevealedMarkdown({
  text,
  streaming,
  githubRepository,
}: {
  text: string;
  streaming: boolean;
  githubRepository?: string;
}) {
  return (
    <MessageBoundary source={text}>
      <Revealed text={text} streaming={streaming} githubRepository={githubRepository} />
    </MessageBoundary>
  );
}

function Revealed({
  text,
  streaming,
  githubRepository,
}: {
  text: string;
  streaming: boolean;
  githubRepository?: string;
}) {
  const { visible, fresh, now } = useStreamReveal(text, streaming);
  return (
    <Markdown streaming={streaming} fresh={fresh} now={now} githubRepository={githubRepository}>
      {visible}
    </Markdown>
  );
}
