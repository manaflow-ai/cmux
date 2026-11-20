import { idIndexOf, keyIndexOf } from "./keyIndex";
import { turnRow, type MinimapTick, type MinimapTurn } from "./model";

/// Logical rail rows: a count-only prefix and the prompts we actually know. Geometry and
/// spacers use `length`; only displayed rows and interaction targets ask for a placeholder.
export class RailRows<T extends MinimapTick> {
  readonly length: number;

  constructor(
    readonly items: readonly T[],
    readonly pendingCount: number,
    readonly sessionId: string,
    private readonly pending: (sessionId: string, index: number) => T,
    /// Where the reading's row numbering starts (model.ts MinimapTurns `base`): a turn's prompt row is
    /// its `slot` less it.
    readonly base = 0,
  ) {
    this.length = pendingCount + items.length;
  }

  at(index: number): T | undefined {
    const at = index < 0 ? this.length + index : index;
    if (at < 0 || at >= this.length) return undefined;
    return at < this.pendingCount ? this.pending(this.sessionId, at) : this.items[at - this.pendingCount];
  }

  /// The prompt row of the turn at `index`, or -1 for one no row holds (model.ts `turnRow`).
  rowAt(index: number): number {
    const item = this.at(index) as Partial<MinimapTurn> | undefined;
    return item ? turnRow(this.base, item) : -1;
  }

  /// The row of the tick keyed `key`: a lookup in a map a page adds only its own keys to (keyIndex.ts).
  keyIndex(key: string): number | undefined {
    const prefix = `${this.sessionId}#pending:`;
    if (key.startsWith(prefix)) {
      const at = Number(key.slice(prefix.length));
      if (Number.isInteger(at) && at >= 0 && at < this.pendingCount && key === `${prefix}${at}`) return at;
    }
    const at = keyIndexOf(this.items, key);
    return at === undefined ? undefined : at + this.pendingCount;
  }

  /// The row of the held tick whose row id is `id`, or that folds a run with that member (keyIndex.ts).
  idIndex(id: string): number | undefined {
    const at = idIndexOf(this.items, id);
    return at === undefined ? undefined : at + this.pendingCount;
  }

  /// Search named prompts only; pending rows have no row id or metadata to find.
  findHeld(predicate: (item: T) => boolean): number {
    const at = this.items.findIndex(predicate);
    return at < 0 ? -1 : at + this.pendingCount;
  }
}

export const turnRows = (items: readonly MinimapTurn[], pendingCount: number, sessionId = "", base = 0) =>
  new RailRows(items, pendingCount, sessionId, pendingTurn, base);
export const tickRows = (items: readonly MinimapTick[], pendingCount: number, sessionId = "") =>
  new RailRows(items, pendingCount, sessionId, pendingTurn);

/// Synthesize one count-only prompt when a displayed row or an interaction reads it.
export function pendingTurn(sessionId: string, at: number): MinimapTurn {
  return {
    id: `pending:${at}`,
    key: `${sessionId}#pending:${at}`,
    prompt: "",
    reply: [],
    pending: true,
  };
}
