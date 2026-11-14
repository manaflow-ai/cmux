// Whether the pointer moved onto an element, or the element moved under a still pointer. A page that lays out again
// (a pane's tabs closing, the chat's tools taking their place in the tab row) puts new elements under a pointer that
// did not move, and the engine sends them `pointerover` as though it had; a tooltip or card opened from that pops up
// over the very control the person was about to click (Leo 2026-11-07: "the top right button area is somehow, like,
// shifting its layout"). Only a real move opens one: the element still under the pointer after it moves gets it then.

/** A pointer event's point on the screen and in the page's viewport. Both stay put while the pointer is still and a
 * layout moves elements under it; an engine that reports no screen point (WebKit's automation sends 0, 0) still
 * reports the viewport point, so a move is either one changing. */
type At = { readonly screenX: number; readonly screenY: number; readonly clientX: number; readonly clientY: number };

/** The pointer's last moved-to point, read by `pointerover` (which comes before the `pointermove` of the same move). */
export class PointerMotion {
  private last: At | undefined;

  /** A `pointermove`: true when the pointer is somewhere new (an engine's synthetic move at the same point is not). */
  moved(event: At): boolean {
    const arrived = this.arrived(event);
    this.last = { screenX: event.screenX, screenY: event.screenY, clientX: event.clientX, clientY: event.clientY };
    return arrived;
  }

  /** A `pointerover`: true when the pointer moved onto the element, false when the element moved under it. */
  arrived(event: At): boolean {
    const last = this.last;
    return (
      last === undefined ||
      last.screenX !== event.screenX ||
      last.screenY !== event.screenY ||
      last.clientX !== event.clientX ||
      last.clientY !== event.clientY
    );
  }
}
