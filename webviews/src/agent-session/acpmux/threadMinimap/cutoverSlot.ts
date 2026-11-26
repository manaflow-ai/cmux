import type { MinimapTurn } from "./model";

/// The gap between rail entries on opposite sides of the New line. A filtered or folded
/// rail supplies its own entries. Indexed history sits outside the held transcript.
/// Only probe the ranges the rail already draws, regardless of the length of the chat.
export function cutoverSlot(
  turns: { heldStart: number; items: readonly Pick<MinimapTurn, "index">[] },
  divider: number,
  ranges: ReadonlyArray<readonly [number, number]>,
): number | undefined {
  const { heldStart, items } = turns;
  for (const [from, to] of ranges) {
    let low = Math.max(0, from - heldStart);
    let high = Math.min(items.length, to - heldStart);
    if (low > high || (items[low - 1]?.index ?? -1) > divider || (items[high]?.index ?? Infinity) <= divider) continue;
    while (low < high) {
      const mid = low + Math.floor((high - low) / 2);
      if (items[mid]!.index <= divider) low = mid + 1;
      else high = mid;
    }
    return heldStart + low;
  }
  return undefined;
}
