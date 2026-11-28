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
// after its commit and judges them in the next frame's animation callbacks, before that frame draws them:
// a row there that is out of the view has its new finite animations finished, so it is drawn once, at its end. `animationstart` and
// `transitionrun` catch what no mutation starts (a transition from an inherited value). Ambient loops
// (infinite iterations: a spinner) are left alone. WAAPI motions are not seen here; each WAAPI site
// gates itself (turnEndFold.ts).
//
// Cost: per frame whose commits added nodes or changed a class, nothing for a row an intersection observer
// last saw wholly in the view (the streaming reply, the live line); else a read of each changed row's and
// element's motions (one style and layout pass for the frame, which it would run anyway), and a box read
// for the view and one per row or element that has a motion to end. None at rest, none for a text-only
// change. Read in each mutation's microtask, as this once was, each read was a forced pass after React's
// writes: each streamed token of a reply in view paid one (0.65 to 1.3 ms a token,
// bench/transcript-replay.bench.ts PROFILE=1), and a fling paid 12 a frame at 100k rows.

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

/// Whether `animation` has a finite end, is still to play and paints only: one this module ends.
function finishable(animation: Animation): boolean {
  if (animation.playState === "finished" || animation.playState === "idle") return false;
  if (!paintsOnly(animation)) return false;
  const end = animation.effect?.getComputedTiming?.().endTime;
  return end !== undefined && Number.isFinite(Number(end));
}

/// Finishes each of `animations` that `finishable` names.
function finishAll(animations: readonly Animation[]): void {
  for (const animation of animations) {
    if (!finishable(animation)) continue;
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
  // The rows wholly in the view as the browser last laid them out (an intersection observer, told in
  // the frame's own layout, never a forced one): every element of such a row is in the view too, so a
  // mutation or a motion's start in it needs no box read. A row it has not reported yet, or that the
  // view cuts, is read as before. A row that grows past the view's edge is told so in the next frame.
  const whole = new WeakSet<Element>();
  const seen = View?.IntersectionObserver
    ? new View.IntersectionObserver(
        (entries) => {
          for (const entry of entries)
            if (entry.isIntersecting && entry.intersectionRatio >= 1) whole.add(entry.target);
            else whole.delete(entry.target);
        },
        { root: scroller, rootMargin: `${EDGE_PX}px`, threshold: [0, 1] },
      )
    : undefined;
  const watched = new WeakSet<Element>();
  const watch = (row: Element) => {
    if (!seen || watched.has(row)) return;
    watched.add(row);
    seen.observe(row);
  };
  const unwatch = (node: Element) => {
    const gone = node.matches(ROW) ? [node] : node.firstElementChild ? [...node.querySelectorAll(ROW)] : [];
    for (const row of gone) {
      if (!watched.has(row) || row.isConnected) continue;
      watched.delete(row);
      whole.delete(row);
      seen!.unobserve(row);
    }
  };
  if (seen) for (const row of scroller.querySelectorAll(ROW)) watch(row);
  // The rows and elements the commits since the last frame touched, judged once, just before that frame draws.
  const rows = new Set<Element>();
  const changed = new Set<Element>();
  let pending = 0;
  // Boxes only where there is a motion to end: a box read is a forced layout of the page after React's writes,
  // and a fling up mounts a page of rows every frame with no motion in them (a 100k-row chat paid 9 s of a 46 s
  // fling in this read, 10.8 ms a frame, bench/transcript-scroll-up.bench.ts MODE=fling SPLIT=1,
  // `getBoundingClientRect <- observer`).
  //
  // And once a frame, not once a commit: `getAnimations` brings style and layout up to date, so reading the
  // motions in each commit's microtask paid a whole style and layout pass per commit, and a fling commits many
  // times a frame (a 100k-row chat paid 9,944 forced style-and-layout passes over 830 frames, 12 a frame,
  // `cssOf <- observer`, bench/transcript-scroll-up.bench.ts RESTYLE=1). In the frame's animation callbacks the
  // pass is the one the frame would run anyway, and a motion ended there is still drawn at its end: no frame
  // has drawn the row since it mounted. A motion that starts later is `started`'s, below.
  const judge = () => {
    pending = 0;
    let view: DOMRect | undefined;
    const outside = (element: Element) =>
      misses(element.getBoundingClientRect(), (view ??= scroller.getBoundingClientRect()));
    for (const row of rows) {
      if (!row.isConnected || whole.has(row)) continue;
      const motions = cssOf(row);
      if (motions.some(finishable) && outside(row)) finishAll(motions);
    }
    for (const element of changed) {
      if (!element.isConnected) continue;
      const row = element.closest(ROW);
      if (row && whole.has(row)) continue;
      const motions = cssOf(element);
      if (motions.some(finishable) && outside(element)) finishAll(motions);
    }
    rows.clear();
    changed.clear();
  };
  const frame = View?.requestAnimationFrame?.bind(View);
  const observer = View?.MutationObserver
    ? new View.MutationObserver((records) => {
        // Each row the commit touched, by the row's box, and each element it added or re-classed, by its
        // own box: a long row that is partly in the view still has its words below the view's edge
        // streaming in out of sight. An element's own box alone is not enough: a line that mounts with
        // no box yet (the Thinking roll) reads as in view.
        for (const record of records) {
          // A row that left is no longer watched (the observer would hold it for the chat's life).
          if (seen && record.type === "childList")
            for (const node of record.removedNodes) if (node instanceof Element) unwatch(node);
          const nodes = record.type === "childList" ? [...record.addedNodes] : [record.target];
          for (const node of nodes) {
            if (!(node instanceof Element)) continue;
            const row = node.closest(ROW);
            if (!row || !scroller.contains(row)) continue;
            watch(row);
            if (whole.has(row)) continue;
            rows.add(row);
            if (node !== row) changed.add(node);
          }
        }
        if (rows.size === 0 || pending) return;
        // No frame to wait for (a page with no animation frames): judged now, as before.
        if (!frame) judge();
        else pending = frame(judge);
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
    if (!row || !scroller.contains(row) || whole.has(row)) return;
    const view = scroller.getBoundingClientRect();
    if (!misses(row.getBoundingClientRect(), view) && !misses(target.getBoundingClientRect(), view)) return;
    finishAll(cssOf(target));
  };
  scroller.addEventListener("animationstart", started, true);
  scroller.addEventListener("transitionrun", started, true);
  return () => {
    if (pending) View?.cancelAnimationFrame?.(pending);
    pending = 0;
    rows.clear();
    changed.clear();
    observer?.disconnect();
    seen?.disconnect();
    scroller.removeEventListener("animationstart", started, true);
    scroller.removeEventListener("transitionrun", started, true);
  };
}
