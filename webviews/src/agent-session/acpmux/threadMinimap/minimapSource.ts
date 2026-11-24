import { useState } from "react";
import type { AcpmuxRow, TranscriptLayout } from "../model";
import type { RowsChange } from "./model";

/// What the transcript hands the rail on each of its renders: every one of these changes with a
/// streamed token (VirtualTranscript).
export type MinimapSourceValues = {
  rows: readonly AcpmuxRow[];
  layout: TranscriptLayout;
  /// The transcript's offset as it renders (layout coordinates).
  scrollTop: number;
  /// Whether the transcript scrolls at all (its layout, dock space included, is taller than it).
  scrolls: boolean;
  /// Where `rows` first differs from the last snapshot (model.ts minimapTurns).
  change?: RowsChange;
};

/// The rail's stable handle on the transcript's rows, layout and offset (ThreadMinimap `source`). The
/// transcript writes each render's values into it and passes `update`'s version beside it: the version
/// moves only when the rail would draw something else (a prompt, a tick, the band of prompts on screen,
/// the full-height map's proportions), so a token that only grows the live reply renders no rail. The
/// rail reads the latest values from it when it draws, and its handlers when they run.
export class MinimapSource {
  current: MinimapSourceValues | undefined;
  private version = 0;
  /// The mounted rail's check: whether `next` changes what it drew last commit. Absent while no rail is
  /// mounted, when every render is a new version.
  private probe: ((next: MinimapSourceValues) => boolean) | undefined;
  /// The mounted rail's probe, from its commit until `clearProbe`.
  setProbe(probe: (next: MinimapSourceValues) => boolean) {
    this.probe = probe;
  }
  clearProbe(probe: (next: MinimapSourceValues) => boolean) {
    if (this.probe === probe) this.probe = undefined;
  }
  /// Takes this render's values; the version the rail renders at.
  update(next: MinimapSourceValues): number {
    const was = this.current;
    this.current = next;
    if (
      !was ||
      was.rows !== next.rows ||
      was.layout !== next.layout ||
      was.scrollTop !== next.scrollTop ||
      was.scrolls !== next.scrolls ||
      was.change !== next.change
    )
      if (!this.probe || this.probe(next)) this.version += 1;
    return this.version;
  }
}

/// One MinimapSource for the transcript's life.
export function useMinimapSource(): MinimapSource {
  const [source] = useState(() => new MinimapSource());
  return source;
}
