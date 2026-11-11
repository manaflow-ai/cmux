// A hover card's open and close (ui/hoverIntent.ts): it opens after the card dwell on hover, at
// once on keyboard focus, and closes after a short grace unless the pointer or the keyboard focus
// moved into the card, or a menu the card opened (Open in) is still open. Every link's card shares
// it (LinkHoverCard.tsx): reply links, pull request chips and the pull request bars. A wheel or
// touchpad scroll puts the card away at once, and a link sliding under a still pointer opens
// nothing until the pointer moves on it (ui/scrollHover.ts).
import { useCallback, useEffect, useRef, useState, type FocusEvent, type PointerEvent } from "react";
import { HOVER_INTENT, HoverBridge, type Point } from "../../../ui/hoverIntent";
import {
  movedFrom,
  onWheel,
  pointerPlace,
  slidUnderStillPointer,
  trackPointerRest,
  type PointerPlace,
} from "../../../ui/scrollHover";
import { focusRingShown } from "../../../ui/focusModality";

export type HoverCard = ReturnType<typeof useHoverCard>;

let nextBridgeId = 0;
type Rect = { left: number; top: number; right: number; bottom: number };
type PointerBridgeListener = (point: Point) => void;
const activePointerBridges = new Set<PointerBridgeListener>();
let removePointerBridgeListener: (() => void) | undefined;

function watchPointerBridge(listener: PointerBridgeListener): () => void {
  activePointerBridges.add(listener);
  if (!removePointerBridgeListener && typeof document !== "undefined") {
    const onMove = (event: globalThis.PointerEvent) => {
      const point = { x: event.clientX, y: event.clientY };
      for (const active of activePointerBridges) active(point);
    };
    document.addEventListener("pointermove", onMove, true);
    removePointerBridgeListener = () => {
      document.removeEventListener("pointermove", onMove, true);
      removePointerBridgeListener = undefined;
    };
  }
  return () => {
    activePointerBridges.delete(listener);
    if (activePointerBridges.size === 0) removePointerBridgeListener?.();
  };
}

