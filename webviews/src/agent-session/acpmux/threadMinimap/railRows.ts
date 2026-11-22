import { PromptHeads } from "../promptHeads";
import type { MinimapTick, MinimapTurn } from "./model";

/// Logical rail rows: a count-only prefix, then the prompts the chat's index names (`earlier`, older than the held
/// rows), then the prompts we hold, then the prompts newer than them a window of the chat lets go of (`later`). Geometry and spacers use `length`; only displayed rows and interaction targets
/// ask for a placeholder or an indexed prompt, so a long chat's rail keeps no object a prompt it does not draw.
export class RailRows<T extends MinimapTick> {
  readonly length: number;
  /// Where the held prompts start: past the count-only and the indexed ones.
  readonly heldStart: number;
  /// Where the newer prompts (`later`) start: past the held ones.
  readonly laterStart: number;
  private keys?: Map<string, number>;

  constructor(
    readonly items: readonly T[],
    readonly pendingCount: number,
    readonly sessionId: string,
    private readonly pending: (sessionId: string, index: number) => T,
    readonly earlier: PromptHeads = PromptHeads.EMPTY,
    readonly later: PromptHeads = PromptHeads.EMPTY,
  ) {
    this.heldStart = pendingCount + earlier.length;
    this.laterStart = this.heldStart + items.length;
    this.length = this.laterStart + later.length;
  }

  at(index: number): T | undefined {
    const at = index < 0 ? this.length + index : index;
    if (at < 0 || at >= this.length) return undefined;
    if (at < this.pendingCount) return this.pending(this.sessionId, at);
    if (at < this.heldStart) return indexedTurn(this.earlier, this.sessionId, at - this.pendingCount) as unknown as T;
    if (at < this.laterStart) return this.items[at - this.heldStart];
    return indexedTurn(this.later, this.sessionId, at - this.laterStart) as unknown as T;
  }

  keyIndex(key: string): number | undefined {
    const prefix = `${this.sessionId}#pending:`;
    if (key.startsWith(prefix)) {
      const at = Number(key.slice(prefix.length));
      if (Number.isInteger(at) && at >= 0 && at < this.pendingCount && key === `${prefix}${at}`) return at;
    }
    this.keys ??= new Map(this.items.map((tick, index) => [tick.key, index + this.heldStart]));
    const held = this.keys.get(key);
    if (held !== undefined) return held;
    const indexed = indexedKeyIndex(this.earlier, this.sessionId, key);
    if (indexed !== undefined) return indexed + this.pendingCount;
    const later = indexedKeyIndex(this.later, this.sessionId, key);
    return later === undefined ? undefined : later + this.laterStart;
  }

  /// Search held prompts only; pending and indexed rows have no row of their own to find.
  findHeld(predicate: (item: T) => boolean): number {
    const at = this.items.findIndex(predicate);
    return at < 0 ? -1 : at + this.heldStart;
  }
}

export const turnRows = (
  items: readonly MinimapTurn[],
  pendingCount: number,
  sessionId = "",
  earlier?: PromptHeads,
  later?: PromptHeads,
) => new RailRows(items, pendingCount, sessionId, pendingTurn, earlier, later);
export const tickRows = (
  items: readonly MinimapTick[],
  pendingCount: number,
  sessionId = "",
  earlier?: PromptHeads,
  later?: PromptHeads,
) => new RailRows(items, pendingCount, sessionId, pendingTurn, earlier, later);

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

/// Indexed prompts the rail has named, by index, per index and chat: a drawn row keeps its turn from render to
/// render (the tick's memo and its spoken label read it by identity). At most NAMED_KEPT a chat, about a few
/// screens of a tall rail; past that the cache starts over.
const named = new WeakMap<
  PromptHeads,
  { sessionId: string; turns: Map<number, MinimapTurn>; keys: Map<string, number> }
>();
const NAMED_KEPT = 2048;

function namedOf(heads: PromptHeads, sessionId: string) {
  let kept = named.get(heads);
  if (!kept || kept.sessionId !== sessionId) {
    kept = { sessionId, turns: new Map(), keys: new Map() };
    named.set(heads, kept);
  }
  return kept;
}

/// The indexed prompt at `at` as a turn with no row (index -1), keyed as its turn is once its page is held
/// (model.ts `turnKey`): the tick keeps its element when the page arrives.
export function indexedTurn(heads: PromptHeads, sessionId: string, at: number): MinimapTurn {
  const kept = namedOf(heads, sessionId);
  const had = kept.turns.get(at);
  if (had) return had;
  if (kept.turns.size >= NAMED_KEPT) kept.turns.clear();
  const promptId = PromptHeads.promptId(heads, at);
  const id = PromptHeads.id(heads, at);
  const turn: MinimapTurn = {
    index: -1,
    id,
    key: `${sessionId}#${promptId ? `prompt-${promptId}` : id}`,
    prompt: PromptHeads.text(heads, at).trim(),
    reply: [],
  };
  kept.turns.set(at, turn);
  return turn;
}

/// Where an indexed prompt's key (`indexedTurn`) is in `heads`, or undefined. A promptId is found by a scan of the
/// column, kept per key: hover and focus look up the same few keys on every render.
function indexedKeyIndex(heads: PromptHeads, sessionId: string, key: string): number | undefined {
  if (!heads.length || !key.startsWith(`${sessionId}#`)) return undefined;
  const rest = key.slice(sessionId.length + 1);
  if (rest.startsWith("user-")) {
    const seq = Number(rest.slice("user-".length));
    const at = Number.isFinite(seq) ? PromptHeads.indexOfSeq(heads, seq) : -1;
    // A prompt with a promptId keys on it, not its row.
    return at >= 0 && !PromptHeads.promptId(heads, at) ? at : undefined;
  }
  if (!rest.startsWith("prompt-")) return undefined;
  const kept = namedOf(heads, sessionId);
  let at = kept.keys.get(key);
  if (at === undefined) {
    at = PromptHeads.indexOfPromptId(heads, rest.slice("prompt-".length));
    if (kept.keys.size >= NAMED_KEPT) kept.keys.clear();
    kept.keys.set(key, at);
  }
  return at >= 0 ? at : undefined;
}
