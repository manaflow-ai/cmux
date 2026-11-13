// A row's entrance starts on the frame that first draws it (Leo, 2026-11-11, on his NIGHTLY's end of
// a turn: "the animation system is so borked and unintegrated"). WebKit can resolve a CSS animation
// when the row commits, then paint it only after a busy task; a short fade has ended by that first paint.
// The row is therefore rendered with its entrance held from the start, and the hold is released from
// the next frame. The animation is created only when the hold attribute is removed, so its clock starts
// at that frame on every engine.

export const ENTRANCE_HELD_ATTR = "data-entrance-held";

type Frames = {
  request: (run: () => void) => number;
  cancel: (handle: number) => void;
};

const windowFrames = (): Frames | undefined =>
  typeof requestAnimationFrame === "function"
    ? { request: (run) => requestAnimationFrame(() => run()), cancel: (handle) => cancelAnimationFrame(handle) }
    : undefined;

/// Releases the render-time entrance hold on the next frame. The attribute is present in the row's
/// initial markup, before WebKit can materialize its CSS animation; removing it creates the animation
/// at the first frame instead of trying to rewind an animation that may already have finished.
export function holdEntranceForFirstFrame(row: Element, frames: Frames | undefined = windowFrames()): () => void {
  if (!frames || typeof row.removeAttribute !== "function") return () => {};
  row.setAttribute(ENTRANCE_HELD_ATTR, "");
  let handle: number | undefined = frames.request(() => {
    handle = undefined;
    row.removeAttribute(ENTRANCE_HELD_ATTR);
  });
  return () => {
    if (handle !== undefined) frames.cancel(handle);
    handle = undefined;
    row.removeAttribute(ENTRANCE_HELD_ATTR);
  };
}
