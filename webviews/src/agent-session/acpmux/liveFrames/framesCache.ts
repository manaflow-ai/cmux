// The frames read so far per turn, at most `limit` (the oldest read goes first), so a strip that
// scrolls back into view draws at once. Same contract as turnShots.ts `TurnShotCache`: a read that
// failed is not kept (the next draw asks again); one that found nothing is.
import { createContext } from "react";
import type { TurnFrame, TurnFramesReader } from "./turnFrames";

type Entry = { read: Promise<TurnFrame[]>; settled?: { frames: TurnFrame[] } };

export class TurnFramesCache {
  private readonly reads = new Map<string, Entry>();
  constructor(private readonly limit = 8) {}

  peek(key: string): { frames: TurnFrame[] } | undefined {
    return this.reads.get(key)?.settled;
  }

  read(key: string, load: () => Promise<TurnFrame[]>): Promise<TurnFrame[]> {
    const kept = this.reads.get(key);
    if (kept) {
      this.reads.delete(key);
      this.reads.set(key, kept);
      return kept.read;
    }
    const entry: Entry = {
      read: load().then(
        (frames) => {
          entry.settled = { frames };
          return frames;
        },
        () => {
          if (this.reads.get(key) === entry) this.reads.delete(key);
          return [];
        },
      ),
    };
    this.reads.set(key, entry);
    while (this.reads.size > this.limit) this.reads.delete(this.reads.keys().next().value!);
    return entry.read;
  }
}

/// The pane provides it (undefined where acpmux has no `turn-frames-v1`): no reader, no strip.
export const TurnFramesContext = createContext<TurnFramesReader | undefined>(undefined);