/// `dwell`: the pointer rest before it opens (the hover-card dwell; an icon-only control whose
/// card replaces its tooltip waits the tooltip delay).
export function useHoverCard(dwell: number = HOVER_INTENT.cardDwell) {
  const [open, setOpen] = useState(false);
  /// The card's Open in menu is open: the card stays until it closes.
  const menuOpen = useRef(false);
  const trigger = useRef<HTMLElement | null>(null);
  /// What to start when the pointer first arrives on the trigger, before the dwell: the card's own
  /// data (a pull request card's read, LinkHoverCard.tsx), so it opens filled. Focus opens the card
  /// at once, and the card asks for itself then.
  const intent = useRef<(() => void) | undefined>(undefined);
  const unwatch = useRef<(() => void) | undefined>(undefined);
  const bridgeId = useRef(0);
  bridgeId.current ||= ++nextBridgeId;
  const bridge = useRef<HoverBridge | null>(null);
  /// The pointer is on the trigger, from pointer enter to leave.
  const onTrigger = useRef(false);
  /// The trigger came under a still pointer (a scroll, a layout change), or a scroll put its card
  /// away with the pointer on it: the card waits for the pointer to move from this place.
  const parked = useRef<PointerPlace | null>(null);
  bridge.current ??= new HoverBridge({
    dwell,
    grace: HOVER_INTENT.cardGrace,
    open: () => setOpen(true),
    close: () => {
      stopWatching();
      if (!menuOpen.current) setOpen(false);
    },
  });

  const point = (event: PointerEvent<HTMLElement>): Point => ({ x: event.clientX, y: event.clientY });
  const rect = (element: Element | null): Rect | undefined => {
    if (!element) return undefined;
    const box = element.getBoundingClientRect();
    return { left: box.left, top: box.top, right: box.right, bottom: box.bottom };
  };
  const cardElement = () =>
    typeof document === "undefined"
      ? null
      : (document
          .querySelector<HTMLElement>(`[data-cmux-hover-bridge="${bridgeId.current}"]`)
          ?.closest<HTMLElement>(".ui-tooltip") ?? null);
  const refresh = () => bridge.current?.update({ trigger: rect(trigger.current), card: rect(cardElement()) });
  const watch = () => {
    if (unwatch.current) return;
    unwatch.current = watchPointerBridge((point) => {
      refresh();
      bridge.current?.move(point);
    });
  };
  const stopWatching = () => {
    unwatch.current?.();
    unwatch.current = undefined;
  };
  const move = (event: PointerEvent<HTMLElement>) => {
    const still = parked.current;
    if (still) {
      if (!movedFrom(still, event)) return;
      // The pointer itself moved on the trigger: the normal dwell starts here. Not through `enter`:
      // the document's capture listener has already put this move's place in `last`, so the slide
      // check would read it as still and park it again on every move (review of #40035, F1).
      parked.current = null;
      start("trigger", event);
      return;
    }
    refresh();
    bridge.current?.move(point(event));
  };
  const enter = (region: "trigger" | "card", event: PointerEvent<HTMLElement>, immediate = false) => {
    if (region === "trigger") {
      trigger.current = event.currentTarget;
      onTrigger.current = true;
      if (!immediate && slidUnderStillPointer(event)) {
        parked.current = { x: event.clientX, y: event.clientY };
        return;
      }
    }
    start(region, event, immediate);
  };
  /// Hover intent on `region`, past the slide check: the trigger's data starts, and the dwell.
  const start = (region: "trigger" | "card", event: PointerEvent<HTMLElement>, immediate = false) => {
    if (region === "trigger") {
      trigger.current = event.currentTarget;
      onTrigger.current = true;
      parked.current = null;
      intent.current?.();
    }
    watch();
    refresh();
    bridge.current?.enter(
      region,
      region === "trigger" ? rect(event.currentTarget) : rect(cardElement()),
      point(event),
      immediate,
    );
  };
  const leave = (region: "trigger" | "card", event?: PointerEvent<HTMLElement>) => {
    if (region === "trigger" && event) {
      onTrigger.current = false;
      parked.current = null;
    }
    refresh();
    bridge.current?.leave(
      region,
      region === "trigger" ? rect(event?.currentTarget ?? trigger.current) : rect(cardElement()),
      event ? point(event) : undefined,
    );
    if (!bridge.current?.open && region === "trigger") stopWatching();
  };

  // The portal gap has no React owner. One shared document listener fans pointer moves to active
  // bridges; each bridge's one timer owns the delayed close/stop condition.
  useEffect(
    () => () => {
      stopWatching();
      bridge.current?.stop();
    },
    [],
  );

  // A wheel or touchpad scroll, momentum included, puts the card (or its pending dwell) away at
  // once; one inside the card itself keeps it. With the pointer still on the trigger, the card waits
  // for the pointer to move again.
  useEffect(() => {
    trackPointerRest();
    return onWheel((target) => {
      const state = bridge.current;
      // Most chips have nothing open and no pointer: they skip the card lookup.
      if (!state || menuOpen.current || !(state.open || onTrigger.current)) return;
      if (target instanceof Node && cardElement()?.contains(target)) return;
      if (onTrigger.current && !parked.current) parked.current = pointerPlace() ?? { x: NaN, y: NaN };
      stopWatching();
      state.stop();
      setOpen(false);
    });
  }, []);

  // Stable across renders, so a caller's Escape listener can depend on it.
  const dismiss = useCallback(() => {
    stopWatching();
    bridge.current?.stop();
    setOpen(false);
  }, []);

  return {
    open,
    /// For the element the card describes.
    trigger: {
      onPointerEnter: (event: PointerEvent<HTMLElement>) => enter("trigger", event),
      onPointerMove: move,
      onPointerLeave: (event: PointerEvent<HTMLElement>) => leave("trigger", event),
      onFocus: (event: FocusEvent<HTMLElement>) => {
        trigger.current = event.currentTarget;
        watch();
        refresh();
        bridge.current?.enter("trigger", rect(event.currentTarget), undefined, true);
      },
      onBlur: () => leave("trigger"),
    },
    /// For the card's content: the pointer or the keyboard focus inside keeps the card open.
    card: {
      "data-cmux-hover-bridge": bridgeId.current,
      onPointerEnter: (event: PointerEvent<HTMLElement>) => enter("card", event),
      onPointerMove: move,
      onPointerLeave: (event: PointerEvent<HTMLElement>) => leave("card", event),
      onFocusCapture: (event: FocusEvent<HTMLElement>) => {
        // Keyboard focus keeps the card. A pointer pick in Open in puts focus back on its trigger
        // with no ring (Menu's focusAfterClose); that alone doesn't pin the card once the pointer
        // has left it.
        if (!focusRingShown(event.target as Element) && !event.currentTarget.matches(":hover")) return;
        watch();
        refresh();
        bridge.current?.enter("card", rect(cardElement()), undefined, true);
      },
      onBlurCapture: () => leave("card"),
    },
    /// Closes the card now (Escape), however it opened; the next hover or focus opens it again.
    dismiss,
    /// Set by the card's content: called on hover intent, before the card opens.
    intent,
    /// The card's Open in menu opened or closed.
    menuChanged: (next: boolean) => {
      menuOpen.current = next;
      if (next) bridge.current?.hold();
      else bridge.current?.release();
    },
  };
}
