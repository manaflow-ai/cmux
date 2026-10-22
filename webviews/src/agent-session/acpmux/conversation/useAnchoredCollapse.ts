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
//   const collapse = useAnchoredCollapse({ open, onOpenChange: setOpen });
//   <button ref={collapse.headerRef} aria-expanded={collapse.open} onClick={collapse.toggle}>…</button>
//   {collapse.present && <div {...collapse.bodyProps}>…</div>}
import { useCallback, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { foldMs, useFold } from "./fold";
import { ANCHORED_COLLAPSE_EVENT, FOLD_SETTLE_MS } from "./foldAnchor";

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
  return !header.dispatchEvent(new CustomEvent(ANCHORED_COLLAPSE_EVENT, { bubbles: true, cancelable: true }));
}

/// The nearest ancestor of `node` that scrolls.
function scrollerOf(node: HTMLElement): HTMLElement | undefined {
  const view = node.ownerDocument.defaultView;
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY ?? "";
    if ((overflow === "auto" || overflow === "scroll") && at.scrollHeight > at.clientHeight) return at;
  }
  const root = node.ownerDocument.scrollingElement;
  return root instanceof HTMLElement ? root : undefined;
}

/// Keeps `header` where it is drawn now with no transcript to hold it: returns what to call once the
/// change is laid out, which moves the nearest scroller by however far the header moved, then again
/// on each frame until the fold is over.
function keepHeader(header: HTMLElement): () => void {
  const top = header.getBoundingClientRect().top;
  const view = header.ownerDocument.defaultView;
  return () => {
    const scroller = scrollerOf(header);
    if (!scroller) return;
    const until = performance.now() + foldMs(header) + FOLD_SETTLE_MS;
    const correct = () => {
      if (!header.isConnected) return;
      const moved = header.getBoundingClientRect().top - top;
      if (Math.abs(moved) >= 0.5) scroller.scrollTop += moved;
      if (performance.now() < until) view?.requestAnimationFrame(correct);
    };
    correct();
  };
}

const always = () => true;

export function useAnchoredCollapse(options: AnchoredCollapseOptions = {}): AnchoredCollapse {
  const [inner, setInner] = useState(options.defaultOpen ?? false);
  const controlled = options.open !== undefined;
  const open = controlled ? options.open! : inner;
  const fold = useFold(open, options.animates ?? always);
  const header = useRef<HTMLElement | null>(null);
  const headerRef = useCallback((node: HTMLElement | null) => {
    header.current = node;
  }, []);
  // Read when the reader toggles, so `setOpen` and `toggle` stay the same function across renders.
  const latest = useRef({ open, controlled, onOpenChange: options.onOpenChange });
  latest.current = { open, controlled, onOpenChange: options.onOpenChange };
  const pendingKeep = useRef<(() => void) | undefined>(undefined);
  const setOpen = useCallback((next: boolean) => {
    const { open: now, controlled: held, onOpenChange } = latest.current;
    if (next === now) return;
    const line = header.current;
    if (line && !holdHeader(line)) pendingKeep.current = keepHeader(line);
    if (!held) setInner(next);
    onOpenChange?.(next);
  }, []);
  const toggle = useCallback(() => setOpen(!latest.current.open), [setOpen]);
  useLayoutEffect(() => {
    const keep = pendingKeep.current;
    pendingKeep.current = undefined;
    keep?.();
  }, [open]);
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
