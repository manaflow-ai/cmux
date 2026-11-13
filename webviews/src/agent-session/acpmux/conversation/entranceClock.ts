// A row's entrance starts on the frame that first draws it (Leo, 2026-11-11, on his NIGHTLY's end of
// a turn: "the animation system is so borked and unintegrated"; a UI change is a state transition,
// so every affected element moves together, with no pop-in).
//
// A row that enters fades in on a CSS animation (conversation.css `.acpmux-row--enter`, 80 ms).
// WebKit starts a CSS animation's clock when the row's style is first resolved, which is the commit
// that mounts it (the transcript measures each new row there), not the frame that paints it. With a
// busy main thread the first frame after that commit came 130 ms or more later, so the fade had
// already ended before anything was drawn: the "Received 2 messages" line and the next turn's
// Thinking line popped in whole at a turn's end (agent-pane-turn-end-motion.test.ts, WebKit with a
// busy main thread). Chromium resolves the start at the frame, so there the two agree.
//
// `holdEntranceForFirstFrame` holds the row's entrance at its first keyframe from the commit and
// plays it from the next frame's callbacks, so the frame that first draws the row draws it at its
// start on every engine. One animation frame request per entering row, none at rest.
//
// Stop condition: the hold ends on the next frame; a page that hides first has its held animations
// finished by pageReveal.ts (finishPageAnimations finishes paused ones too), and an unmount cancels
// the request.

/// The entrance keyframes a generic row's own animation plays (conversation.css).
const ENTRANCES = new Set(["cv-enter", "cv-enter-fade"]);

type Frames = {
  request: (run: () => void) => number;
  cancel: (handle: number) => void;
};

const windowFrames = (): Frames | undefined =>
  typeof requestAnimationFrame === "function"
    ? { request: (run) => requestAnimationFrame(() => run()), cancel: (handle) => cancelAnimationFrame(handle) }
    : undefined;

/// Whether `animation` is the row's own finite entrance.
function isEntrance(animation: Animation): boolean {
  const name = (animation as Animation & { animationName?: string }).animationName;
  if (!name || !ENTRANCES.has(name)) return false;
  const end = animation.effect?.getComputedTiming?.().endTime;
  return end !== undefined && Number.isFinite(Number(end));
}

/// Holds `row`'s entrance at its start until the next frame, then plays it from there. Called in
/// the layout effect of the commit that mounts the row, before it paints. Returns the cancel.
export function holdEntranceForFirstFrame(row: Element, frames: Frames | undefined = windowFrames()): () => void {
  if (!frames || typeof row.getAnimations !== "function") return () => {};
  const held = row.getAnimations().filter((animation) => animation.playState === "running" && isEntrance(animation));
  if (held.length === 0) return () => {};
  for (const animation of held) {
    animation.pause();
    animation.currentTime = 0;
  }
  let handle: number | undefined = frames.request(() => {
    handle = undefined;
    for (const animation of held) if (animation.playState === "paused") animation.play();
  });
  return () => {
    if (handle !== undefined) frames.cancel(handle);
    handle = undefined;
  };
}
