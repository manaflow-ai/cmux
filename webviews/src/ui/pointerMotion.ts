// Whether the pointer moved onto an element, or the element moved under a still pointer. A page that lays out again
// (a pane's tabs closing, the chat's tools taking their place in the tab row) puts new elements under a pointer that
// did not move, and the engine sends them `pointerover` as though it had; a tooltip or card opened from that pops up
// over the very control the person was about to click (Leo 2026-11-07: "the top right button area is somehow, like,
// shifting its layout"). Only a real move opens one: the element still under the pointer after it moves gets it then.

/** The screen point of a pointer event. */
type At = { readonly screenX: number; readonly screenY: number };

/** The pointer's last moved-to point, read by `pointerover` (which comes before the `pointermove` of the same move). */
export class PointerMotion {
  private last: { x: number; y: number } | undefined;

  /** A `pointermove`: true when the pointer is somewhere new (an engine's synthetic move at the same point is not). */
  moved(event: At): boolean {
    const arrived = this.arrived(event);
    this.last = { x: event.screenX, y: event.screenY };
    return arrived;
  }

  /** A `pointerover`: true when the pointer moved onto the element, false when the element moved under it. */
  arrived(event: At): boolean {
    return this.last === undefined || this.last.x !== event.screenX || this.last.y !== event.screenY;
  }
}
