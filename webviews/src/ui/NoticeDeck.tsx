// The stacked layout of NoticeStack (leo-workspace design/notifications.md): a compact deck. The
// newest toast is in front at the bottom; up to two older ones peek above it, each a step smaller,
// cut to the front one's height with their text hidden. While the pointer or focus is in the deck
// it spreads into the full list, newest at the bottom, so every toast can be read, answered or
// closed; it gathers again when they leave.
//
// Every change is one state transition of the whole deck (Leo, 2026-11-04: "we move all our
// affected, possibly affected elements in the cohesive way"): a new toast rises into the front from
// the deck's foot while the others step back in the same frames; a closed one sinks out of the foot
// while the rest step forward; a repeat moves to the front. The deck clips at its foot, so a toast
// travels in and out from behind that edge with no fade and nothing popping in. Its box is placed
// absolutely and its height follows the toasts, so nothing under it ever moves.
//
// Motion: transitions only, on the shared motion tokens; `data-cmux-motion` off or reduced, or the
// system's Reduce Motion, ends them (notice.css), and a closed toast then goes at once.
//
// Measuring: each toast's natural height is read once per change of the toasts or of the deck's
// width (a ResizeObserver on the deck, disconnected on unmount), never per frame.
import { useCallback, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import type { NoticeEntry } from "./NoticeStack";

export type DeckAlign = "center" | "end";

/** How far each older toast peeks above the one in front, and the gap between spread toasts. */
export const DECK_PEEK = 8;
export const DECK_GAP = 8;
/** Each step back is this much smaller. */
export const DECK_SCALE_STEP = 0.05;
/** At most this many toasts show in the gathered deck; the rest wait behind. */
export const DECK_DEPTH = 3;
/** A closed toast is kept this long at most for its exit, if no transitionend comes. */
const EXIT_FALLBACK_MS = 400;

type Phase = "from" | "shown" | "leaving";

interface Card {
  entry: NoticeEntry;
  phase: Phase;
  /** Where a leaving card was, so it sinks from there. */
  at?: { y: number; scale: number; height: number };
}

export interface DeckPlace {
  y: number;
  scale: number;
  /** The card's drawn height: its own when spread or in front, the front's when gathered. */
  height: number | undefined;
  /** Hidden behind the visible depth. */
  hidden: boolean;
}

/// Where each toast stands, newest first: gathered, each older one `DECK_PEEK` higher and a step
/// smaller, cut to the front one's height; spread, each above the newer ones with `DECK_GAP`
/// between. `heights` are the toasts' natural heights (0 when not measured yet).
export function deckPlaces(heights: readonly number[], expanded: boolean): DeckPlace[] {
  const front = heights[0] ?? 0;
  let above = 0;
  return heights.map((height, index) => {
    if (expanded) {
      const y = -above;
      above += height + DECK_GAP;
      return { y, scale: 1, height: height || undefined, hidden: false };
    }
    const step = Math.min(index, DECK_DEPTH - 1);
    return {
      y: -step * DECK_PEEK,
      scale: 1 - step * DECK_SCALE_STEP,
      height: index === 0 ? height || undefined : front || undefined,
      hidden: index >= DECK_DEPTH,
    };
  });
}

/// The deck's own height: the spread list, or the front toast and the peeks above it.
export function deckHeight(heights: readonly number[], expanded: boolean): number {
  if (heights.length === 0) return 0;
  if (expanded) return heights.reduce((sum, height) => sum + height, 0) + DECK_GAP * (heights.length - 1);
  return (heights[0] ?? 0) + DECK_PEEK * (Math.min(heights.length, DECK_DEPTH) - 1);
}

/// The longest transition on `element`, in milliseconds (0: motion off, or a test document).
function transitionMs(element: Element): number {
  const style = getComputedStyle(element);
  const times = (value: string | undefined) =>
    (value ?? "").split(",").map((part) => {
      const text = part.trim();
      const number = Number.parseFloat(text);
      if (!Number.isFinite(number)) return 0;
      return text.endsWith("ms") ? number : number * 1000;
    });
  const durations = times(style.transitionDuration);
  const delays = times(style.transitionDelay);
  return Math.max(0, ...durations.map((duration, index) => duration + (delays[index % delays.length] ?? 0)));
}

export function NoticeDeck({
  entries,
  expanded: wantsSpread,
  draw,
}: {
  entries: readonly NoticeEntry[];
  /** The pointer or focus is in the stack. */
  expanded: boolean;
  draw(entry: NoticeEntry): ReactNode;
}) {
  // Newest first: the front card is first in the DOM, so Tab reaches it first.
  const [cards, setCards] = useState<Card[]>(() =>
    [...entries].reverse().map((entry) => ({ entry, phase: "shown" as const })),
  );
  const [seen, setSeen] = useState(entries);
  const [heights, setHeights] = useState<ReadonlyMap<string, number>>(() => new Map());
  const [width, setWidth] = useState(0);
  const elements = useRef(new Map<string, HTMLElement>());
  const deck = useRef<HTMLDivElement>(null);
  const places = useRef(new Map<string, { y: number; scale: number; height: number }>());

  // Follow the queue during render, so the first frame of a change already holds its phases.
  let shown = cards;
  if (seen !== entries) {
    const live = new Map(entries.map((entry) => [entry.spec.id, entry]));
    const known = new Set(cards.map((card) => card.entry.spec.id));
    const next: Card[] = [...entries].reverse().map((entry) => {
      const id = entry.spec.id;
      const was = cards.find((card) => card.entry.spec.id === id && card.phase !== "leaving");
      return { entry, phase: was ? was.phase : known.has(id) ? "shown" : "from" };
    });
    // A card gone from the queue stays to play its exit where it was.
    for (const [index, card] of cards.entries()) {
      const id = card.entry.spec.id;
      if (live.has(id)) continue;
      next.splice(Math.min(index, next.length), 0, {
        ...card,
        phase: "leaving",
        at: card.at ?? places.current.get(id),
      });
    }
    shown = next;
    setCards(next);
    setSeen(entries);
  }

  const drop = useCallback((id: string) => {
    places.current.delete(id);
    setCards((current) => current.filter((card) => !(card.entry.spec.id === id && card.phase === "leaving")));
  }, []);

  // Natural heights, read once per change of the cards or of the deck's width.
  useLayoutEffect(() => {
    const measured = new Map<string, number>();
    for (const card of shown) {
      if (card.phase === "leaving") continue;
      const element = elements.current.get(card.entry.spec.id);
      if (!element) continue;
      element.style.setProperty("--ui-notice-deck-card-h", "auto");
      // offsetHeight: the layout height, which the card's scale leaves alone.
      measured.set(card.entry.spec.id, (element.firstElementChild as HTMLElement | null)?.offsetHeight ?? 0);
      element.style.removeProperty("--ui-notice-deck-card-h");
    }
    setHeights((current) => {
      if (current.size === measured.size && [...measured].every(([id, height]) => current.get(id) === height))
        return current;
      return measured;
    });
  }, [shown, width]);

  useLayoutEffect(() => {
    const element = deck.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.round(entry?.contentRect.width ?? 0)));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // A new card's start must be drawn before it moves to its place, or no transition runs.
  useLayoutEffect(() => {
    const arriving = shown.filter((card) => card.phase === "from");
    if (arriving.length === 0) return;
    for (const card of arriving) {
      const element = elements.current.get(card.entry.spec.id);
      if (element) void getComputedStyle(element).transform;
    }
    setCards((current) => current.map((card) => (card.phase === "from" ? { ...card, phase: "shown" } : card)));
  }, [shown]);

  // A leaving card goes when its exit ends; at once when no transition runs (motion off).
  useLayoutEffect(() => {
    const leaving = shown.filter((card) => card.phase === "leaving");
    if (leaving.length === 0) return;
    const timers: ReturnType<typeof setTimeout>[] = [];
    for (const card of leaving) {
      const id = card.entry.spec.id;
      const element = elements.current.get(id);
      const ms = element ? transitionMs(element) : 0;
      if (ms <= 0) drop(id);
      // wakeup-allow: one fallback per leaving toast, cleared when the deck changes or unmounts
      else timers.push(setTimeout(() => drop(id), ms + EXIT_FALLBACK_MS));
    }
    return () => timers.forEach(clearTimeout);
  }, [shown, drop]);

  const staying = shown.filter((card) => card.phase !== "leaving");
  const spread = wantsSpread && staying.length > 1;
  const sizes = staying.map((card) => heights.get(card.entry.spec.id) ?? 0);
  const placed = deckPlaces(sizes, spread);
  const height = deckHeight(sizes, spread);
  let order = 0;

  return (
    <div
      ref={deck}
      className="ui-notice-deck"
      data-expanded={spread ? "" : undefined}
      style={{ "--ui-notice-deck-h": `${height}px` } as CSSProperties}
    >
      <ol className="ui-notice-deck-cards">
        {shown.map((card) => {
          const id = card.entry.spec.id;
          const leaving = card.phase === "leaving";
          const index = leaving ? -1 : order++;
          const place = leaving
            ? (card.at ?? { y: 0, scale: 1, height: 0 })
            : { ...placed[index]!, height: placed[index]!.height ?? 0 };
          if (!leaving) places.current.set(id, { y: place.y, scale: place.scale, height: place.height });
          const style = {
            "--ui-notice-deck-y": `${place.y}px`,
            "--ui-notice-deck-scale": String(place.scale),
            ...(place.height ? { "--ui-notice-deck-card-h": `${place.height}px` } : {}),
            zIndex: leaving ? 0 : shown.length - index,
          } as CSSProperties;
          return (
            <li
              key={id}
              ref={(element) => {
                if (element) elements.current.set(id, element);
                else elements.current.delete(id);
              }}
              className="ui-notice-deck-card"
              data-phase={card.phase}
              data-front={index === 0 ? "" : undefined}
              data-hidden={!leaving && placed[index]!.hidden ? "" : undefined}
              aria-hidden={leaving ? true : undefined}
              inert={leaving}
              style={style}
              onTransitionEnd={(event) => {
                if (leaving && event.target === event.currentTarget) drop(id);
              }}
            >
              {draw(card.entry)}
            </li>
          );
        })}
      </ol>
    </div>
  );
}
