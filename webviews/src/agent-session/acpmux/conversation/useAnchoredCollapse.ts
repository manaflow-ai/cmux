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
  /// Opens or closes it. Given the click (a row's `onClick`), only a deliberate one (`deliberateClick`).
  /// True when it did: a wrapper that does more on a click (notes it, moves focus) does it only then.
  toggle: (event?: unknown) => boolean;
  /// Whether `event` is a deliberate click (`deliberateClick`), using up the header's press as
  /// `toggle` does: for a row that acts on the click later (it waits on a read, then `setOpen`).
  deliberate: (event?: unknown) => boolean;
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

/// What a block's open held (`holdBlock`) and the offset it was clicked at, so its close holds the same.
export type BlockHold = { current: { held: "block" | "control"; at: number } | undefined };

/// Asks the transcript to hold a line for a toggle that sits under or inside the block it opens (Show
/// more, a text file's card), so that an open then a close put the view back where it started however
/// often the reader does it (Leo, 2026-11-08: "it's not an— what is it? idempotent action ... there's
/// the drift"). Holding the block's top to open and the control to close, as Show more did since
/// #24050 and the paste card since #36303, moved the view down by what opened on every round trip.
/// - Opening holds the block's top, so it grows below it (Leo, 2026-10-21: "just expand the area at
///   the bottom and you're in the same place").
/// - Closing with the view where the open left it holds the same line, so the pair is exact.
/// - Closing after the reader scrolled (to a Show less under a long block) holds the block's top if
///   it is in the view, else the control where the reader clicked it.
/// A close at the very bottom still pins the bottom (VirtualTranscript `beginBottomStackFold`).
export function holdBlock(block: HTMLElement, control: HTMLElement | null, memo: BlockHold, opening: boolean): boolean {
  const scroller = block.closest<HTMLElement>(".acpmux-scroll") ?? scrollerOf(block);
  const at = scroller?.scrollTop ?? 0;
  const opened = memo.current;
  memo.current = undefined;
  let held: "block" | "control";
  if (opening || !control) held = "block";
  else if (opened && Math.abs(opened.at - at) <= 1) held = opened.held;
  else {
    const top = scroller?.getBoundingClientRect().top ?? 0;
    held = block.getBoundingClientRect().top >= top - 0.5 ? "block" : "control";
  }
  if (opening) memo.current = { held, at };
  return holdHeader(held === "block" ? block : control!);
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

/// How far (px) the pointer may travel between press and release for the release to still be a click
/// on a line: past it the reader dragged (a selection, a scroll on a trackpad's press), and nothing
/// opens or closes (Leo, 2026-11-06: "way too jittery/sensitive").
export const CLICK_SLOP_PX = 4;

/// Where the pointer pressed a header (`useAnchoredCollapse`'s headerRef notes it).
type Press = { x: number; y: number };

/// Whether `event`, a click on `header`, is the reader's deliberate click: a keyboard click (detail
/// 0) or a call with no event always is; a pointer's is unless it travelled more than CLICK_SLOP_PX
/// from where it pressed, or left a selection inside the line (a drag or a double-click that selects
/// its words), so neither a small drag nor a selection toggles the row. A selection elsewhere that
/// only spans the line (an older one the click did not clear) never blocks it.
export function deliberateClick(event: unknown, header: HTMLElement | null, press: Press | undefined): boolean {
  const click = event as { detail?: number; clientX?: number; clientY?: number } | undefined;
  if (!click || typeof click.detail !== "number" || click.detail === 0) return true;
  if (press && typeof click.clientX === "number" && typeof click.clientY === "number") {
    if (Math.hypot(click.clientX - press.x, click.clientY - press.y) > CLICK_SLOP_PX) return false;
  }
  const selection = header?.ownerDocument.getSelection?.();
  if (header && selection && !selection.isCollapsed && selection.rangeCount > 0) {
    const range = selection.getRangeAt(0);
    if (header.contains(range.commonAncestorContainer)) return false;
  }
  return true;
}

export function useAnchoredCollapse(options: AnchoredCollapseOptions = {}): AnchoredCollapse {
  const [inner, setInner] = useState(options.defaultOpen ?? false);
  const controlled = options.open !== undefined;
  const open = controlled ? options.open! : inner;
  // A transcript view switch (transcriptView.ts) opens and closes the rows on screen at once: they snap.
  const fold = useFold(open, options.animates ?? foldPlays, options.fadeIn ?? true);
  const header = useRef<HTMLElement | null>(null);
  // Where the pointer last pressed the header, for `deliberateClick`; the listener lives as long as
  // the header is mounted. A ref reattach keeps the press: a caller's inline ref (CommandRow's) detaches
  // and reattaches at every render, and a streamed render between a press and its release must not
  // turn a drag into a click. The press holds the node it landed on and counts only while that node is
  // still the header, so a header that went (a row that draws its toggle elsewhere) leaves no stale
  // press behind. The next press replaces it, and the toggle clears it.
  const press = useRef<(Press & { on: HTMLElement }) | undefined>(undefined);
  const unlisten = useRef<(() => void) | undefined>(undefined);
  const headerRef = useCallback((node: HTMLElement | null) => {
    unlisten.current?.();
    unlisten.current = undefined;
    header.current = node;
    if (!node) return;
    const note = (event: PointerEvent) => {
      press.current = event.button === 0 ? { x: event.clientX, y: event.clientY, on: node } : undefined;
    };
    node.addEventListener("pointerdown", note, { passive: true });
    unlisten.current = () => node.removeEventListener("pointerdown", note);
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
  const deliberate = useCallback((event?: unknown) => {
    const noted = press.current;
    press.current = undefined;
    const pressed = noted && noted.on === header.current ? noted : undefined;
    return deliberateClick(event, header.current, pressed);
  }, []);
  const toggle = useCallback(
    (event?: unknown) => {
      if (!deliberate(event)) return false;
      setOpen(!latest.current.open);
      return true;
    },
    [deliberate, setOpen],
  );
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
    deliberate,
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
