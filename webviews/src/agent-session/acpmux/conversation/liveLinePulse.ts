// The running turn's live line hears each event without drawing for it. The transcript shapes the
// line again on every streamed chunk and tool output line (turns.ts `codexLiveTurn`), and four of its
// fields move on each: `quietKey` and `heardKey` (the reply's version, the rows' last event) and their
// times. They change what the line shows only when a quiet or silent stretch ends, so the transcript
// notes the newest line here (VirtualTranscript) and the line's frame does not draw for them
// (virtualTranscriptModel.ts `sameRowDraw`); the line (Thinking.tsx) listens here and draws when what
// it shows changes. Under a streamed reply its frame drew once per chunk (490 times in one heavy
// typing run, 1,500 rows, 60 chunks/s plus 2,000 tool output lines/s).
import { createContext } from "react";
import type { AcpmuxRow } from "../model";
import { LIVE_THINKING } from "./turns";

/// The fields that move with every event and are heard here, not drawn for.
export const PULSE_FIELDS = ["version", "quietKey", "quietAt", "heardKey", "heardAt"] as const;

export type LiveLinePulse = {
  /// The newest live line the transcript shaped, or undefined before one.
  line(): AcpmuxRow | undefined;
  /// When the line last heard anything, to the next whole second on the page clock: its rows' latest
  /// dated moment (`heardAt`) or when a newer `heardKey` was noted, whichever is later. Undefined
  /// before the line changed under this transcript (the line's own fields say when it mounted).
  heard(): number | undefined;
  /// Called after a newer line's pulse fields changed; returns the unsubscribe.
  subscribe(listener: () => void): () => void;
};

export type LiveLinePulseSource = LiveLinePulse & {
  /// The transcript's rows of this pass: notes their live line, if one is drawn.
  note(rows: readonly AcpmuxRow[]): void;
};

/// How far from the end the live line can sit: after it only the todo list or a held prompt's rows.
const LINE_TAIL = 8;

export function createLiveLinePulse(now: () => number = Date.now): LiveLinePulseSource {
  let current: AcpmuxRow | undefined;
  let heard: number | undefined;
  const listeners = new Set<() => void>();
  return {
    line: () => current,
    heard: () => heard,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    note(rows) {
      let line: AcpmuxRow | undefined;
      for (let index = rows.length - 1; index >= Math.max(0, rows.length - LINE_TAIL); index -= 1)
        if (rows[index]!.id === LIVE_THINKING) {
          line = rows[index];
          break;
        }
      if (!line || line === current) return;
      const before = current;
      current = line;
      if (!before || PULSE_FIELDS.every((field) => Object.is(before[field], line[field]))) return;
      if (line.heardKey !== undefined && line.heardKey !== before.heardKey) {
        const at = Math.max(line.heardAt ?? 0, now());
        heard = Math.ceil(at / 1000) * 1000;
      }
      for (const listener of listeners) listener();
    },
  };
}

/// The transcript's pulse; null outside a transcript (galleries, tests), where the line draws for every change.
export const LiveLinePulseContext = createContext<LiveLinePulse | null>(null);
