// A page switched away from and back to is a reattach, not a data change
// (plans/cmux-next/shared-projections.md). Each tab's page stays alive and hidden while another
// tab or workspace shows, so a switch only hides and shows it (`visibilityState`). Two things then
// went wrong in every view:
// - WebKit suspends a hidden page's animations, so an entrance started while hidden (a transcript
//   row that streamed in, a chat card that arrived) played when the user came back.
// - A change that was computed while hidden landed as the page showed again and was diffed as
//   live news, so it animated on the first frame back.
// This module is the one owner of "may an entrance run now": no while hidden, no until the first
// frame after the page shows has passed. Views decide an entrance from their data diff and also
// ask `entranceAllowed`. `installRevealSettle` finishes the page's finite animations when it hides
// and when it shows, so nothing started while hidden plays on return.

type RevealState = {
  /// Set from the page showing again until its first frame has passed.
  settling: boolean;
  /// Bumped on every visibility change, so a late settle from an older reveal does nothing.
  generation: number;
};

const states = new WeakMap<Document, RevealState>();

function defaultDocument(): Document | undefined {
  return typeof document === "undefined" ? undefined : document;
}

function nextFrame(doc: Document, run: () => void): void {
  const view = doc.defaultView as (Window & typeof globalThis) | null;
  const raf = view?.requestAnimationFrame?.bind(view) ?? globalThis.requestAnimationFrame;
  if (typeof raf === "function") raf(() => run());
  else setTimeout(run, 16);
}

/// Finishes every running animation with an end (CSS animations and transitions, Web Animations);
/// infinite ones (spinners, a breathing status dot) keep running. Finishing, unlike cancelling,
/// runs each animation's own `onfinish` cleanup.
export function finishPageAnimations(doc: Document | undefined = defaultDocument()): number {
  const all = (doc as (Document & { getAnimations?: () => Animation[] }) | undefined)?.getAnimations?.();
  if (!all) return 0;
  let finished = 0;
  for (const animation of all) {
    if (animation.playState === "finished" || animation.playState === "idle") continue;
    const end = animation.effect?.getComputedTiming?.().endTime;
    if (end === undefined || !Number.isFinite(Number(end))) continue;
    try {
      animation.finish();
      finished += 1;
    } catch {
      // An animation that cannot finish (no end after all) keeps running.
    }
  }
  return finished;
}

function watch(doc: Document): RevealState {
  let state = states.get(doc);
  if (state) return state;
  const created: RevealState = { settling: false, generation: 0 };
  state = created;
  states.set(doc, created);
  doc.addEventListener("visibilitychange", () => {
    created.generation += 1;
    finishPageAnimations(doc);
    if (doc.visibilityState === "hidden") {
      created.settling = false;
      return;
    }
    // Shown again: changes that land before its first frame has painted were made while the user
    // was away. Two frames: the first runs before that paint, the second after it.
    created.settling = true;
    const generation = created.generation;
    nextFrame(doc, () =>
      nextFrame(doc, () => {
        if (created.generation === generation) created.settling = false;
      }),
    );
  });
  return created;
}

/// Starts the page's reveal handling (idempotent). The page entry calls it once; `entranceAllowed`
/// also starts it, so a view in a gallery or a test gets the same rule.
export function installRevealSettle(doc: Document | undefined = defaultDocument()): void {
  if (doc) watch(doc);
}

/// Whether a view may run an entrance (a fade in, a slide) for a data change now: the page shows,
/// its first frame back has passed, and the host has not turned motion off.
export function entranceAllowed(doc: Document | undefined = defaultDocument()): boolean {
  if (!doc) return true;
  if (pageAway(doc)) return false;
  return doc.documentElement?.dataset.agentMotion !== "off";
}

/// Whether the user is away from the page: it is hidden, or it shows again and its first frame back
/// has not passed. Unlike `entranceAllowed`, motion turned off does not count: a view that paces
/// content in (the streaming reveal) keeps its pace with motion off and catches up only on return.
export function pageAway(doc: Document | undefined = defaultDocument()): boolean {
  if (!doc) return false;
  const state = watch(doc);
  return doc.visibilityState === "hidden" || state.settling;
}
