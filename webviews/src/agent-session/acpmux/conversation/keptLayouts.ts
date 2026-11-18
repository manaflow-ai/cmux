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
};

/// What a chat's layout keeps. `drawn` is the transcript's drawn heights (each names its chat, version
/// and width). `look`, `view` and `registry` are what it was measured with: another one measures again.
export type KeptLayout<D> = {
  drawn: D;
  heights: ReadonlyMap<string, KeptHeight>;
  look: unknown;
  view: unknown;
  registry: unknown;
};

/// Chats whose layout one page keeps, as many as their tails it keeps a while (tailCache.ts).
export const KEPT_LAYOUTS = 12;

export class KeptLayouts<D> {
  /// Least recently kept first.
  private kept = new Map<string, KeptLayout<D>>();

  constructor(private readonly limit = KEPT_LAYOUTS) {}

  /// Keeps `layout` for `sessionId`, replacing what was kept for it, and drops the oldest past the limit.
  keep(sessionId: string, layout: KeptLayout<D>): void {
    this.kept.delete(sessionId);
    this.kept.set(sessionId, layout);
    while (this.kept.size > this.limit) {
      const oldest = this.kept.keys().next().value;
      if (oldest === undefined) break;
      this.kept.delete(oldest);
    }
  }

  /// The layout kept for `sessionId` when it was measured with the same look, view and registry; taken
  /// out either way (the transcript keeps it again when it leaves the chat).
  take(sessionId: string, look: unknown, view: unknown, registry: unknown): KeptLayout<D> | undefined {
    const kept = this.kept.get(sessionId);
    if (!kept) return undefined;
    this.kept.delete(sessionId);
    return kept.look === look && kept.view === view && kept.registry === registry ? kept : undefined;
  }

  get size(): number {
    return this.kept.size;
  }

  clear(): void {
    this.kept.clear();
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
