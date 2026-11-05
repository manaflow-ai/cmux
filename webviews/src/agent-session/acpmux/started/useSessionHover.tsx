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
} from "react";
import { AnchoredCard } from "../../../ui/Tooltip";
import { HOVER_INTENT, HoverGroup, useHoverIntent } from "../../../ui/hoverIntent";
import { type SessionHoverStore, useSessionHoverInfo } from "./sessionHover";
import { SESSION_HOVER_DELAY, SessionHoverContext, hoverCardSide } from "./sessionHoverCardModel";
import { SessionHoverContent } from "./SessionHoverCard";

/// One group for every reference: after one card, the next shows at once while the pointer moves on.
const group = new HoverGroup(HOVER_INTENT.cardGrace);

export type SessionHoverTrigger = {
  onPointerEnter?(event: PointerEvent<HTMLElement>): void;
  onPointerLeave?(): void;
  onPointerDown?(): void;
  onFocus?(event: FocusEvent<HTMLElement>): void;
  onBlur?(event: FocusEvent<HTMLElement>): void;
  onKeyDown?(event: KeyboardEvent<HTMLElement>): void;
  "aria-describedby"?: string;
};

/// The hover card of session `sessionId`: spread `trigger` on the reference and render `card`
/// beside it. Both are empty without a ``SessionHoverContext``.
export function useSessionHover(sessionId: string): { trigger: SessionHoverTrigger; card: ReactNode } {
  const hover = useContext(SessionHoverContext);
  const intent = useHoverIntent<HTMLElement>({ delay: SESSION_HOVER_DELAY, group });
  const { hover: point, dismiss } = intent;
  const [placed, setPlaced] = useState<{ anchor: HTMLElement; side: "top" | "bottom" } | null>(null);
  const leave = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const inside = useRef<HTMLButtonElement | null>(null);
  // Escape in the card hands focus back to the reference: that focus must not show the card again.
  const returning = useRef(false);
  const cardId = useId();
  useEffect(() => {
    if (intent.shown) setPlaced({ anchor: intent.shown, side: hoverCardSide(intent.shown) });
  }, [intent.shown]);
  useEffect(() => () => clearTimeout(leave.current), []);
  if (!hover) return { trigger: {}, card: null };

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
      point(event.currentTarget);
    },
    onPointerLeave: go,
    onPointerDown: now,
    onFocus: (event) => {
      stay();
      if (returning.current) {
        returning.current = false;
        return;
      }
      point(event.currentTarget, 0);
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
      instant={intent.instant}
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
          hover.open(sessionId);
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
  return { trigger, card };
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
