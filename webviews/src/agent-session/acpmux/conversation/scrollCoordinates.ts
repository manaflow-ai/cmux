/** The transcript's logical row coordinates may fall between the browser's physical scroll ticks. */
export type ScrollCoordinateNode = {
  scrollTop: number;
  style: Pick<CSSStyleDeclaration, "setProperty" | "removeProperty">;
};

const origins = new WeakMap<ScrollCoordinateNode, number>();
export const SCROLL_ORIGIN_PROPERTY = "--acpmux-scroll-origin";

type OriginHost = { style: Pick<CSSStyleDeclaration, "setProperty" | "removeProperty"> };
const hosts = new WeakMap<ScrollCoordinateNode, OriginHost>();

/// Where `node`'s origin is written: the one element that reads it (the transcript's thread), not the
/// scroller. The property does not inherit (conversation.css @property), so a new origin restyles that
/// element alone. Written on the scroller, an inherited property, every page landing's anchor write
/// restyled each element of every mounted row (about 1,600 in a long chat) before the frame could
/// paint (Leo, 2026-11-11: "scrolling up is slow and it layout shift and everythng lag").
export function hostScrollOrigin(node: ScrollCoordinateNode, host: OriginHost | null): void {
  const was = hosts.get(node);
  if (was === host) return;
  const origin = origins.get(node);
  (was ?? node).style.removeProperty(SCROLL_ORIGIN_PROPERTY);
  if (host) hosts.set(node, host);
  else hosts.delete(node);
  if (origin !== undefined) (host ?? node).style.setProperty(SCROLL_ORIGIN_PROPERTY, `${origin}px`);
}

function originHost(node: ScrollCoordinateNode): OriginHost {
  return hosts.get(node) ?? node;
}

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

/** Reset on an intentional navigation/session/follow handoff, before its target is written. */
export function clearScrollOrigin(node: ScrollCoordinateNode): void {
  if (!origins.delete(node)) return;
  originHost(node).style.removeProperty(SCROLL_ORIGIN_PROPERTY);
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
  else {
    if (origins.get(node) === residual) return residual;
    origins.set(node, residual);
    originHost(node).style.setProperty(SCROLL_ORIGIN_PROPERTY, `${residual}px`);
  }
  return residual;
}
