// A row's entrance starts on the frame that first draws it (Leo, 2026-11-11, on his NIGHTLY's end of
// a turn: "the animation system is so borked and unintegrated"; a UI change is a state transition,
// so every affected element moves together, with no pop-in).
//
// A row that enters fades in on a CSS animation (conversation.css `.acpmux-row--enter`, 180 ms).
// WebKit starts a CSS animation's clock when the row's style is first resolved, which is the commit
// that mounts it (the transcript measures each new row there), not the frame that paints it. With a
// busy main thread the first frame after that commit came 130 ms or more later, so the fade had
// already ended before anything was drawn: the "Received 2 messages" line and the next turn's
// Thinking line popped in whole at a turn's end (agent-pane-turn-end-motion.test.ts, WebKit with a
// busy main thread). Chromium resolves the start at the frame, so there the two agree.
//
// `holdEntranceForFirstFrame` holds the row's entrance at its first keyframe from the commit and
// plays it in a task after the next frame renders. A frame callback is before rendering: releasing
// there let the short fade reach 98% opacity before the first observed WebKit frame under load. The slim
// follow arm places the row in view at once, exposing that premature start. One frame request and
// one posted task per entering row, none at rest; the motion's duration and follow mode stay the same.
//
// Stop condition: the hold ends after the next frame; a page that hides first has its held animations
// finished by pageReveal.ts (finishPageAnimations finishes paused ones too), and an unmount cancels
// the frame or posted task.

/// The entrance keyframes a generic row's own animation plays (conversation.css).
/// A sent prompt's pop (conversation.css SEND-POP) plays on its presentation wrapper, inside the row.
const ENTRANCES = new Set([
  "cv-enter",
  "cv-enter-fade",
  "cv-send-pop",
  "cv-send-pop-fade",
  "cv-send-pop-spring",
  "cv-recap-rise",
  "cv-recap-unfurl",
  "cv-recap-bead",
]);

export type Frames = {
  request: (run: () => void) => number;
  cancel: (handle: number) => void;
  post: (run: () => void) => () => void;
};

/// Posted from a frame callback: runs after that frame's rendering, with no fixed delay.
function postAfterFrame(run: () => void): () => void {
  const channel = new MessageChannel();
  const cancel = () => {
    channel.port1.onmessage = null;
    channel.port1.close();
    channel.port2.close();
  };
  channel.port1.onmessage = () => {
    cancel();
    run();
  };
  channel.port2.postMessage(null);
  return cancel;
}

export const windowFrames = (): Frames | undefined =>
  typeof requestAnimationFrame === "function"
    ? {
        request: (run) => requestAnimationFrame(() => run()),
        cancel: (handle) => cancelAnimationFrame(handle),
        post: postAfterFrame,
      }
    : undefined;

/// Whether `animation` is the row's own finite entrance.
function isEntrance(animation: Animation): boolean {
  const name = (animation as Animation & { animationName?: string }).animationName;
  if (!name || !ENTRANCES.has(name)) return false;
  const end = animation.effect?.getComputedTiming?.().endTime;
  return end !== undefined && Number.isFinite(Number(end));
}

/// Holds `row`'s entrance at its start through the next frame, then plays it from there. Called in
/// the layout effect of the commit that mounts the row, before it paints. Returns the cancel.
/// `subtree`: also the row's descendants' entrances (a sent prompt's pop is on its presentation wrapper).
export function holdEntranceForFirstFrame(
  row: Element,
  frames: Frames | undefined = windowFrames(),
  subtree = false,
): () => void {
  if (!frames || typeof row.getAnimations !== "function") return () => {};
  return holdForFirstFrame(
    row
      .getAnimations(subtree ? { subtree: true } : undefined)
      .filter((animation) => animation.playState === "running" && isEntrance(animation)),
    frames,
  );
}

/// Holds `animations` at time zero through the next frame's rendering and plays them from a task that
/// frame posts (the new chat's entrance, newChatEntrance.ts, holds its own Web Animations here). One
/// still paused when the task runs plays; one a page hide finished stays finished. Returns the cancel,
/// which drops the frame request and the posted task alike.
export function holdForFirstFrame(
  animations: readonly Animation[],
  frames: Frames | undefined = windowFrames(),
): () => void {
  if (!frames || animations.length === 0) return () => {};
  for (const animation of animations) {
    animation.pause();
    animation.currentTime = 0;
  }
  let cancelPosted: (() => void) | undefined;
  let handle: number | undefined = frames.request(() => {
    handle = undefined;
    cancelPosted = frames.post(() => {
      cancelPosted = undefined;
      for (const animation of animations) if (animation.playState === "paused") animation.play();
    });
  });
  return () => {
    if (handle !== undefined) frames.cancel(handle);
    handle = undefined;
    cancelPosted?.();
    cancelPosted = undefined;
  };
}
