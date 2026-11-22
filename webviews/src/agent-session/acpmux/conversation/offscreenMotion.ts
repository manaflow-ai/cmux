// A CSS animation or transition that starts outside the view is drawn at its end
// (cmuxterm-hq docs/design/transcript-animation-rules.md, rule 1: "inside the view only").
//
// Leo, 2026-11-22: "your chat folds or whatever, i scroll down, some bullshit ABOVE folds...? and plays an
// animation!? so there's some bullshit animation where i dont expect it to be, which is horrendous."
//
// The transcript's CSS motions (a row's entrance, the streamed words' fade, the Thinking line's roll, the
// Worked for clock's roll) start from a class or a mount, whatever the view: the overscan holds up to
// four viewports of rows the reader cannot see, and each one's motion played there, half done when he
// scrolled to it. One listener on the scroller ends each such start: `animationstart` and
// `transitionrun` come once per start, on the frame after the one that resolved it, so a motion out of
// sight draws one frame there and then its end. Ambient loops (a spinner, a shimmer) never end and are
// left alone. WAAPI motions are not seen here; each WAAPI site gates itself (turnEndFold.ts).
//
// Cost: one box read per start, none at rest.

/// A box this far past the view's edge still counts as in it (rounding, a 1 px border).
const EDGE_PX = 1;

/// Whether `element`'s box misses `scroller`'s.
export function outOfView(element: Element, scroller: Element): boolean {
  const box = element.getBoundingClientRect();
  if (box.width === 0 && box.height === 0) return false;
  const view = scroller.getBoundingClientRect();
  return box.bottom <= view.top + EDGE_PX || box.top >= view.bottom - EDGE_PX;
}

/// Ends, at once, each finite CSS animation or transition that starts inside `scroller` out of its view.
/// Returns the unsubscribe.
export function endOffscreenMotion(scroller: HTMLElement | null | undefined): () => void {
  if (!scroller || typeof scroller.addEventListener !== "function") return () => {};
  const started = (event: Event) => {
    const target = event.target;
    if (!(target instanceof Element) || typeof target.getAnimations !== "function") return;
    const named = event as AnimationEvent & TransitionEvent;
    const pseudo = named.pseudoElement || "";
    const mine = target.getAnimations().filter((animation) => {
      const css = animation as Animation & {
        animationName?: string;
        transitionProperty?: string;
        effect: (AnimationEffect & { pseudoElement?: string | null }) | null;
      };
      if ((css.effect?.pseudoElement ?? "") !== pseudo) return false;
      return event.type === "animationstart"
        ? css.animationName === named.animationName
        : css.transitionProperty === named.propertyName;
    });
    if (mine.length === 0) return;
    if (!outOfView(target, scroller)) return;
    for (const animation of mine) {
      if (animation.playState === "finished" || animation.playState === "idle") continue;
      const end = animation.effect?.getComputedTiming?.().endTime;
      if (end === undefined || !Number.isFinite(Number(end))) continue;
      try {
        animation.finish();
      } catch {
        // An animation that cannot finish keeps running.
      }
    }
  };
  scroller.addEventListener("animationstart", started, true);
  scroller.addEventListener("transitionrun", started, true);
  return () => {
    scroller.removeEventListener("animationstart", started, true);
    scroller.removeEventListener("transitionrun", started, true);
  };
}
