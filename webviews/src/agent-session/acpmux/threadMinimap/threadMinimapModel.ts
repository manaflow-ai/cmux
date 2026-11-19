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
    // The same three looks, each a lookup (keyIndex.ts), not a walk over the rows: a tick moved by
    // older turns put above it or taken away is found in O(1), and one gone is known gone. A row id is
    // one tick's own or one folded run's member, and a key one tick's.
    const keyed = ticks.keyIndex(ref.key);
    if (keyed !== undefined && keyed < ticks.pendingCount && keyed >= from && ticks.at(keyed)!.id === ref.id)
      return keyed;
    from = Math.max(from, ticks.pendingCount);
    const byId = ticks.idIndex(ref.id);
    if (byId !== undefined && byId >= from) return byId;
    return keyed !== undefined && keyed >= from ? keyed : -1;
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
