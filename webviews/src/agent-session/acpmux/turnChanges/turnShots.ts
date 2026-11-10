// A turn's before and after picture of the chat's page (wow idea 26): acpmux captures the page a
// browser pane of the chat's workspace shows when the turn starts and once it ends, and keeps the
// pair when the pictures differ (cmux-tui acpmux hub/turn_shots.rs). The edited-files card reads
// it by the turn's id when it draws (TurnShotsPair.tsx); a card that never draws reads nothing.
import { createContext } from "react";
import type { CompareMode } from "../../../ui/MediaCompare";
import { endsTurn, turnRows } from "../diff";
import type { AcpmuxRow } from "../model";

export type TurnShotPair = { before: string; after: string };

/// The pair of the turn that holds row `rowId`: `peek` answers at once when it was read before
/// (`{}`: none), `read` reads it. The pane provides it; undefined draws no pictures.
export type TurnShotsReader = {
  /// Changes when a turn ends (the newest summary row's id): a new reader re-renders the cards.
  version?: string;
  /// How the pair shows; the pane leaves it to the default split (the gallery shows the others).
  mode?: CompareMode;
  peek(rowId: string): { pair?: TurnShotPair } | undefined;
  read(rowId: string): Promise<TurnShotPair | undefined>;
};
export const TurnShotsContext = createContext<TurnShotsReader | undefined>(undefined);

const picture = (value: unknown): string | undefined => {
  if (!value || typeof value !== "object") return undefined;
  const { mimeType, data } = value as { mimeType?: unknown; data?: unknown };
  if (typeof data !== "string" || !data) return undefined;
  const type = typeof mimeType === "string" && /^image\/[a-z0-9.+-]+$/.test(mimeType) ? mimeType : "image/png";
  return `data:${type};base64,${data}`;
};

/// acpmux's `{before, after}` as data URLs; undefined unless both are there.
export function readTurnShots(reply: unknown): TurnShotPair | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const { before, after } = reply as { before?: unknown; after?: unknown };
  const pair = { before: picture(before), after: picture(after) };
  return pair.before && pair.after ? { before: pair.before, after: pair.after } : undefined;
}

/// The acpmux turn id of the ended turn that holds row `rowId`: its ending summary's. Undefined
/// while the turn runs: its after is not taken yet.
export function shotTurnId(rows: readonly AcpmuxRow[], rowId: string): string | undefined {
  return turnRows([...rows], rowId).find((row) => row.kind === "turnSummary" && endsTurn(row))?.turnId;
}

type CacheEntry = { read: Promise<TurnShotPair | undefined>; settled?: { pair?: TurnShotPair } };

/// The pairs read so far, by session and turn, at most `limit` (the oldest read goes first), so a
/// card that scrolls back into view draws its pair at once, with no reveal, and memory stays bounded
/// however long the chat is. A read that found nothing is kept too: a turn's pair never appears later.
/// A read that failed (no answer, or the pair still being taken) is not kept: the next draw asks again.
export class TurnShotCache {
  private readonly reads = new Map<string, CacheEntry>();
  constructor(private readonly limit = 12) {}

  /// The pair already read for `key`: `{pair}` once settled (pair undefined: none), else undefined
  /// (never read, being read, or the read failed).
  peek(key: string): { pair?: TurnShotPair } | undefined {
    return this.reads.get(key)?.settled;
  }

  read(key: string, load: () => Promise<TurnShotPair | undefined>): Promise<TurnShotPair | undefined> {
    const kept = this.reads.get(key);
    if (kept) {
      this.reads.delete(key);
      this.reads.set(key, kept);
      return kept.read;
    }
    const entry: CacheEntry = {
      read: load().then(
        (pair) => {
          entry.settled = { pair };
          return pair;
        },
        () => {
          if (this.reads.get(key) === entry) this.reads.delete(key);
          return undefined;
        },
      ),
    };
    this.reads.set(key, entry);
    while (this.reads.size > this.limit) this.reads.delete(this.reads.keys().next().value!);
    return entry.read;
  }
}
