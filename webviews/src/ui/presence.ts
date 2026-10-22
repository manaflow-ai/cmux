// Directional enter and exit (Leo 2026-10-20): a surface comes in from the side it belongs to and
// leaves the way it came. A panel on the right slides in from the right, a card above the composer
// rises from it, a bar at the top drops from the top, a drawer on the left comes from the left.
//
// `usePresence` keeps a closing surface mounted until its exit has played, and marks it with
// `data-enter` (its edge) and `data-presence` (`from`, `shown`, `leaving`); ui/popupSurface.css
// draws the motion from those, on the host's motion tokens (`--agent-motion-in` and `-out`, which
// the native Motion gate sets to 0 when the area's animations are off). A reopen during the exit
// reverses from where it is, as the transitions are interruptible. Motion off removes it at once;
// Reduce Motion keeps a fade with no travel.
import { useCallback, useLayoutEffect, useRef, useState } from "react";

/** The edge a surface enters from and leaves toward. */
export type EnterEdge = "right" | "left" | "top" | "bottom";

type Phase = "hidden" | "from" | "shown" | "leaving";

export interface PresenceProps {
  ref: (element: HTMLElement | null) => void;
  "data-enter": EnterEdge;
  "data-presence": Exclude<Phase, "hidden">;
}

export interface Presence {
  /** Whether to render the surface: shown, or still playing its exit. */
  present: boolean;
  /** Whether it is playing its exit (it takes no input then). */
  leaving: boolean;
  /** Spread on the surface's root element. */
  props: PresenceProps;
}

/// The longest transition on `element`, delay included, in milliseconds (0 when none runs: motion
/// off, a test document).
function transitionMs(element: HTMLElement): number {
  const style = getComputedStyle(element);
  const times = (value: string) =>
    value.split(",").map((part) => {
      const text = part.trim();
      const number = Number.parseFloat(text);
      if (!Number.isFinite(number)) return 0;
      return text.endsWith("ms") ? number : number * 1000;
    });
  const durations = times(style.transitionDuration ?? "");
  const delays = times(style.transitionDelay ?? "");
  return Math.max(0, ...durations.map((duration, index) => duration + (delays[index % delays.length] ?? 0)));
}

/// Presence of a surface that enters from `edge` while `shown`. With `appear`, a surface mounted
/// already shown enters too (a notice, a new card); without it, one shown at mount is simply there
/// (a panel restored with the page).
export function usePresence(shown: boolean, edge: EnterEdge, { appear = false }: { appear?: boolean } = {}): Presence {
  const [phase, setPhase] = useState<Phase>(() => (shown ? (appear ? "from" : "shown") : "hidden"));
  const element = useRef<HTMLElement | null>(null);
  const ref = useCallback((node: HTMLElement | null) => {
    element.current = node;
  }, []);

  // Follow `shown` during render, so the first frame after a change already carries its phase.
  let next = phase;
  if (shown && (phase === "hidden" || phase === "leaving")) next = phase === "hidden" ? "from" : "shown";
  if (!shown && (phase === "from" || phase === "shown")) next = "leaving";
  if (next !== phase) setPhase(next);

  useLayoutEffect(() => {
    const node = element.current;
    if (phase === "from") {
      // The `from` style must be resolved before the change to `shown`, or no transition starts.
      if (node) void getComputedStyle(node).opacity;
      setPhase("shown");
      return;
    }
    if (phase !== "leaving") return;
    const ms = node ? transitionMs(node) : 0;
    if (!node || ms <= 0) {
      setPhase("hidden");
      return;
    }
    const done = () => setPhase((current) => (current === "leaving" ? "hidden" : current));
    const ended = (event: TransitionEvent) => {
      if (event.target === node) done();
    };
    node.addEventListener("transitionend", ended);
    // A transition that never ends (the element's style changed under it) still unmounts.
    const timer = setTimeout(done, ms + 50);
    return () => {
      node.removeEventListener("transitionend", ended);
      clearTimeout(timer);
    };
  }, [phase]);

  const shownPhase = next === "hidden" ? "leaving" : next;
  return {
    present: next !== "hidden",
    leaving: next === "leaving",
    props: { ref, "data-enter": edge, "data-presence": shownPhase },
  };
}

/// The keys that arrived after the first render, for a list whose new rows enter (`data-enter` on
/// the row: ui/popupSurface.css plays it once when the row mounts) while the rows it is drawn with
/// are simply there. A key stays arrived until its row's enter has played (`played`, from the row's
/// `animationend`), so a row that remounts after that (View all, a fold reopening) is simply there.
/// `drawn` (default every key) are the rows on screen now: a key that comes while its row is folded
/// away is not arriving where anyone sees it, so it shows in place when the fold opens. The keys
/// must outlive a change of record; a list that can draw another chat is keyed by it.
export function useArrivals(
  keys: readonly string[],
  drawn: readonly string[] = keys,
): {
  arrived: ReadonlySet<string>;
  played: (key: string) => void;
} {
  const [state, setState] = useState(() => ({ seen: new Set(keys), arrived: new Set<string>() }));
  const played = useCallback((key: string) => {
    setState((current) => {
      if (!current.arrived.has(key)) return current;
      const arrived = new Set(current.arrived);
      arrived.delete(key);
      return { seen: current.seen, arrived };
    });
  }, []);
  const fresh = keys.filter((key) => !state.seen.has(key));
  if (fresh.length === 0) return { arrived: state.arrived, played };
  // Follow the keys during render, as usePresence follows `shown`.
  const onScreen = new Set(drawn);
  const next = {
    seen: new Set([...state.seen, ...fresh]),
    arrived: new Set([...state.arrived, ...fresh.filter((key) => onScreen.has(key))]),
  };
  setState(next);
  return { arrived: next.arrived, played };
}
