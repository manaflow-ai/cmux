import { useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { StreamReveal, wordEdge } from "../streamReveal";
import { pageAway } from "../../shared/pageReveal";
import { MOTION_MS } from "../../../motion/scale.generated";

/// The display frames the reveal runs on (tests drive their own).
export const revealFrames = {
  request: (callback: (now: number) => void): number => requestAnimationFrame(callback),
  cancel: (handle: number): void => cancelAnimationFrame(handle),
};

const reducedMotion = () =>
  typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;

/// Text revealed `count` characters at a time; each step fades in for FRESH_FADE_STEPS of the
/// host's `--agent-motion-in` from `born`.
export type Reveal = { id: number; count: number; born: number };
/// How many of the host's `--agent-motion-in` steps the fade of newly revealed text runs
/// (conversation.css `.cv-fresh`, which runs the same): one, so the newest words never trail the
/// stream by a third of a second (Leo, 2026-11-09: "cannot lag nor can they take long").
export const FRESH_FADE_STEPS = 1;
/// How long newly revealed text keeps its fade (acp-streaming.md "Reveal animation"). `.cv-fresh`
/// runs FRESH_FADE_STEPS of the host's `--agent-motion-in`. The fallback matches the conversation
/// stylesheet's default. The host can change this token at runtime, so expiry reads it as spans are
/// retired instead of letting a fixed scale value outlive or cut short the CSS fade.
export const FADE_MS = MOTION_MS.micro * FRESH_FADE_STEPS;

function freshFadeMs(): number {
  if (typeof document === "undefined") return FADE_MS;
  try {
    const token =
      document.defaultView?.getComputedStyle(document.documentElement).getPropertyValue("--agent-motion-in").trim() ??
      "";
    const value = Number.parseFloat(token);
    if (!Number.isFinite(value) || value < 0) return FADE_MS;
    if (token.endsWith("ms")) return value * FRESH_FADE_STEPS;
    if (token.endsWith("s")) return value * 1000 * FRESH_FADE_STEPS;
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

/// A row's reveal state: the length of the text when it last grew, and when.
type Loop = { grownTo?: number; grewAt?: number };

/// One row's work for a display frame: true while it has more to reveal or fade.
/// `fadeMs` is the host's fade token, read once a frame for every row (a computed-style read each).
type RevealTick = (now: number, away: boolean, fadeMs: number) => boolean;

/// The one clock every revealing row runs on (chat-instant-under-load.md, piece 4). One display
/// frame callback for the whole page, however many rows reveal: each due row advances in it, and
/// React batches their state into one render and one commit. It holds a frame only while some row
/// has more to reveal or fade, and stops when none has (its stop condition). Before it, each row
/// ran its own frame loop and committed on its own.
export const revealClock = {
  rows: new Set<RevealTick>(),
  handle: 0,
  /// Which requested frame is the clock's: a frame callback the clock no longer waits for (cancelled,
  /// or superseded) does nothing when it runs.
  frame: 0,
  running: false,
  lastFrame: undefined as number | undefined,
  lastCommit: undefined as number | undefined,
  frameMs: COMMIT_MS,
  /// Rows taken off during the current frame's run (an unmount in a flushed render): not put back.
  gone: new Set<RevealTick>(),
  /// Runs `tick` from the next display frame on, until it returns false.
  add(tick: RevealTick): void {
    this.rows.add(tick);
    if (!this.handle && !this.running) this.request();
  },
  /// Takes `tick` off the clock; the clock stops when no row is left.
  remove(tick: RevealTick): void {
    this.rows.delete(tick);
    if (this.running) this.gone.add(tick);
    if (this.rows.size || this.running) return;
    this.stop();
  },
  request(): void {
    const frame = (this.frame += 1);
    this.handle = revealFrames.request((now) => {
      if (frame === this.frame) revealFrame(now);
    });
  },
  /// No row left: the frame is given back and the clock's timing starts over with the next row.
  stop(): void {
    if (this.handle) revealFrames.cancel(this.handle);
    this.handle = 0;
    this.frame += 1;
    this.lastFrame = undefined;
    this.lastCommit = undefined;
  },
};

function revealFrame(now: number): void {
  const clock = revealClock;
  clock.handle = 0;
  if (!clock.rows.size) {
    clock.stop();
    return;
  }
  // Every tick is a display frame; a gap (a hidden page, a long task) counts as two at most.
  if (clock.lastFrame !== undefined && now >= clock.lastFrame)
    clock.frameMs = clock.frameMs * 0.8 + Math.min(now - clock.lastFrame, 2 * COMMIT_MS) * 0.2;
  clock.lastFrame = now;
  // Text that arrived while the page was hidden shows at once, with no fade; nobody watched it
  // arrive. WebKit runs no frames while a page is hidden, so this tick usually runs as the page
  // shows again: until its first frame back has passed, the backlog counts as away too
  // (shared/pageReveal.ts), and its blocks draw in place (Markdown's awayBlocks).
  const away = pageAway();
  if (
    !away &&
    clock.frameMs < FAST_FRAME_MS &&
    clock.lastCommit !== undefined &&
    now >= clock.lastCommit &&
    now - clock.lastCommit < FAST_FRAME_MS
  ) {
    clock.request();
    return;
  }
  clock.lastCommit = now;
  const due = [...clock.rows];
  clock.rows.clear();
  clock.running = true;
  // How many of `due` have run: a row that throws stops only itself; the rows after it stay on the clock.
  let ran = 0;
  const run = () => {
    const fadeMs = freshFadeMs();
    while (ran < due.length) {
      const tick = due[ran]!;
      ran += 1;
      if (!clock.gone.has(tick) && tick(now, away, fadeMs) && !clock.gone.has(tick)) clock.rows.add(tick);
    }
  };
  try {
    // The backlog commits in this frame, before it paints, for every row at once: a state update
    // from a frame callback renders in a later task, so the first frame back showed the reply as
    // the user left it and the next one grew it and moved the transcript (Leo 2026-10-20, "no
    // layout shifts"). Only a page coming back takes this path; a streaming frame never does.
    if (away) flushSync(run);
    else run();
  } finally {
    for (const tick of due.slice(ran)) if (!clock.gone.has(tick)) clock.rows.add(tick);
    clock.running = false;
    clock.gone.clear();
    if (clock.rows.size) clock.request();
    else clock.stop();
  }
}

/// The part of `text` to show this frame, and the steps still fading in.
export function useStreamReveal(text: string, streaming: boolean): { visible: string; fresh: Reveal[]; now: number } {
  const reveal = useRef<StreamReveal | null>(null);
  const reduce = useRef<boolean | null>(null);
  reduce.current ??= reducedMotion();
  // Assistant text is append-only. A reconnect can briefly deliver a shorter prefix; keep the
  // last complete body on screen until the replacement page restores it.
  const [knownText, setKnownText] = useState(text);
  const [previous, setPrevious] = useState({ text, streaming });
  const historicalReplacement = !streaming && !previous.streaming && text !== previous.text;
  const displayText = text.length < knownText.length ? knownText : text;
  // Text there when the row mounts shows at once; only what arrives after it flows in.
  reveal.current ??= new StreamReveal({ initial: displayText, reduceMotion: reduce.current });
  const [shown, setShown] = useState<Shown>(() => ({ length: displayText.length, fresh: [], now: 0 }));
  const latest = useRef({ text: displayText, streaming, shown });
  latest.current = { text: displayText, streaming, shown };
  const nextId = useRef(0);
  const loop = useRef<Loop>({});
  // This row's work on the page's one reveal clock (revealClock), made once: it reads the latest
  // text and state itself, so a new snapshot (once a frame while the reply streams) only puts it on
  // the clock when it is off, never restarts it.
  const [tick] = useState<RevealTick>(() => (now, away, fadeMs) => {
    const current = reveal.current!;
    const state = loop.current;
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
    let length = reduce.current ? raw : wordEdge(target, raw, !live || paused, before.length);
    // After `advance`, which takes in the text received meanwhile: all of it shows.
    if (away) {
      current.flush();
      length = latest.current.text.length;
    }
    // Nothing fades in on return, including the steps that were fading as the page hid.
    const fresh = away ? [] : before.fresh.filter((step) => now - step.born < fadeMs);
    if (length > before.length && !reduce.current && !away)
      fresh.push({ id: (nextId.current += 1), count: length - before.length, born: now });
    // A frame that only waits out a held last word commits nothing. Every row's update in a frame
    // lands in the clock's one callback, so React renders and commits them together.
    if (length !== before.length || fresh.length || before.fresh.length) {
      const next = { length, fresh, now };
      latest.current.shown = next;
      setShown(next);
    }
    const held = length < target.length;
    return !current.settled || fresh.length > 0 || held;
  });
  useLayoutEffect(() => {
    const current = reveal.current!;
    // A completed historical row is already settled when it is published. If a page swap gives
    // it a fuller body, paint that body in the same commit; waiting for the reveal clock would show
    // the old prefix and animate the restored suffix as if it were new text.
    if (historicalReplacement) {
      current.replace(displayText);
      const next = { length: displayText.length, fresh: [], now: shown.now };
      latest.current.shown = next;
      setShown(next);
      return;
    }
    if (revealClock.rows.has(tick)) return;
    if (current.settled && shown.length >= displayText.length && !shown.fresh.length) return;
    revealClock.add(tick);
    // `shown` is read only to skip a row that has nothing to do.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [displayText, historicalReplacement, shown, streaming]);
  useLayoutEffect(() => {
    // Keep the longest complete body for a reconnect snapshot that briefly goes backwards.
    setKnownText((current) => (text.length >= current.length ? text : current));
  }, [text]);
  useLayoutEffect(() => {
    setPrevious({ text, streaming });
  }, [text, streaming]);
  useLayoutEffect(() => () => revealClock.remove(tick), [tick]);
  // Reduce Motion can change while the row is mounted, and the stylesheet follows it at once.
  // Turned on, the whole reply shows now: the pending frame is cancelled and no step is left
  // fading; later text shows as it arrives. Turned off, later text is paced again.
  useLayoutEffect(() => {
    const query = typeof window === "undefined" ? undefined : window.matchMedia?.("(prefers-reduced-motion: reduce)");
    if (!query) return;
    const changed = () => {
      const on = query.matches;
      if (reduce.current === on) return;
      reduce.current = on;
      reveal.current!.setReduceMotion(on, latest.current.text);
      if (!on) return;
      revealClock.remove(tick);
      const { text: target, shown: before } = latest.current;
      if (before.length === target.length && !before.fresh.length) return;
      const next = { length: target.length, fresh: [], now: before.now };
      latest.current.shown = next;
      setShown(next);
    };
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, [tick]);
  return {
    visible: historicalReplacement ? displayText : displayText.slice(0, Math.min(shown.length, displayText.length)),
    fresh: historicalReplacement ? [] : shown.fresh,
    now: shown.now,
  };
}
