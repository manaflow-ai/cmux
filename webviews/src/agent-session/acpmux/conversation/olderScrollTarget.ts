import { layoutScrollTop, physicalScrollTop, type ScrollCoordinateNode } from "./scrollCoordinates";

/// A native scrollbar drag can move into the estimated room above the rows before the next
/// history page arrives. Keep the reader's requested logical position while the room is consumed,
/// instead of clamping every pointer move to the same loaded-history boundary.
export function noteOlderScrollTarget(
  previous: number | undefined,
  logicalTop: number,
  room: number,
  userIntentHeld: boolean,
): number | undefined {
  if (!userIntentHeld || room <= 0 || logicalTop >= room - 0.5) return previous;
  return Math.min(previous ?? logicalTop, logicalTop);
}

/// The target is logical (room-independent). While history is still reserved, native scrolling
/// remains at the loaded edge; each landed page reduces that edge until the target is reachable.
export function olderScrollTargetTop(target: number | undefined, room: number): number | undefined {
  return target === undefined ? undefined : Math.max(room, target);
}

/// Holds the reader at the retained target as the room above the rows drains (each landed page),
/// and says whether the target is now reachable, so the caller lets it go. The scroller's write lives
/// here, outside the component, so React Compiler does not read it as a write to a render value.
export function holdOlderScrollTarget(node: ScrollCoordinateNode, target: number, room: number): boolean {
  const next = olderScrollTargetTop(target, room);
  if (next !== undefined && Math.abs(layoutScrollTop(node) - next) > 0.5)
    node.scrollTop = physicalScrollTop(node, next);
  return room <= target + 0.5;
}
