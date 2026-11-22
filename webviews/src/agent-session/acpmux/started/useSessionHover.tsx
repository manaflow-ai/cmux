import {
  type FocusEvent,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { HOVER_INTENT, HoverGroup, useHoverIntent } from "../../../ui/hoverIntent";
import {
  movedFrom,
  onWheel,
  pointerPlace,
  slidUnderStillPointer,
  trackPointerRest,
  type PointerPlace,
} from "../../../ui/scrollHover";
import { type SessionHoverStore, useSessionHoverInfo } from "./sessionHover";
import { SESSION_HOVER_DELAY, SessionHoverContext, hoverCardSide } from "./sessionHoverCardModel";
import { SessionHoverContent } from "./SessionHoverCard";

/// One group for every reference: after one card, the next shows at once while the pointer moves on.
const group = new HoverGroup(HOVER_INTENT.cardGrace);

export type SessionHoverTrigger = {
  onPointerEnter?(event: PointerEvent<HTMLElement>): void;
  onPointerMove?(event: PointerEvent<HTMLElement>): void;
  onPointerLeave?(): void;
  onPointerDown?(): void;
  onFocus?(event: FocusEvent<HTMLElement>): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  onKeyDown?(event: KeyboardEvent<HTMLElement>): void;
  "aria-describedby"?: string;
};

const noStore = () => () => {};

/// The hover card of session `sessionId`: spread `trigger` on the reference and render `card`
/// beside it. Both are empty without a ``SessionHoverContext`` and for a chat its store does not list,
/// so a reference keeps its own tooltip there. A click on the card opens the chat with `open`, the
/// reference's own opener (a sender's name opens as a sender), else the context's. `takeOver(anchor,
/// now)` hands it a pointer or focus already on the reference (another card's, whose reference just
/// resolved to this chat): with `now`, the card shows in that card's place in the same frame, else
/// after the usual rest.
export function useSessionHover(
  sessionId: string,
  open?: (sessionId: string) => void,
): { trigger: SessionHoverTrigger; card: ReactNode; takeOver(anchor: HTMLElement, now: boolean): void } {
  const hover = useContext(SessionHoverContext);
  const readListed = () => (hover && sessionId ? hover.store.get(sessionId) !== undefined : false);
  const listed = useSyncExternalStore(hover?.store.subscribe ?? noStore, readListed, readListed);
  const intent = useHoverIntent<HTMLElement>({ delay: SESSION_HOVER_DELAY, group });
  const { hover: point, dismiss } = intent;
  const [placed, setPlaced] = useState<{ anchor: HTMLElement; side: "top" | "bottom" } | null>(null);
  // A card that took another's place is there at once, with no fade in, until it goes.
  const [swapped, setSwapped] = useState<HTMLElement | null>(null);
  const leave = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const inside = useRef<HTMLButtonElement | null>(null);
  // Escape in the card hands focus back to the reference: that focus must not show the card again.
  const returning = useRef(false);
  const cardId = useId();
  /// The pointer is on the reference, from pointer enter to leave.
  const onReference = useRef(false);
  /// The reference came under a still pointer (a scroll), or a scroll put its card away with the
  /// pointer on it: the card waits for the pointer to move from this place (ui/scrollHover.ts).
  const parked = useRef<PointerPlace | null>(null);
  const shown = useRef(false);
  // A wheel or touchpad scroll puts the card (or its wait) away at once; one inside the card keeps it.
  useEffect(() => {
    trackPointerRest();
    return onWheel((target) => {
      if (!shown.current && !onReference.current) return;
      const cardElement = inside.current?.closest(".acpmux-session-hover-card");
      if (target instanceof Node && cardElement?.contains(target)) return;
      if (onReference.current && !parked.current) parked.current = pointerPlace() ?? { x: NaN, y: NaN };
      clearTimeout(leave.current);
      leave.current = undefined;
      dismiss();
    });
  }, [dismiss]);
  useEffect(() => {
    shown.current = intent.shown !== null;
    if (intent.shown) setPlaced({ anchor: intent.shown, side: hoverCardSide(intent.shown) });
    else setSwapped(null);
  }, [intent.shown]);
  useEffect(() => () => clearTimeout(leave.current), []);
  // A chat that leaves the list takes its card and the reference's handlers with it, so no leave
  // or blur would put the card away: drop the hover now, or the chat coming back reopens it with
  // nothing on the reference (review of #36360, F1).
  useEffect(() => {
    if (listed) return;
    clearTimeout(leave.current);
    leave.current = undefined;
    point(null);
  }, [listed, point]);
  if (!hover || !listed) return { trigger: {}, card: null, takeOver: () => undefined };
  const takeOver = (anchor: HTMLElement, now: boolean) => {
    if (now) {
      // Placed with the show, in the render that puts the other card away: no frame without a card.
      setPlaced({ anchor, side: hoverCardSide(anchor) });
      setSwapped(anchor);
      point(anchor, 0);
    } else point(anchor);
  };

  const stay = () => {
    clearTimeout(leave.current);
    leave.current = undefined;
  };
  // The pointer or focus left the reference or its card: the card goes after the grace, unless
  // it comes back to either, or focus is still on one of them (the pointer drifting off a card
  // the keyboard opened).
  const go = () => {
    stay();
    leave.current = setTimeout(() => {
      leave.current = undefined;
      if (ownsFocus(document.activeElement)) return;
      point(null);
    }, HOVER_INTENT.cardGrace);
  };
  const now = () => {
    stay();
    dismiss();
  };
  const ownsFocus = (target: EventTarget | null) =>
    target instanceof Node && (inside.current?.contains(target) || placed?.anchor.contains(target));
  const trigger: SessionHoverTrigger = {
    onPointerEnter: (event) => {
      stay();
      onReference.current = true;
      // Content that scrolled under a still pointer is no hover.
      if (slidUnderStillPointer(event)) {
        parked.current = { x: event.clientX, y: event.clientY };
        return;
      }
      parked.current = null;
      if (hover.store.get(sessionId)) point(event.currentTarget);
    },
    onPointerMove: (event) => {
      const still = parked.current;
      if (!still || !movedFrom(still, event)) return;
      parked.current = null;
      if (hover.store.get(sessionId)) point(event.currentTarget);
    },
    onPointerLeave: () => {
      onReference.current = false;
      parked.current = null;
      go();
    },
    onPointerDown: now,
    onFocus: (event) => {
      stay();
      if (returning.current) {
        returning.current = false;
        return;
      }
      if (hover.store.get(sessionId)) point(event.currentTarget, 0);
    },
    onBlur: (event) => {
      if (!ownsFocus(event.relatedTarget)) go();
    },
    // ui-allow: Escape puts the card away and ArrowDown moves focus into it; Enter stays the reference's own.
    onKeyDown: (event) => {
      if (event.key === "Escape" && intent.shown) {
        event.stopPropagation();
        now();
      } else if (event.key === "ArrowDown" && intent.shown && inside.current) {
        event.preventDefault();
        inside.current.focus();
      }
    },
    ...(intent.shown ? { "aria-describedby": cardId } : {}),
  };
  const card = placed ? (
    <AnchoredCard
      id={cardId}
      anchor={placed.anchor}
      side={placed.side}
      open={intent.shown !== null}
      instant={intent.instant || (swapped !== null && swapped === intent.shown)}
      interactive
      ariaLabel={hover.store.get(sessionId)?.title}
      className="ui-glass ui-glass-floats acpmux-session-hover-card"
      onPointerEnter={stay}
      onPointerLeave={go}
    >
      <SessionHoverBody
        store={hover.store}
        sessionId={sessionId}
        buttonRef={inside}
        onOpen={() => {
          now();
          (open ?? hover.open)(sessionId);
        }}
        onEscape={() => {
          now();
          returning.current = true;
          placed.anchor.focus();
          returning.current = false;
        }}
        onBlur={(event) => {
          if (!ownsFocus(event.relatedTarget)) go();
        }}
        onFocus={stay}
      />
    </AnchoredCard>
  ) : null;
  return { trigger, card, takeOver };
}

function SessionHoverBody({
  store,
  sessionId,
  buttonRef,
  onOpen,
  onEscape,
  onBlur,
  onFocus,
}: {
  store: SessionHoverStore;
  sessionId: string;
  buttonRef: { current: HTMLButtonElement | null };
  onOpen(): void;
  onEscape(): void;
  onBlur(event: FocusEvent<HTMLElement>): void;
  onFocus(): void;
}) {
  const info = useSessionHoverInfo(store, sessionId);
  if (!info) return null;
  return (
    <SessionHoverContent
      info={info}
      buttonRef={buttonRef}
      onOpen={onOpen}
      onEscape={onEscape}
      onBlur={onBlur}
      onFocus={onFocus}
    />
  );
}

/// The card's content: the whole card is one button that opens the session.
