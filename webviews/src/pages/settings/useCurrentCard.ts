import { useCallback, useEffect, useRef, useState, type RefObject } from "react";

/** How far below the jump bar's bottom edge a card's top may sit and still be current, so the
 * card a jump lands on (its scroll margin puts it just below the bar) is the current one. */
const SLACK = 32;

/** The keys that scroll the page: one of them ends a jump's pin, like a wheel or a touch. */
const SCROLL_KEYS = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "]);

/** The least scroll each card at the end of a page gets as current, when the page has no tail
 * room yet (makeTailRoom gives it room on the next frame). */
const TAIL_STEP = 48;

export type CardSpot = {
  /** The cards, in page order. */
  ids: readonly string[];
  /** Each card's top, in the same coordinates as `line`. */
  tops: ReadonlyMap<string, number>;
  /** The reading line: just under the jump bar. */
  line: number;
  scrollTop: number;
  /** The most the scroll area scrolls (scrollHeight less clientHeight). */
  maxScroll: number;
};

/**
 * The current card. Each card has a scroll position where it becomes current: where its top
 * reaches the reading line. The cards at the end of a page that never reach the line (the page
 * bottoms out first) take the last TAIL_STEP of scroll each, the last card at the very end; when
 * the page is too short for that, they share what is left after the last card that does reach
 * the line, evenly. So each becomes current in turn and the last is current at the end. The current card is the last whose position the scroll has passed, or
 * the first while none has.
 */
export function currentCard({ ids, tops, line, scrollTop, maxScroll }: CardSpot): string | null {
  if (ids.length === 0) return null;
  const at = ids.map((id) => scrollTop + (tops.get(id) ?? Infinity) - line);
  if (maxScroll > 0) {
    let reach = 0;
    at.forEach((spot, index) => {
      if (spot <= maxScroll) reach = index;
    });
    const tail = ids.length - 1 - reach;
    if (tail > 0) {
      const floor = reach > 0 ? at[reach - 1]! + 1 : 0;
      // The last reachable card moves earlier only when the end cards need its room.
      const start = Math.max(floor, Math.min(at[reach]!, maxScroll - tail * TAIL_STEP));
      at[reach] = start;
      const step = Math.min(TAIL_STEP, (maxScroll - start) / tail);
      for (let index = 1; index <= tail; index++) at[reach + index] = maxScroll - (tail - index) * step;
    }
  }
  // A scroll area at its end can stop a fraction short of maxScroll: that is the end.
  const scrolled = scrollTop >= maxScroll - 1 ? Math.max(scrollTop, maxScroll) : scrollTop;
  let found = 0;
  at.forEach((spot, index) => {
    if (spot <= scrolled) found = index;
  });
  return ids[found]!;
}

/**
 * The card the reader is in (currentCard), and `pin`, for a jump: the card it names stays current
 * until the person scrolls on their own (wheel, touch, a scrolling key, or a press in the scroll area), so
 * a jump to a short card near the end, which cannot scroll to the top, still marks that card. It
 * measures on the scroll area's scroll, at most once a frame, so a jump that skips cards still
 * marks the one it lands on. It reads `[data-group]` cards inside `root`; the scroll area is
 * root's nearest scrolling ancestor.
 */
