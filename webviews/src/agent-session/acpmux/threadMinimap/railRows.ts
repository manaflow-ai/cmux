import type { MinimapTick, MinimapTurn } from "./model";

/// Logical rail rows: a count-only prefix and the prompts we actually know. Geometry and
/// spacers use `length`; only displayed rows and interaction targets ask for a placeholder.
export class RailRows<T extends MinimapTick> {
  readonly length: number;
  private keys?: Map<string, number>;

  constructor(
    readonly items: readonly T[],
    readonly pendingCount: number,
    readonly sessionId: string,
    private readonly pending: (sessionId: string, index: number) => T,
  ) {
    this.length = pendingCount + items.length;
  }

  at(index: number): T | undefined {
    const at = index < 0 ? this.length + index : index;
    if (at < 0 || at >= this.length) return undefined;
    return at < this.pendingCount ? this.pending(this.sessionId, at) : this.items[at - this.pendingCount];
  }

  keyIndex(key: string): number | undefined {
    const prefix = `${this.sessionId}#pending:`;
    if (key.startsWith(prefix)) {
      const at = Number(key.slice(prefix.length));
      if (Number.isInteger(at) && at >= 0 && at < this.pendingCount && key === `${prefix}${at}`) return at;
    }
    this.keys ??= new Map(this.items.map((tick, index) => [tick.key, index + this.pendingCount]));
    return this.keys.get(key);
  }

  /// Search named prompts only; pending rows have no row id or metadata to find.
  findHeld(predicate: (item: T) => boolean): number {
    const at = this.items.findIndex(predicate);
    return at < 0 ? -1 : at + this.pendingCount;
  }
}

export const turnRows = (items: readonly MinimapTurn[], pendingCount: number, sessionId = "") =>
  new RailRows(items, pendingCount, sessionId, pendingTurn);
export const tickRows = (items: readonly MinimapTick[], pendingCount: number, sessionId = "") =>
  new RailRows(items, pendingCount, sessionId, pendingTurn);

/// Synthesize one count-only prompt when a displayed row or an interaction reads it.
export function pendingTurn(sessionId: string, at: number): MinimapTurn {
  return {
    index: -1,
    id: `pending:${at}`,
    key: `${sessionId}#pending:${at}`,
    prompt: "",
    reply: [],
    pending: true,
  };
}
