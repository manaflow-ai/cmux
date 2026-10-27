// A reply as it streams: the text flows in over display frames (StreamReveal) instead of in
// bursts, one per acpmux delta. The same element shows the reply before and after the stream
// ends, so nothing remounts when it settles.
import { useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { StreamReveal, wordEdge } from "../streamReveal";
import { Markdown } from "./Markdown";
import { MessageBoundary } from "./MessageBoundary";
import { pageAway } from "../../shared/pageReveal";
import { MOTION_MS } from "../../../motion/scale.generated";

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

/// Text revealed `count` characters at a time; each step fades in for the host's
/// `--agent-motion-in` duration from `born`.
export type Reveal = { id: number; count: number; born: number };
/// How long newly revealed text keeps its fade (acp-streaming.md "Reveal animation"). `.cv-fresh`
/// runs the host's `--agent-motion-in`. The fallback matches the conversation stylesheet's
/// default. The host can change this token at runtime, so expiry reads it as spans are retired
/// instead of letting a fixed scale value outlive or cut short the CSS fade.
export const FADE_MS = MOTION_MS.standard;

function motionDurationMs(): number {
  if (typeof document === "undefined") return FADE_MS;
  try {
    const token =
      document.defaultView?.getComputedStyle(document.documentElement).getPropertyValue("--agent-motion-in").trim() ??
      "";
    const value = Number.parseFloat(token);
    if (!Number.isFinite(value) || value < 0) return FADE_MS;
    if (token.endsWith("ms")) return value;
    if (token.endsWith("s")) return value * 1000;
  } catch {
    // A document without computed styles (SSR or a minimal test DOM) uses the stylesheet fallback.
  }
  return FADE_MS;
}

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

/// A row's reveal loop: the frame it waits for (0 when idle), the display's frame time, and the
/// length of the text when it last grew, and when.
type Loop = {
  handle: number;
  lastFrame?: number;
  lastCommit?: number;
  frameMs: number;
  grownTo?: number;
  grewAt?: number;
};

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
      state.handle = 0;
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
      const { text: target, streaming: live } = latest.current;
      if (state.grownTo !== target.length) {
        state.grownTo = target.length;
        state.grewAt = now;
      }
      const raw = current.advance(target, now, !live);
      // A word shows once it is whole, never a letter at a time (#22339); the reveal's own count
      // runs on, so a word that completes shows at once. The last word counts as whole once text
      // stops arriving: before a tool call it has no space after it, and the agent may work on the
      // call for seconds.
      const paused = now - state.grewAt! >= StreamReveal.stallMs;
      let length = reduce.current || !streamWords() ? raw : wordEdge(target, raw, !live || paused, before.length);
      // After `advance`, which takes in the text received meanwhile: all of it shows.
      if (away) {
        current.flush();
        length = latest.current.text.length;
      }
      // Nothing fades in on return, including the steps that were fading as the page hid.
      const fadeMs = motionDurationMs();
      const fresh = away ? [] : before.fresh.filter((step) => now - step.born < fadeMs);
      if (length > before.length && !reduce.current && !away)
        fresh.push({ id: (nextId.current += 1), count: length - before.length, born: now });
      // A frame that only waits out a held last word commits nothing.
      if (length !== before.length || fresh.length || before.fresh.length) {
        const next = { length, fresh, now };
        latest.current.shown = next;
        // The backlog commits in this frame, before it paints: a state update from a frame callback
        // renders in a later task, so the first frame back showed the reply as the user left it and
        // the next one grew it and moved the transcript (Leo 2026-10-20, "no layout shifts").
        if (away) flushSync(() => setShown(next));
        else setShown(next);
      }
      const held = length < target.length;
      if (!current.settled || fresh.length || held) state.handle = revealFrames.request(tick);
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
  messageAt,
  artifactIdentity,
  artifactRevision,
}: {
  text: string;
  streaming: boolean;
  githubRepository?: string;
  messageAt?: number;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  return (
    <MessageBoundary source={text}>
      <Revealed
        text={text}
        streaming={streaming}
        githubRepository={githubRepository}
        messageAt={messageAt}
        artifactIdentity={artifactIdentity}
        artifactRevision={artifactRevision}
      />
    </MessageBoundary>
  );
}

function Revealed({
  text,
  streaming,
  githubRepository,
  messageAt,
  artifactIdentity,
  artifactRevision,
}: {
  text: string;
  streaming: boolean;
  githubRepository?: string;
  messageAt?: number;
  artifactIdentity?: string;
  artifactRevision?: number;
}) {
  const { visible, fresh, now } = useStreamReveal(text, streaming);
  // Until all of it shows, the reply draws as streaming: the frame after the stream ends still
  // lacks the last word, and parsed as finished, a span that word closes showed its raw Markdown.
  return (
    <Markdown
      streaming={streaming || visible.length < text.length}
      fresh={fresh}
      now={now}
      githubRepository={githubRepository}
      messageAt={messageAt}
      artifactIdentity={artifactIdentity}
      artifactRevision={artifactRevision}
    >
      {visible}
    </Markdown>
  );
}
