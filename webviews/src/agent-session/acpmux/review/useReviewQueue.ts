// The Review queue's reads (reviewModel.ts): each candidate folder's `git.diff` (Branch, else
// Uncommitted when the folder has no base), read only for the folders within `READ_WINDOW` of the end
// of what is shown, at most `READ_CONCURRENCY` at once. `extend` reads further (the cursor neared the
// end). A folder is read again when its chat does something (its read key moves); nothing is read on
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
  const [extra, setExtra] = useState(0);
  const running = useRef(0);
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
    const next: ReviewCandidate[] = nextReads(candidates, reads, shown.reached, READ_WINDOW + extra).slice(0, free);
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
          // Only the folders still listed keep a read: the map never outgrows the candidates.
          const keep = new Set(candidates.map(readKey));
          const map = new Map([...previous].filter(([key]) => keep.has(key)));
          map.set(readKey(candidate), result);
          return map;
        });
      });
    }
  }, [candidates, reads, shown.reached, extra, read]);

  const extend = useCallback(() => setExtra((value) => value + READ_WINDOW), []);
  return { ...shown, extend, total: candidates.length };
}
