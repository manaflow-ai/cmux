/** The transcript's logical row coordinates may fall between the browser's physical scroll ticks. */
export type ScrollCoordinateNode = {
  scrollTop: number;
  style: Pick<CSSStyleDeclaration, "setProperty" | "removeProperty">;
};

const origins = new WeakMap<ScrollCoordinateNode, number>();
export const SCROLL_ORIGIN_PROPERTY = "--acpmux-scroll-origin";

export function scrollOrigin(node: ScrollCoordinateNode): number {
  return origins.get(node) ?? 0;
}

/** Logical layout coordinates; ordinary wheel deltas change only the physical offset. */
export function layoutScrollTop(node: ScrollCoordinateNode): number {
  return node.scrollTop - scrollOrigin(node);
}

/** Convert a row-layout target to the current physical scrolling coordinate system. */
export function physicalScrollTop(node: ScrollCoordinateNode, logicalTop: number): number {
  return logicalTop + scrollOrigin(node);
}

/**
 * Where the origin is written: the transcript's thread (VirtualTranscript `.acpmux-thread`, the
 * scroller's spacer's child), whose `top` is its one reader, so a write restyles that element alone
 * (conversation.css `@property --acpmux-scroll-origin`, which does not inherit). A node with no thread
 * (a test's) holds it itself.
 */
function originStyle(node: ScrollCoordinateNode): ScrollCoordinateNode["style"] {
  const thread =
    "querySelector" in node
      ? (node as unknown as Element).querySelector<HTMLElement>(":scope > .acpmux-spacer > .acpmux-thread")
      : null;
  return thread?.style ?? node.style;
}

/** Reset on an intentional navigation/session/follow handoff, before its target is written. */
export function clearScrollOrigin(node: ScrollCoordinateNode): void {
  // No origin held, none written: nothing to restyle.
  if (!origins.delete(node)) return;
  originStyle(node).removeProperty(SCROLL_ORIGIN_PROPERTY);
}

/**
 * The existing row-anchor caller's one scroll write, followed by a bounded placement residual.
 * Applying this CSS origin on the thread (together with its existing lift) preserves row pixels;
 * a clamp or stale write rebases instead of translating the thread by a large distance.
 */
export function writeAnchorScrollTop(node: ScrollCoordinateNode, desiredLogicalTop: number): number {
  node.scrollTop = desiredLogicalTop;
  return retainScrollOrigin(node, desiredLogicalTop);
}

/** Keep logical placement after an existing rounded physical write, without writing scrollTop again. */
export function retainScrollOrigin(node: ScrollCoordinateNode, desiredLogicalTop: number): number {
  const residual = node.scrollTop - desiredLogicalTop;
  if (!Number.isFinite(residual) || Math.abs(residual) > 1) {
    clearScrollOrigin(node);
    return 0;
  }
  if (residual === 0) clearScrollOrigin(node);
  // The same remainder as the one written: the thread already stands there.
  else if (origins.get(node) !== residual) {
    origins.set(node, residual);
    originStyle(node).setProperty(SCROLL_ORIGIN_PROPERTY, `${residual}px`);
  }
  return residual;
}
