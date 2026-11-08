import { RailRows } from "./railRows";
import { type MinimapTick as MinimapTickRow } from "./model";

/// The band's first turn at the last commit: its tick (key and row id) and row, where its prompt was
/// in the layout, and where its row drew in the rail; and the first tick's, which older turns change.
export type Anchor = { tick: TickRef; first: TickRef; index: number; layoutTop: number; y: number };

/// A tick as the rail's state remembers it: its key and its prompt's row id.
export type TickRef = Pick<MinimapTickRow, "key" | "id"> & Pick<Partial<MinimapTickRow>, "members">;

/// The index of the tick `ref` names in `ticks`, or -1: by its row first, then by its key. The row
/// id holds where older turns arrive (a repeated key can move to an older echo, model.ts ticksOf);
/// the key holds where acpmux's echo replaces this pane's row for a send (a new row, one promptId).
export function tickIndex(ticks: readonly TickRef[] | RailRows<MinimapTickRow>, ref: TickRef, from = 0): number {
  if (ticks instanceof RailRows) {
    const pending = ticks.keyIndex(ref.key);
    if (pending !== undefined && pending < ticks.pendingCount && pending >= from && ticks.at(pending)!.id === ref.id)
      return pending;
    from = Math.max(from, ticks.pendingCount);
  }
  for (let index = from; index < ticks.length; index += 1) if (ticks.at(index)!.id === ref.id) return index;
  // A tick folded into a run of other chats' messages since (model.ts `foldIncoming`) is that run's.
  for (let index = from; index < ticks.length; index += 1) if (ticks.at(index)!.members?.includes(ref.id)) return index;
  for (let index = from; index < ticks.length; index += 1) if (ticks.at(index)!.key === ref.key) return index;
  return -1;
}

/// How many turns arrived above `anchor`'s since it was taken (undefined: none, or it is gone).
export function prependedBy(
  anchor: Anchor | undefined,
  ticks: readonly MinimapTickRow[] | RailRows<MinimapTickRow>,
): number | undefined {
  if (!anchor || !ticks.length || tickIndex(ticks, anchor.first) === 0) return undefined;
  const at = tickIndex(ticks, anchor.tick, anchor.index);
  return at < 0 ? undefined : at - anchor.index;
}
