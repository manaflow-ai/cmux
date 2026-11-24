// A chat's settled layout, kept by the transcript when it shows another chat, so the chat's next show in
// the same page places every row it drew before at the height it drew, and estimates none of them again
// (Leo, 2026-11-18: "faster truly settled agent transcripts showing up whether from loading in app or
// switching between workspaces ... Fundamentally").
//
// Before this, a switch away dropped the chat's drawn heights (VirtualTranscript `drawn`, filtered to the
// rows on screen) and its estimates (kept by row object, and a return builds new row objects from the
// kept tail), so a return to a 10k-row chat measured every row's text again and then moved rows as the
// mounted ones drew (cmuxterm-hq#13406). A kept layout is the chat's rows' heights by id, each with the
// version and text length it was measured at: a row that changed while the chat was away misses and is
// measured as before, so nothing stale places a row.
//
// Page memory only, bounded by KEPT_LAYOUTS chats (a god chat's entry is one small object per row).

/// A row's estimated height as the transcript last measured it (model.ts `RowHeights`), with what makes
/// it the same row's: its version and its text's length.
export type KeptHeight = {
  version: number;
  textLength: number;
  width: number;
  height: number;
  edge?: string;
  scale?: number;
  open?: string;
};

/// A row as the store reads it: its id, version and text say whether it is the same row.
export type KeptRow = { id: string; version: number; text?: string };

/// A row's estimated height as the transcript holds it (model.ts `RowHeights` values).
/// `open`: the row's state signature it was estimated in (rowOpenState.ts), kept with it.
export type RowHeight = { width: number; height: number; edge?: string; scale?: number; open?: string };

/// What a chat's layout keeps: references only, recorded after every commit, so recording is O(1). `rows`
/// and `heights` are the transcript's last estimate's rows and its estimates by row object; `drawn` its
/// drawn heights (each names its chat, version and width). `look`, `view` and `registry` are what it was
/// measured with: another one measures again.
export type KeptLayout<D, R extends KeptRow = KeptRow> = {
  drawn: D;
  rows: readonly R[];
  heights: WeakMap<R, RowHeight>;
  look: unknown;
  view: unknown;
  registry: unknown;
};

/// A chat shown again seeds its estimates for this many passes and this long (its kept tail's draw, its
/// attach page and the records after it each build new row objects), then measures as usual.
const SEED_PASSES = 4;
const SEED_MS = 2_000;

type Seeding = { heights: ReadonlyMap<string, KeptHeight>; passes: number; since?: number };

/// Chats whose layout one page keeps, as many as their tails it keeps a while (tailCache.ts).
export const KEPT_LAYOUTS = 12;

export class KeptLayouts<D, R extends KeptRow = KeptRow> {
  /// Least recently recorded first.
  private kept = new Map<string, KeptLayout<D, R>>();
  /// Chats shown again whose first estimates take their rows' heights from what they left.
  private seeding = new Map<string, Seeding>();

  constructor(
    private readonly limit = KEPT_LAYOUTS,
    private readonly now: () => number = () => performance.now(),
  ) {}

  /// Records what the transcript showing `sessionId` laid out, replacing what was recorded for it, and
  /// drops the oldest chat past the limit.
  record(sessionId: string, layout: KeptLayout<D, R>): void {
    this.kept.delete(sessionId);
    this.kept.set(sessionId, layout);
    while (this.kept.size > this.limit) {
      const oldest = this.kept.keys().next().value;
      if (oldest === undefined) break;
      this.kept.delete(oldest);
      this.seeding.delete(oldest);
    }
  }

  /// The transcript shows `sessionId` again: the drawn heights its layout left, when it was measured with
  /// the same look, view and registry, and its next estimates seed (`seed`) from that layout's heights, by
  /// row id. One pass over the rows it left, once per switch.
  show(sessionId: string, look: unknown, view: unknown, registry: unknown, scale: number): D | undefined {
    this.seeding.delete(sessionId);
    const kept = this.kept.get(sessionId);
    if (!kept || kept.look !== look || kept.view !== view || kept.registry !== registry) return undefined;
    const heights = new Map<string, KeptHeight>();
    for (const row of kept.rows) {
      const known = kept.heights.get(row);
      if (known && (known.scale ?? 1) === scale)
        heights.set(row.id, { version: row.version, textLength: row.text?.length ?? 0, ...known });
    }
    this.seeding.set(sessionId, { heights, passes: 0 });
    return kept.drawn;
  }

  /// Gives each of `rows` with no estimate in `into` yet the height `sessionId`'s kept layout holds for it
  /// (same id, version, text length and scale), so the estimate keeps it instead of measuring it. Stops
  /// after SEED_PASSES passes and SEED_MS. Returns `into`.
  seed<M extends WeakMap<R, RowHeight>>(sessionId: string | undefined, rows: readonly R[], into: M, scale: number): M {
    const seeding = sessionId === undefined ? undefined : this.seeding.get(sessionId);
    if (sessionId === undefined || !seeding) return into;
    for (const row of rows) {
      if (into.has(row)) continue;
      const kept = keptHeightFor(seeding.heights, row, scale);
      if (kept)
        into.set(row, {
          width: kept.width,
          height: kept.height,
          ...(kept.edge !== undefined ? { edge: kept.edge } : {}),
          ...(kept.scale !== undefined ? { scale: kept.scale } : {}),
          ...(kept.open !== undefined ? { open: kept.open } : {}),
        });
    }
    seeding.passes += 1;
    seeding.since ??= this.now();
    if (seeding.passes >= SEED_PASSES && this.now() - seeding.since >= SEED_MS) this.seeding.delete(sessionId);
    return into;
  }

  /// `sessionId` is measured with another look or registry: nothing it kept places a row now.
  forget(sessionId: string): void {
    this.kept.delete(sessionId);
    this.seeding.delete(sessionId);
  }

  get size(): number {
    return this.kept.size;
  }

  clear(): void {
    this.kept.clear();
    this.seeding.clear();
  }
}

/// The kept height for `row`, when it is the same row at the same scale: its id, version and text length.
export function keptHeightFor(
  heights: ReadonlyMap<string, KeptHeight>,
  row: { id: string; version: number; text?: string },
  scale: number,
): KeptHeight | undefined {
  const kept = heights.get(row.id);
  if (!kept || kept.version !== row.version || kept.textLength !== (row.text?.length ?? 0)) return undefined;
  return (kept.scale ?? 1) === scale ? kept : undefined;
}
