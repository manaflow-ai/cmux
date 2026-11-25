import { useLayoutEffect, useRef, useState } from "react";
import { StreamReveal, wordEdge } from "../streamReveal";
import { pageAway } from "../../shared/pageReveal";
import { MOTION_MS } from "../../../motion/scale.generated";

/// The display frames the reveal runs on, and its clock (tests drive their own).
export const revealFrames = {
  request: (callback: (now: number) => void): number => requestAnimationFrame(callback),
  cancel: (handle: number): void => cancelAnimationFrame(handle),
  now: (): number => performance.now(),
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

/// What shows of the reply: its first `length` characters of `text` (the text that was drawn), the
/// steps still fading in, and the time of the last step. `done` is whether the stream had ended.
type Shown = { text: string; done: boolean; length: number; fresh: Reveal[]; now: number };

/// The fade's length, read from the stylesheet by the frame loop (a style read in render would force
/// a style recalc on the commit that draws new text).
let fadeMs = FADE_MS;

/// One row's work for a display frame: true while it has more to show or a fade to drop.
type RevealTick = (now: number) => boolean;

/// The one clock every revealing row runs on (chat-instant-under-load.md, piece 4). One display frame
/// callback for the whole page, however many rows hold a last word or a fading step: each row advances
/// in it, React batches their state into one render and one commit, and the host's fade token is read
/// once a frame instead of once a row (a computed-style read each). It holds a frame only while some row
/// has work, and gives it back when none has. Before it, each row ran its own frame loop.
export const revealClock = {
  rows: new Set<RevealTick>(),
  handle: 0,
  /// Which requested frame is the clock's: a frame callback the clock no longer waits for (cancelled,
  /// or superseded) does nothing when it runs.
  frame: 0,
  /// Runs `tick` from the next display frame on, until it returns false or is removed.
  add(tick: RevealTick): void {
    this.rows.add(tick);
    if (!this.handle) this.request();
  },
  /// Takes `tick` off the clock; the clock gives its frame back when no row is left.
  remove(tick: RevealTick): void {
    this.rows.delete(tick);
    if (!this.rows.size) this.stop();
  },
  has(tick: RevealTick): boolean {
    return this.rows.has(tick);
  },
  request(): void {
    const frame = (this.frame += 1);
    this.handle = revealFrames.request((now) => {
      if (frame === this.frame) revealFrame(now);
    });
  },
  stop(): void {
    if (this.handle) revealFrames.cancel(this.handle);
    this.handle = 0;
    this.frame += 1;
  },
};

function revealFrame(now: number): void {
  const clock = revealClock;
  clock.handle = 0;
  fadeMs = freshFadeMs();
  try {
    // A row that throws leaves the clock (as its own loop stopped before); the rows after it stay on it.
    // A snapshot: a row added during this frame starts on the next one.
    for (const tick of Array.from(clock.rows)) {
      if (!clock.rows.has(tick)) continue;
      let more = false;
      try {
        more = tick(now);
      } finally {
        if (!more) clock.rows.delete(tick);
      }
    }
  } finally {
    if (clock.rows.size) {
      if (!clock.handle) clock.request();
    } else clock.stop();
  }
}

/// The next `Shown` for `text`: all of it that has arrived, ending at a whole word while the stream
/// runs (wordEdge; `release` lets the last word show too), and the newly shown characters as one
/// fading step. Away (a hidden page) and Reduce Motion show everything with no fade.
function nextShown(
  before: Shown,
  text: string,
  done: boolean,
  now: number,
  { reduce, away, release, id }: { reduce: boolean; away: boolean; release: boolean; id: () => number },
): Shown {
  const kept = Math.min(before.length, text.length);
  const length = reduce || away ? text.length : wordEdge(text, text.length, done || release, kept);
  if (reduce || away) return { text, done, length, fresh: [], now };
  const fresh = before.fresh.filter((step) => now - step.born < fadeMs);
  if (length > kept) fresh.push({ id: id(), count: length - kept, born: now });
  return { text, done, length, fresh, now: length > kept ? now : before.now };
}

/// The part of `text` to show, and the steps still fading in. Text shows in the commit that brings it,
/// which acpmux's snapshots make once per display frame (direct.ts `emitInFrame`): the reply's height
/// changes only when text arrives, and every streamed chunk draws the reply once. Newly shown text
/// fades in (`.cv-fresh`), an opacity effect that never changes height. A pacer used to let text
/// through over the frames after it arrived (StreamReveal): each step grew the row again, and the row's
/// growth fed the follow chase (cmuxterm-hq docs/design/agent-transcript-clean-slate.md, step 3).
/// A frame loop runs only to show a held last word once text stops arriving and to drop finished fades.
export function useStreamReveal(text: string, streaming: boolean): { visible: string; fresh: Reveal[]; now: number } {
  const reduce = useRef<boolean | null>(null);
  reduce.current ??= reducedMotion();
  // Assistant text is append-only. A reconnect can briefly deliver a shorter prefix; keep the
  // last complete body on screen until the replacement page restores it.
  const [knownText, setKnownText] = useState(text);
  if (text.length >= knownText.length && text !== knownText) setKnownText(text);
  const displayText = text.length < knownText.length ? knownText : text;
  // Text there when the row mounts shows at once; only what arrives after it fades in.
  const [shown, setShown] = useState<Shown>(() => ({
    text: displayText,
    done: !streaming,
    length: displayText.length,
    fresh: [],
    now: 0,
  }));
  const nextId = useRef(0);
  const id = () => (nextId.current += 1);
  const done = !streaming;
  let current = shown;
  if (displayText !== shown.text || done !== shown.done) {
    // A completed historical row replaced by a fuller body (a page swap) is already settled: it
    // shows whole, never faded in as if it had just streamed.
    current =
      done && shown.done
        ? { text: displayText, done, length: displayText.length, fresh: [], now: shown.now }
        : nextShown(shown, displayText, done, revealFrames.now(), {
            reduce: reduce.current,
            away: pageAway(),
            release: false,
            id,
          });
    // Set during render: React draws this component again before its children, so the reply's
    // Markdown renders once per chunk.
    setShown(current);
  }
  const latest = useRef(current);
  latest.current = current;
  // This row's work on the page's one reveal clock (revealClock), made once: while the last word is
  // held, or a step still fades, once a frame. It reads the latest state itself; a new chunk puts it
  // on the clock only when it is off.
  const [tick] = useState<RevealTick>(() => (now: number) => {
    const before = latest.current;
    let next = before;
    const held = before.length < before.text.length;
    // The last word counts as whole once text stops arriving: before a tool call it has no space
    // after it, and the agent may work on the call for seconds.
    if (held && now - before.now >= StreamReveal.stallMs)
      next = nextShown(before, before.text, before.done, now, {
        reduce: reduce.current!,
        away: pageAway(),
        release: true,
        id,
      });
    // A finished fade's span goes in a commit that draws text anyway, or once every fade is done.
    else if (before.fresh.length && before.fresh.every((step) => now - step.born >= fadeMs))
      next = { ...before, fresh: [] };
    if (next !== before) {
      latest.current = next;
      setShown(next);
    }
    return next.length < next.text.length || next.fresh.length > 0;
  });
  useLayoutEffect(() => {
    if (revealClock.has(tick)) return;
    if (current.length >= current.text.length && !current.fresh.length) return;
    revealClock.add(tick);
  });
  useLayoutEffect(() => () => revealClock.remove(tick), [tick]);
  // Reduce Motion can change while the row is mounted, and the stylesheet follows it at once.
  // Turned on, the whole reply shows now and no step is left fading; later text shows as it arrives
  // with no fade. Turned off, later text fades in again.
  useLayoutEffect(() => {
    const query = typeof window === "undefined" ? undefined : window.matchMedia?.("(prefers-reduced-motion: reduce)");
    if (!query) return;
    const changed = () => {
      const on = query.matches;
      if (reduce.current === on) return;
      reduce.current = on;
      if (!on) return;
      revealClock.remove(tick);
      const before = latest.current;
      if (before.length === before.text.length && !before.fresh.length) return;
      const next = { ...before, length: before.text.length, fresh: [] };
      latest.current = next;
      setShown(next);
    };
    changed();
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  }, [tick]);
  return {
    visible: displayText.slice(0, Math.min(current.length, displayText.length)),
    fresh: current.fresh,
    now: current.now,
  };
}
