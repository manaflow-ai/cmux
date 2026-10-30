// One collapsible for the whole transcript (Leo 2026-10-21: "it shouldnt move your scroll or
// whatever just expand the area at the bottom and you're in the same place ... these all need
// animations for expand and collpase!"). The header the reader clicked stays at the same height in
// the view while its body opens or closes under it, and the body plays the shared fold (fold.ts):
// height and opacity over `--cv-fold-duration`, easing out, at once under Reduce Motion or with the
// pane's animations off.
//
// The header stays put in one of two ways:
// - In the transcript (VirtualTranscript, App.tsx), the hook asks for a hold with a bubbling
//   `ANCHORED_COLLAPSE_EVENT`. The transcript's placement passes then move the offset by however far
//   the header moved, while the fold plays and rows settle to their drawn heights (foldAnchor.ts).
// - Anywhere else (no one answers the event), the hook moves the nearest scroller itself after each
//   layout until the fold is over.
//
// Only the reader's toggles hold. A Find reveal (useFindReveal) opens through the row's own
// disclosure setter on purpose: Find then scrolls the view to its match, and a hold would put the
// header back on every placement pass, undoing that scroll.
//
//   const collapse = useAnchoredCollapse({ open, onOpenChange: setOpen });
//   <button ref={collapse.headerRef} aria-expanded={collapse.open} onClick={collapse.toggle}>…</button>
//   {collapse.present && <div {...collapse.bodyProps}>…</div>}
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { foldMs, useFold } from "./fold";
import { ANCHORED_COLLAPSE_EVENT, FOLD_SETTLE_MS } from "./foldAnchor";
import { foldPlays } from "./transcriptView";

export { ANCHORED_COLLAPSE_EVENT };

export type AnchoredCollapseOptions = {
  /// The first state when the hook holds it (uncontrolled).
  defaultOpen?: boolean;
  /// The state, when the caller holds it (a transcript disclosure, a row's choice).
  open?: boolean;
  /// Called with each state the reader picks (both modes).
  onOpenChange?: (open: boolean) => void;
  /// Whether a change plays the fold (default: every one). A folded thought plays only the reader's
  /// toggle, not its automatic fold.
  animates?: () => boolean;
  /// Whether opening fades the body in (default: yes); false opens it at full opacity, the height
  /// alone moving, and only closing fades (fold.ts `useFold`).
  fadeIn?: boolean;
};

export type AnchoredCollapseBodyProps = {
  ref: RefObject<HTMLDivElement | null>;
  className: string;
  "data-open": "true" | "false";
  "aria-hidden"?: true;
  inert?: boolean;
};

export type AnchoredCollapse = {
  open: boolean;
  /// Draw the body: while open, and while it closes.
  present: boolean;
  toggle: () => void;
  setOpen: (open: boolean) => void;
  /// The ref for the line the reader clicks: it stays where it is drawn while the body opens or closes.
  headerRef: (node: HTMLElement | null) => void;
  /// Spread on the body's wrapper (the box the fold sizes).
  bodyProps: AnchoredCollapseBodyProps;
};

/// Asks the transcript that holds `header` to keep it where it is drawn now. True when one will.
export function holdHeader(header: HTMLElement): boolean {
  if (!header.isConnected) return false;
  // The node's own window builds the event, so a header in another document (an iframe, a test's DOM) can carry it.
  const Custom = header.ownerDocument.defaultView?.CustomEvent ?? CustomEvent;
  return !header.dispatchEvent(new Custom(ANCHORED_COLLAPSE_EVENT, { bubbles: true, cancelable: true }));
}

/// The nearest ancestor of `node` that scrolls.
function scrollerOf(node: HTMLElement): HTMLElement | undefined {
  const view = node.ownerDocument.defaultView;
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY ?? "";
    if ((overflow === "auto" || overflow === "scroll") && at.scrollHeight > at.clientHeight) return at;
  }
  const root = node.ownerDocument.scrollingElement;
  // The node's own window's HTMLElement: a test's DOM (or another document) installs no global one.
  return view && root instanceof view.HTMLElement ? root : undefined;
}

/// Keeps `header` where it is drawn now with no transcript to hold it: returns what to call once the
/// change is laid out, which moves the nearest scroller by however far the header moved, then again
/// on each frame until the fold is over. That call returns the stop: a later toggle or an unmount
/// cancels the loop, so two corrections never add up.
function keepHeader(header: HTMLElement): () => () => void {
  const top = header.getBoundingClientRect().top;
  const view = header.ownerDocument.defaultView;
  return () => {
    const scroller = scrollerOf(header);
    if (!scroller) return () => {};
    const until = performance.now() + foldMs(header) + FOLD_SETTLE_MS;
    let frame: number | undefined;
    const correct = () => {
      frame = undefined;
      if (!header.isConnected) return;
      const moved = header.getBoundingClientRect().top - top;
      if (Math.abs(moved) >= 0.5) scroller.scrollTop += moved;
      if (performance.now() < until) frame = view?.requestAnimationFrame(correct);
    };
    correct();
    return () => {
      if (frame !== undefined) view?.cancelAnimationFrame(frame);
      frame = undefined;
    };
  };
}

export function useAnchoredCollapse(options: AnchoredCollapseOptions = {}): AnchoredCollapse {
  const [inner, setInner] = useState(options.defaultOpen ?? false);
  const controlled = options.open !== undefined;
  const open = controlled ? options.open! : inner;
  // A transcript view switch (transcriptView.ts) opens and closes the rows on screen at once: they snap.
  const fold = useFold(open, options.animates ?? foldPlays, options.fadeIn ?? true);
  const header = useRef<HTMLElement | null>(null);
  const headerRef = useCallback((node: HTMLElement | null) => {
    header.current = node;
  }, []);
  // Read when the reader toggles, so `setOpen` and `toggle` stay the same function across renders.
  const latest = useRef({ open, controlled, onOpenChange: options.onOpenChange });
  latest.current = { open, controlled, onOpenChange: options.onOpenChange };
  const pendingKeep = useRef<(() => () => void) | undefined>(undefined);
  // The running fallback correction (no transcript listening), stopped by the next toggle and on unmount.
  const keeping = useRef<(() => void) | undefined>(undefined);
  const stopKeeping = useCallback(() => {
    keeping.current?.();
    keeping.current = undefined;
  }, []);
  const setOpen = useCallback(
    (next: boolean) => {
      const { open: now, controlled: held, onOpenChange } = latest.current;
      if (next === now) return;
      stopKeeping();
      const line = header.current;
      // Measured after the previous correction stopped, so the new one starts from where the header is drawn.
      if (line && !holdHeader(line)) pendingKeep.current = keepHeader(line);
      if (!held) setInner(next);
      onOpenChange?.(next);
    },
    [stopKeeping],
  );
  const toggle = useCallback(() => setOpen(!latest.current.open), [setOpen]);
  useLayoutEffect(() => {
    const keep = pendingKeep.current;
    pendingKeep.current = undefined;
    if (keep) keeping.current = keep();
  }, [open]);
  useEffect(() => stopKeeping, [stopKeeping]);
  return {
    open,
    present: fold.present,
    toggle,
    setOpen,
    headerRef,
    bodyProps: {
      ref: fold.ref,
      className: "cv-fold cv-anchored-collapse",
      "data-open": open ? "true" : "false",
      "aria-hidden": open ? undefined : true,
      inert: open ? undefined : true,
    },
  };
}
