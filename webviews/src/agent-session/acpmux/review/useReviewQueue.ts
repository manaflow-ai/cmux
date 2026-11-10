// The Review queue's reads (reviewModel.ts): each candidate folder's `git.diff` (Branch, else
// Uncommitted when the folder has no base), read only until the rows reach `READ_WINDOW` past the
// cursor, at most `READ_CONCURRENCY` at once. `extend(index)` moves that mark with the cursor; a
// finished read never pulls in more by itself. A folder is read again when its chat does something (its read key moves); nothing is read on
// a timer, and every read that answers after the page unmounted is dropped.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSessionEntry } from "../sessionList";
import {
  nextReads,
  READ_CONCURRENCY,
  READ_WINDOW,
  readKey,
  readReviewStat,
  reviewCandidates,
  reviewRows,
  type ReviewCandidate,
  type ReviewRead,
  type ReviewStat,
} from "./reviewModel";

/// Reads one `git.diff` scope of `cwd`, with no patch (the host's `git.diff {cwd, scope}`).
export type ReadDiff = (cwd: string, scope: ReviewStat["scope"]) => Promise<unknown>;

async function readFolder(read: ReadDiff, cwd: string): Promise<ReviewRead> {
  try {
    return { state: "read", stat: readReviewStat(await read(cwd, "branch"), "branch") };
  } catch {
    // No base branch to compare with (a plain checkout): what is not committed yet.
    try {
      return { state: "read", stat: readReviewStat(await read(cwd, "uncommitted"), "uncommitted") };
    } catch {
      return { state: "failed" };
    }
  }
}

export function useReviewQueue(
  sessions: readonly AcpmuxSessionEntry[],
  read: ReadDiff,
  local: ReadonlySet<string>,
  now?: number,
) {
  const candidates = useMemo(() => reviewCandidates(sessions, now), [sessions, now]);
  const [reads, setReads] = useState<ReadonlyMap<string, ReviewRead>>(() => new Map());
  const [want, setWant] = useState(READ_WINDOW);
  const running = useRef(0);
  /// The candidates as of the last render: a read that answers late prunes against these, not the
  /// list it started with.
  const latest = useRef(candidates);
  latest.current = candidates;
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const shown = useMemo(() => reviewRows(candidates, reads, local), [candidates, reads, local]);

  useEffect(() => {
    const free = READ_CONCURRENCY - running.current;
    if (free <= 0) return;
    const next: ReviewCandidate[] = nextReads(candidates, reads, shown, want).slice(0, free);
    if (next.length === 0) return;
    running.current += next.length;
    setReads((previous) => {
      const map = new Map(previous);
      for (const candidate of next) map.set(readKey(candidate), { state: "reading" });
      return map;
    });
    for (const candidate of next) {
      void readFolder(read, candidate.key).then((result) => {
        running.current -= 1;
        if (!alive.current) return;
        setReads((previous) => {
          // Only the folders still listed keep a read: the map never outgrows the candidates, and a
          // read whose folder moved on (its chat did something since) is dropped.
          const keep = new Set(latest.current.map(readKey));
          const map = new Map([...previous].filter(([key]) => keep.has(key)));
          if (keep.has(readKey(candidate))) map.set(readKey(candidate), result);
          return map;
        });
      });
    }
  }, [candidates, reads, shown, want, read]);

  /// The cursor is on row `index`: read until `READ_WINDOW` rows show past it.
  const extend = useCallback((index: number) => setWant((value) => Math.max(value, index + 1 + READ_WINDOW)), []);
  return { ...shown, extend, total: candidates.length };
}
