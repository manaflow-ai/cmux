// A hover card's open and close (ui/hoverIntent.ts): it opens after the card dwell on hover, at
// once on keyboard focus, and closes after a short grace unless the pointer or the keyboard focus
// moved into the card, or a menu the card opened (Open in) is still open. Every link's card shares
// it (LinkHoverCard.tsx): reply links, pull request chips and the pull request bars.
import { useCallback, useEffect, useRef, useState, type FocusEvent, type PointerEvent } from "react";
import { frameInput, type FrameInput } from "../../../ui/frameInput";
import { HOVER_INTENT, HoverBridge, type Point } from "../../../ui/hoverIntent";

export type HoverCard = ReturnType<typeof useHoverCard>;

let nextBridgeId = 0;
type Rect = { left: number; top: number; right: number; bottom: number };
type PointerBridgeListener = (point: Point) => void;
const activePointerBridges = new Set<PointerBridgeListener>();
let removePointerBridgeListener: (() => void) | undefined;
let pointerBridgeMoves: FrameInput<Point> | undefined;

function watchPointerBridge(listener: PointerBridgeListener): () => void {
  activePointerBridges.add(listener);
  const win = typeof document === "undefined" ? null : document.defaultView;
  if (!removePointerBridgeListener && win) {
    // Each bridge measures its trigger and card per move: once per frame, at the newest pointer
    // (ui/frameInput.ts).
    const moves = frameInput(win, (point: Point) => {
      for (const active of activePointerBridges) active(point);
    });
    const onMove = (event: globalThis.PointerEvent) => moves.push({ x: event.clientX, y: event.clientY });
    // Passive: the bridge only follows the pointer, it cancels nothing.
    document.addEventListener("pointermove", onMove, { capture: true, passive: true });
    pointerBridgeMoves = moves;
    removePointerBridgeListener = () => {
      moves.cancel();
      document.removeEventListener("pointermove", onMove, true);
      pointerBridgeMoves = undefined;
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
  const unwatch = useRef<(() => void) | undefined>(undefined);
  const bridgeId = useRef(0);
  bridgeId.current ||= ++nextBridgeId;
  const bridge = useRef<HoverBridge | null>(null);
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
    // While watching, the document listener already hands this move over at the frame.
    if (unwatch.current) return;
    refresh();
    bridge.current?.move(point(event));
  };
  const enter = (region: "trigger" | "card", event: PointerEvent<HTMLElement>, immediate = false) => {
    // A held move is older than this crossing: it goes first, as in the browser.
    pointerBridgeMoves?.flush();
    if (region === "trigger") trigger.current = event.currentTarget;
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
    pointerBridgeMoves?.flush();
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
        if (!(event.target as Element).matches(":focus-visible") && !event.currentTarget.matches(":hover")) return;
        watch();
        refresh();
        bridge.current?.enter("card", rect(cardElement()), undefined, true);
      },
      onBlurCapture: () => leave("card"),
    },
    /// Closes the card now (Escape), however it opened; the next hover or focus opens it again.
    dismiss,
    /// The card's Open in menu opened or closed.
    menuChanged: (next: boolean) => {
      menuOpen.current = next;
      if (next) bridge.current?.hold();
      else bridge.current?.release();
    },
  };
}
