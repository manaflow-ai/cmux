// The stacked layout of NoticeStack (leo-workspace design/notifications.md): a compact deck at one
// anchor. The newest toast is in front at the anchor's edge; up to two older ones peek behind it,
// each a step smaller, cut to the front one's height with their text hidden. While the pointer or
// focus is in the deck it spreads into the full list, so every toast can be read, answered or
// closed; it gathers again when they leave. A bottom deck grows upward, a top deck downward.
//
// Every change is one state transition of the whole deck (Leo, 2026-11-04: "we move all our
// affected, possibly affected elements in the cohesive way"): a new toast comes into the front from
// behind the deck's edge while the others step back in the same frames; a closed one goes back
// behind it while the rest step forward; a repeat moves to the front. The deck's box is placed
// absolutely and its height follows the toasts, so nothing under it ever moves.
//
// Drag (Leo, 2026-11-07: "get the toasts to be draggable so you can move it around if you need to
// see something"): a toast follows the pointer from a press (anchors.ts `createDrag`); its time
// stops while it is held. Released, it settles at the nearest anchor on the shared spring, flying
// from where it was dropped into that anchor's deck (`flights`, a FLIP across decks); flicked, or
// dropped past the surface's edge, it is closed and flies on out.
//
// Motion: transitions only, on the shared motion tokens; `data-cmux-motion` off or reduced, or the
// system's Reduce Motion, ends them (notice.css), and every change then lands in one frame.
//
// Measuring: each toast's natural height is read once per change of the toasts or of the deck's
// width (a ResizeObserver on the deck, disconnected on unmount), never per frame. A drag writes
// the card's offset straight to its style, so a pointer move renders nothing.
//
// Keyboard (#38090): the cards are in the document in the order they stand on screen, top to
// bottom, so Tab and Shift-Tab walk a spread deck the way the eye does: a bottom deck has its
// newest card last, a top deck first. Gathered, only the front card can be reached, and focusing it
// spreads the deck. Tab leaving the deck goes to the nearest control on screen that way
// (tabReach.ts), never to one with no box or to a transcript row drawn past the viewport's edge.
import { useCallback, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import {
  anchorPoint,
  createDrag,
  nearestAnchor,
  type Anchor,
  type Box,
  type Drag,
  type DragRelease,
  type Point,
} from "./anchors";
import type { NoticeEntry } from "./NoticeStack";
import { leaveLayerOnScreen } from "./tabReach";

export type DeckAlign = "center" | "end";
/** How a dragged toast feels: `spring` follows the pointer and settles on the spring;
 *  `rubber` lags toward the anchor it would settle at; `ghosts` is `spring` with the six
 *  anchors outlined while it is held. */
export type DragFeel = "spring" | "rubber" | "ghosts";

/** How far each older toast peeks behind the one in front, and the gap between spread toasts. */
export const DECK_PEEK = 8;
export const DECK_GAP = 8;
/** Each step back is this much smaller. */
export const DECK_SCALE_STEP = 0.05;
/** At most this many toasts show in the gathered deck; the rest wait behind. */
export const DECK_DEPTH = 3;
/** A closed toast is kept this long past its transition at most, if no transitionend comes. */
const EXIT_FALLBACK_MS = 400;
/** A flung toast travels on this many ms at its release speed, and at least FLING_MIN px. */
const FLING_MS = 200;
const FLING_MIN = 120;
/** `rubber`: how much of the way toward its anchor a held toast leans. */
const RUBBER_LEAN = 0.3;

type Phase = "from" | "fly" | "shown" | "leaving";

interface Card {
  entry: NoticeEntry;
  phase: Phase;
  /** Where a leaving card was, so it leaves from there. */
  at?: { y: number; scale: number; height: number };
}

/** Where cards dropped at another anchor were on screen, by id, until their new deck draws them. */
export type Flights = Map<string, DOMRect>;

export interface DeckDrag {
  feel: DragFeel;
  /** The surface the toasts may rest in, in client coordinates. */
  box(): Box;
  /** A toast is held (true) or let go (false): the stack's time stops while one is. */
  hold(held: boolean, nearest?: Anchor): void;
  /** Where a released toast goes. */
  release(id: string, release: Exclude<DragRelease, { kind: "click" }>): void;
}

export interface DeckPlace {
  y: number;
  scale: number;
  /** The card's drawn height: its own when spread or in front, the front's when gathered. */
  height: number | undefined;
  /** Hidden behind the visible depth. */
  hidden: boolean;
}

/// Where each toast stands, newest first, measured from the deck's edge (upward for a bottom deck,
/// so y is negative; downward for a top deck): gathered, each older one `DECK_PEEK` further in and
/// a step smaller, cut to the front one's height; spread, each beyond the newer ones with
/// `DECK_GAP` between. `heights` are the toasts' natural heights (0 when not measured yet).
export function deckPlaces(
  heights: readonly number[],
  expanded: boolean,
  edge: "top" | "bottom" = "bottom",
): DeckPlace[] {
  const sign = edge === "bottom" ? -1 : 1;
  const front = heights[0] ?? 0;
  let beyond = 0;
  return heights.map((height, index) => {
    if (expanded) {
      const y = sign * beyond || 0;
      beyond += height + DECK_GAP;
      return { y, scale: 1, height: height || undefined, hidden: false };
    }
    const step = Math.min(index, DECK_DEPTH - 1);
    return {
      y: sign * step * DECK_PEEK || 0,
      scale: 1 - step * DECK_SCALE_STEP,
      height: index === 0 ? height || undefined : front || undefined,
      hidden: index >= DECK_DEPTH,
    };
  });
}

/// The deck's own height: the spread list, or the front toast and the peeks behind it.
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

/** A press on one of these is the control's, never a drag. */
const CONTROLS = "button, a[href], input, textarea, select, label, [role='checkbox']";

function setOffset(element: HTMLElement, offset: Point | undefined): void {
  if (!offset) {
    element.style.removeProperty("--ui-notice-drag-x");
    element.style.removeProperty("--ui-notice-drag-y");
    return;
  }
  element.style.setProperty("--ui-notice-drag-x", `${offset.x}px`);
  element.style.setProperty("--ui-notice-drag-y", `${offset.y}px`);
}

export function NoticeDeck({
  entries,
  expanded: wantsSpread,
  draw,
  edge = "bottom",
  drag,
  flights,
}: {
  entries: readonly NoticeEntry[];
  /** Spread whatever the pointer does. Otherwise it spreads while the pointer or focus is in it. */
  expanded?: boolean;
  draw(entry: NoticeEntry): ReactNode;
  /** The anchor's edge the deck stands on. */
  edge?: "top" | "bottom";
  /** Without it the toasts don't drag. */
  drag?: DeckDrag;
  /** Shared by the stack's decks: a card dropped here from another deck flies in from there. */
  flights?: Flights;
}) {
  // Newest first; drawn in screen order (below).
  const [cards, setCards] = useState<Card[]>(() =>
    [...entries].reverse().map((entry) => ({ entry, phase: "shown" as const })),
  );
  const [seen, setSeen] = useState(entries);
  const [heights, setHeights] = useState<ReadonlyMap<string, number>>(() => new Map());
  const [width, setWidth] = useState(0);
  const [held, setHeld] = useState<string | undefined>(undefined);
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
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
      const fresh: Phase = flights?.has(id) ? "fly" : "from";
      return { entry, phase: was ? was.phase : known.has(id) ? "shown" : fresh };
    });
    // A card gone from the queue stays to play its exit where it was; one that went to another
    // anchor's deck is drawn there, from where it was dropped, and goes from here at once.
    for (const [index, card] of cards.entries()) {
      const id = card.entry.spec.id;
      if (live.has(id) || card.phase === "leaving" || flights?.has(id)) {
        if (card.phase === "leaving" && !live.has(id)) next.splice(Math.min(index, next.length), 0, card);
        continue;
      }
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

  // A card closed from under the pointer or focus sends no leave or blur: read the deck's real
  // state whenever the toasts change, so it never stays spread.
  useLayoutEffect(() => {
    const element = deck.current;
    if (!element) return;
    setHovered(element.matches(":hover"));
    setFocused(element.contains(document.activeElement));
  }, [entries]);

  // Tab leaving the deck lands on a control on screen (tabReach.ts). A listener, not a prop: the
  // deck is no widget of its own, only the box its cards' controls sit in.
  useLayoutEffect(() => {
    const element = deck.current;
    if (!element) return;
    const key = (event: KeyboardEvent) => leaveLayerOnScreen(element, event);
    element.addEventListener("keydown", key);
    return () => element.removeEventListener("keydown", key);
  }, []);

  // Natural heights, read once per change of the cards or of the deck's width.
  useLayoutEffect(() => {
    // Every card at its natural height first, then every read, then every restore: one layout for
    // the deck, not one per card.
    const open: [string, HTMLElement][] = [];
    for (const card of shown) {
      if (card.phase === "leaving") continue;
      const element = elements.current.get(card.entry.spec.id);
      if (element) open.push([card.entry.spec.id, element]);
    }
    for (const [, element] of open) element.style.setProperty("--ui-notice-deck-card-h", "auto");
    // offsetHeight: the layout height, which the card's scale leaves alone.
    const measured = new Map<string, number>(
      open.map(([id, element]) => [id, (element.firstElementChild as HTMLElement | null)?.offsetHeight ?? 0]),
    );
    for (const [, element] of open) element.style.removeProperty("--ui-notice-deck-card-h");
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

  // A new card's start must be drawn before it moves to its place, or no transition runs. A card
  // flown in from another deck starts where it was dropped: the difference to its new place.
  useLayoutEffect(() => {
    const arriving = shown.filter((card) => card.phase === "from" || card.phase === "fly");
    if (arriving.length === 0) return;
    // Every place is read before any start is written, then the starts are drawn together: one
    // layout for the deck, not one per card.
    const starts: { element: HTMLElement; from?: DOMRect; to?: DOMRect }[] = [];
    for (const card of arriving) {
      const id = card.entry.spec.id;
      const element = elements.current.get(id);
      const from = flights?.get(id);
      flights?.delete(id);
      if (!element) continue;
      const flying = card.phase === "fly" && from;
      starts.push(flying ? { element, from, to: element.getBoundingClientRect() } : { element });
    }
    for (const { element, from, to } of starts) {
      if (!from || !to) continue;
      element.style.setProperty("--ui-notice-fly-x", `${from.left - to.left}px`);
      element.style.setProperty("--ui-notice-fly-y", `${from.top - to.top}px`);
      // It lands on the drag's spring, as a toast let go in its own deck does.
      element.dataset.settling = "";
    }
    for (const { element } of starts) void getComputedStyle(element).transform;
    setCards((current) =>
      current.map((card) => (card.phase === "from" || card.phase === "fly" ? { ...card, phase: "shown" } : card)),
    );
  }, [shown, flights]);

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

  /// A press on a card: it follows the pointer once it moves past the slop, and on release
  /// settles, comes back, or goes.
  const press = (id: string, event: React.PointerEvent<HTMLLIElement>) => {
    if (!drag || event.button !== 0 || (event.target as Element).closest(CONTROLS)) return;
    const element = event.currentTarget;
    const start = { x: event.clientX, y: event.clientY };
    const moving: Drag = createDrag(start, event.timeStamp);
    // No text selection starts under a drag; the card's controls keep their own presses.
    event.preventDefault();
    element.setPointerCapture?.(event.pointerId);
    const origin = element.getBoundingClientRect();
    const centre = { x: origin.left + origin.width / 2, y: origin.top + origin.height / 2 };
    let nearest: Anchor | undefined;
    const shownOffset = (offset: Point, box: Box): Point => {
      if (drag.feel !== "rubber") return offset;
      const target = anchorPoint(nearestAnchor({ x: centre.x + offset.x, y: centre.y + offset.y }, box), box);
      const lean = { x: target.x - centre.x, y: target.y - centre.y };
      return { x: offset.x + (lean.x - offset.x) * RUBBER_LEAN, y: offset.y + (lean.y - offset.y) * RUBBER_LEAN };
    };
    const move = (next: PointerEvent) => {
      const offset = moving.move({ x: next.clientX, y: next.clientY }, next.timeStamp);
      if (!moving.dragging) return;
      const box = drag.box();
      if (element.dataset.dragging === undefined) {
        element.dataset.dragging = "";
        delete element.dataset.settling;
        setHeld(id);
      }
      setOffset(element, shownOffset(offset, box));
      const now = nearestAnchor({ x: next.clientX, y: next.clientY }, box);
      if (now !== nearest) {
        nearest = now;
        drag.hold(true, now);
      }
    };
    const end = (last: PointerEvent, cancelled: boolean) => {
      element.removeEventListener("pointermove", move);
      element.removeEventListener("pointerup", up);
      element.removeEventListener("pointercancel", cancel);
      const result = cancelled
        ? ({ kind: "click" } as const)
        : moving.release({ x: last.clientX, y: last.clientY }, last.timeStamp, drag.box());
      const wasDragging = element.dataset.dragging !== undefined;
      delete element.dataset.dragging;
      setHeld(undefined);
      if (!wasDragging) return;
      drag.hold(false);
      if (result.kind === "click") {
        element.dataset.settling = "";
        setOffset(element, undefined);
        return;
      }
      if (result.kind === "dismiss") {
        const speed = Math.hypot(result.velocity.x, result.velocity.y);
        const length = Math.hypot(result.offset.x, result.offset.y) || 1;
        const reach = Math.max(FLING_MIN, speed * FLING_MS);
        const direction =
          speed > 0
            ? { x: result.velocity.x / speed, y: result.velocity.y / speed }
            : { x: result.offset.x / length, y: result.offset.y / length };
        element.style.setProperty("--ui-notice-fling-x", `${direction.x * reach}px`);
        element.style.setProperty("--ui-notice-fling-y", `${direction.y * reach}px`);
        element.dataset.flung = "";
      } else {
        element.dataset.settling = "";
        // Dropped here: it springs back into its place. Elsewhere: its new deck draws it from
        // where it is now.
        flights?.set(id, element.getBoundingClientRect());
        setOffset(element, undefined);
      }
      drag.release(id, result);
    };
    const up = (last: PointerEvent) => end(last, false);
    const cancel = (last: PointerEvent) => end(last, true);
    element.addEventListener("pointermove", move);
    element.addEventListener("pointerup", up);
    element.addEventListener("pointercancel", cancel);
  };

  const staying = shown.filter((card) => card.phase !== "leaving");
  const spread = (wantsSpread || hovered || focused || held !== undefined) && staying.length > 1;
  const sizes = staying.map((card) => heights.get(card.entry.spec.id) ?? 0);
  const placed = deckPlaces(sizes, spread, edge);
  const height = deckHeight(sizes, spread);
  // The deck clips at its edge only while a card comes or goes behind it; a held or flying card is
  // never cut.
  const clips = shown.some(
    (card) =>
      card.phase === "from" ||
      (card.phase === "leaving" && elements.current.get(card.entry.spec.id)?.dataset.flung === undefined),
  );
  // Each card's place counts from the front (newest first); the document lists them as they stand on
  // screen, so Tab moves the way the eye does: a bottom deck grows upward, its newest card last.
  let order = 0;
  const ranked = shown.map((card) => ({ card, index: card.phase === "leaving" ? -1 : order++ }));
  if (edge === "bottom") ranked.reverse();

  return (
    <div
      ref={deck}
      className="ui-notice-deck"
      data-edge={edge}
      data-expanded={spread ? "" : undefined}
      data-clip={clips ? "" : undefined}
      data-held={held !== undefined ? "" : undefined}
      style={{ "--ui-notice-deck-h": `${height}px` } as CSSProperties}
      onPointerEnter={() => setHovered(true)}
      onPointerLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setFocused(false);
      }}
    >
      <ol className="ui-notice-deck-cards">
        {ranked.map(({ card, index }) => {
          const id = card.entry.spec.id;
          const leaving = card.phase === "leaving";
          const place = leaving
            ? (card.at ?? { y: 0, scale: 1, height: 0 })
            : { ...placed[index]!, height: placed[index]!.height ?? 0 };
          if (!leaving) places.current.set(id, { y: place.y, scale: place.scale, height: place.height });
          // Gathered, an older card is only a sliver behind the front one with its text faded out:
          // nothing on it can be reached by Tab or read aloud until the deck spreads (focusing the
          // front card spreads it).
          const concealed = !leaving && !spread && index > 0;
          const style = {
            "--ui-notice-deck-y": `${place.y}px`,
            "--ui-notice-deck-scale": String(place.scale),
            ...(place.height ? { "--ui-notice-deck-card-h": `${place.height}px` } : {}),
            zIndex: held === id ? shown.length + 1 : leaving ? 0 : shown.length - index,
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
              data-draggable={drag ? "" : undefined}
              aria-hidden={leaving || concealed ? true : undefined}
              inert={leaving || concealed}
              style={style}
              onPointerDown={leaving ? undefined : (event) => press(id, event)}
              onTransitionEnd={(event) => {
                if (event.target !== event.currentTarget) return;
                if (leaving) drop(id);
                else if (card.phase === "shown") {
                  event.currentTarget.style.removeProperty("--ui-notice-fly-x");
                  event.currentTarget.style.removeProperty("--ui-notice-fly-y");
                }
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