export function useCurrentCard(
  root: RefObject<HTMLElement | null>,
  ids: readonly string[],
  /** The data attribute that names each card: `[data-group]` cards, or Personalization's
   * `[data-part]` parts. */
  attr: "group" | "part" = "group",
): [current: string | null, pin: (id: string) => void] {
  const [current, setCurrent] = useState<string | null>(ids[0] ?? null);
  const pinned = useRef<string | null>(null);
  const pin = useCallback((id: string) => {
    pinned.current = id;
    setCurrent(id);
  }, []);
  const key = ids.join("\n");
  useEffect(() => {
    const host = root.current;
    if (!host || ids.length === 0) return;
    const scroller = scrollParent(host);
    let frame = 0;
    const measure = () => {
      frame = 0;
      if (scroller) makeTailRoom(host, scroller, ids.at(-1)!, attr);
      if (pinned.current) return setCurrent(pinned.current);
      const bar = host.querySelector<HTMLElement>("[data-jump-bar]");
      const tops = new Map<string, number>();
      for (const card of host.querySelectorAll<HTMLElement>(`[data-${attr}]`)) {
        const id = card.dataset[attr]!;
        if (!tops.has(id)) tops.set(id, card.getBoundingClientRect().top);
      }
      setCurrent(
        currentCard({
          ids,
          tops,
          line: readingLine(bar, scroller),
          scrollTop: scroller?.scrollTop ?? window.scrollY,
          maxScroll: scroller
            ? scroller.scrollHeight - scroller.clientHeight
            : document.documentElement.scrollHeight - window.innerHeight,
        }),
      );
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    // The person's own scroll ends a jump's pin; the jump's own scroll does not.
    const unpin = () => {
      pinned.current = null;
    };
    const unpinOnScrollKey = (event: KeyboardEvent) => {
      if (SCROLL_KEYS.has(event.key)) unpin();
    };
    measure();
    // A resize, or a card that grows or shrinks, moves the cards without a scroll.
    const resizes = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(onScroll);
    resizes?.observe(host);
    if (scroller) resizes?.observe(scroller);
    const target: HTMLElement | Window = scroller ?? window;
    target.addEventListener("scroll", onScroll, { passive: true });
    // Each listener added here is removed in the cleanup below, one call each.
    target.addEventListener("wheel", unpin, { passive: true });
    target.addEventListener("touchmove", unpin, { passive: true });
    target.addEventListener("pointerdown", unpin, { passive: true });
    window.addEventListener("keydown", unpinOnScrollKey);
    return () => {
      target.removeEventListener("scroll", onScroll);
      target.removeEventListener("wheel", unpin);
      target.removeEventListener("touchmove", unpin);
      target.removeEventListener("pointerdown", unpin);
      window.removeEventListener("keydown", unpinOnScrollKey);
      resizes?.disconnect();
      if (frame) cancelAnimationFrame(frame);
      host.style.removeProperty(TAIL_ROOM);
    };
    // `key` stands for `ids`: a new array of the same cards keeps the listener.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [root, key, attr]);
  return [current, pin];
}

/** The room under a page's cards (layout.css `.section`, `.personalization`), so its last card can
 * scroll up to the bar. */
const TAIL_ROOM = "--jump-tail";

/**
 * Gives the page just enough room under its last card that the card scrolls up to where a jump
 * lands it, under the bar, and no more: none on a page whose end already reaches. Then the short
 * cards at the end of a page each become current at their own place, spaced by their own height,
 * as every other card does, instead of all in the last bit of scroll. It sets the room only when
 * it changes, so the page's height settles after one pass.
 */
function makeTailRoom(host: HTMLElement, scroller: HTMLElement, lastId: string, attr: "group" | "part") {
  const last = [...host.querySelectorAll<HTMLElement>(`[data-${attr}]`)].find((card) => card.dataset[attr] === lastId);
  if (!last) return;
  const had = parseFloat(host.style.getPropertyValue(TAIL_ROOM)) || 0;
  const landing =
    scroller.getBoundingClientRect().top +
    (parseFloat(getComputedStyle(scroller).scrollPaddingTop) || 0) +
    (parseFloat(getComputedStyle(last).scrollMarginTop) || 0);
  // The scroll that lands the last card, and the most the page scrolls without the room.
  const lands = scroller.scrollTop + last.getBoundingClientRect().top - landing;
  const reach = scroller.scrollHeight - scroller.clientHeight - had;
  const room = Math.max(0, Math.ceil(lands - reach));
  if (Math.abs(room - had) > 1) host.style.setProperty(TAIL_ROOM, `${room}px`);
}

/**
 * The reading line, in viewport coordinates: SLACK under where the jump bar's bottom sits once it
 * is pinned (the scroll area's top, its top padding, the bar's sticky top and its height). It is
 * where the pinned bar sits even before the bar pins, so a card's spot on the scroll stays put.
 */
function readingLine(bar: HTMLElement | null, scroller: HTMLElement | null): number {
  const top = scroller
    ? scroller.getBoundingClientRect().top + (parseFloat(getComputedStyle(scroller).paddingTop) || 0)
    : 0;
  if (!bar) return top + SLACK;
  return top + (parseFloat(getComputedStyle(bar).top) || 0) + bar.getBoundingClientRect().height + SLACK;
}

function scrollParent(node: HTMLElement): HTMLElement | null {
  for (let parent = node.parentElement; parent; parent = parent.parentElement) {
    const overflow = getComputedStyle(parent).overflowY;
    if (overflow === "auto" || overflow === "scroll") return parent;
  }
  return null;
}
