// A CSS animation or transition that starts outside the view is drawn at its end
// (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1: "inside the view only").
//
// Leo, 2026-11-22: "your chat folds or whatever, i scroll down, some bullshit ABOVE folds...? and plays an
// animation!? so there's some bullshit animation where i dont expect it to be, which is horrendous."
//
// The transcript's CSS motions (a row's entrance, the streamed words' fade, the Thinking line's roll, the
// Worked for clock's roll) start from a class or a mount, whatever the view: the overscan holds up to
// four viewports of rows the reader cannot see, and each one's motion played there, half done when he
// scrolled to it. A mutation observer on the thread sees each mount and class change in the microtask
// after its commit, before the frame that would draw it: a row there that is out of the view has its
// new finite animations finished, so it is drawn once, at its end. `animationstart` and
// `transitionrun` catch what no mutation starts (a transition from an inherited value). Ambient loops
// (infinite iterations: a spinner) are left alone. WAAPI motions are not seen here; each WAAPI site
// gates itself (turnEndFold.ts).
//
// Cost: per commit that adds nodes or changes a class, one box read for the view and one per changed
// row and element; none at rest, none for a text-only change.

/// A box this far past the view's edge still counts as in it (rounding, a 1 px border).
const EDGE_PX = 1;
const ROW = ".acpmux-row";

type Box = { top: number; bottom: number; width: number; height: number };

/// Whether `box` is wholly past one of `view`'s edges. A box of no size is exempt (a line that has
/// mounted with no box yet), and so is a view of no height: a scroller that has not been laid out
/// has no view to judge against, and reading it as a sliver at the top would end motion the reader is
/// about to see.
const misses = (box: Box, view: Box) =>
  !(box.width === 0 && box.height === 0) &&
  view.height !== 0 &&
  (box.bottom <= view.top + EDGE_PX || box.top >= view.bottom - EDGE_PX);

/// Whether `element`'s box misses `scroller`'s.
export function outOfView(element: Element, scroller: Element): boolean {
  return misses(element.getBoundingClientRect(), scroller.getBoundingClientRect());
}

/// The properties a motion may have for it to be finished here: paint only. A motion that sizes or
/// places a box (a height, a padding, a margin) out of the view still moves what is in it when the
/// view is pinned to the bottom, so ending it at once would step the rows in view; those belong to
/// the anchor pass and their owners.
const PAINT = new Set([
  "opacity",
  "transform",
  "translate",
  "scale",
  "rotate",
  "clip-path",
  "filter",
  "color",
  "background-color",
  "background-position",
  "border-color",
  "box-shadow",
  "outline-color",
  "text-decoration-color",
  "fill",
  "stroke",
  "visibility",
]);
const kebab = (name: string) => name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
function paintsOnly(animation: Animation): boolean {
  const transition = (animation as Animation & { transitionProperty?: string }).transitionProperty;
  if (typeof transition === "string") return PAINT.has(transition);
  const effect = animation.effect as KeyframeEffect | null;
  const frames = effect?.getKeyframes?.() ?? [];
  for (const frame of frames)
    for (const name of Object.keys(frame))
      if (!["offset", "computedOffset", "easing", "composite"].includes(name) && !PAINT.has(kebab(name))) return false;
  return true;
}

/// Finishes each of `animations` that has a finite end, is still to play and paints only.
function finishAll(animations: readonly Animation[]): void {
  for (const animation of animations) {
    if (animation.playState === "finished" || animation.playState === "idle") continue;
    if (!paintsOnly(animation)) continue;
    const end = animation.effect?.getComputedTiming?.().endTime;
    if (end === undefined || !Number.isFinite(Number(end))) continue;
    try {
      animation.finish();
    } catch {
      // An animation that cannot finish keeps running.
    }
  }
}

/// Ends, at once, each finite CSS animation or transition that starts inside `scroller` out of its view.
/// Returns the unsubscribe.
export function endOffscreenMotion(scroller: HTMLElement | null | undefined): () => void {
  if (!scroller || typeof scroller.addEventListener !== "function") return () => {};
  const View = scroller.ownerDocument.defaultView;
  /// The rows' own CSS animations only: a WAAPI motion (a fold's clip, a glide) is its owner's to gate.
  const cssOf = (element: Element) =>
    element
      .getAnimations({ subtree: true })
      .filter(
        (animation) =>
          (View?.CSSAnimation && animation instanceof View.CSSAnimation) ||
          (View?.CSSTransition && animation instanceof View.CSSTransition),
      );
  const observer = View?.MutationObserver
    ? new View.MutationObserver((records) => {
        // Each row the commit touched, by the row's box, and each element it added or re-classed, by its
        // own box: a long row that is partly in the view still has its words below the view's edge
        // streaming in out of sight. An element's own box alone is not enough: a line that mounts with
        // no box yet (the Thinking roll) reads as in view.
        const rows = new Set<Element>();
        const changed = new Set<Element>();
        for (const record of records) {
          const nodes = record.type === "childList" ? [...record.addedNodes] : [record.target];
          for (const node of nodes) {
            if (!(node instanceof Element)) continue;
            const row = node.closest(ROW);
            if (!row || !scroller.contains(row)) continue;
            rows.add(row);
            if (node !== row) changed.add(node);
          }
        }
        if (rows.size === 0) return;
        const view = scroller.getBoundingClientRect();
        for (const row of rows) if (misses(row.getBoundingClientRect(), view)) finishAll(cssOf(row));
        for (const element of changed)
          if (element.isConnected && misses(element.getBoundingClientRect(), view)) finishAll(cssOf(element));
      })
    : undefined;
  observer?.observe(scroller, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  // What no mutation of a class started: a transition from an inherited value, and the motions a
  // `data-*` flip starts (the send entrance, a card's reveal). Judged exactly as the observer judges
  // them, by the row's box as well as the element's own: a line that has mounted with no box yet
  // reads as in view by its own box alone, and this is the only pass that sees these.
  const started = (event: Event) => {
    const target = event.target;
    if (!(target instanceof Element) || typeof target.getAnimations !== "function") return;
    const row = target.closest(ROW);
    if (!row || !scroller.contains(row)) return;
    const view = scroller.getBoundingClientRect();
    if (!misses(row.getBoundingClientRect(), view) && !misses(target.getBoundingClientRect(), view)) return;
    finishAll(cssOf(target));
  };
  scroller.addEventListener("animationstart", started, true);
  scroller.addEventListener("transitionrun", started, true);
  return () => {
    observer?.disconnect();
    scroller.removeEventListener("animationstart", started, true);
    scroller.removeEventListener("transitionrun", started, true);
  };
}
