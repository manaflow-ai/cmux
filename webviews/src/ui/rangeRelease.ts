// A native range slider's drag, ended on every release WebKit sends it
// (https://github.com/manaflow-ai/cmux/issues/65781).
//
// WebKit's slider thumb holds the mouse itself for its drag and leaves drag mode only when the
// thumb gets the mouseup. Never call setPointerCapture on a range input (or an ancestor of one): the
// capture takes that mouseup from the thumb, which then stays in drag mode, sends no `change`, and
// follows the pointer over it with no button down.
//
// Without a capture, a drag that starts on the thumb reaches the input as `mouseup` (then the
// native `change`) wherever the pointer is released, and sends no `pointerup`; a press on the track
// sends both. So a slider that tracks its own drag ends it on any of these.

/** The input's handlers that end a range slider's drag: `end` may run more than once per drag. */
export function rangeDragEnd(end: () => void) {
  return { onMouseUp: end, onPointerUp: end, onPointerCancel: end, onBlur: end };
}
