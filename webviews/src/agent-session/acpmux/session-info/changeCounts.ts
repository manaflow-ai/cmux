// Environment's Changes row (EnvironmentSection.tsx): the chat folder's git changes, added and removed
// lines, read from the session host's `git.diff` with no patch. The work not yet committed when there
// is any, else what the branch's own commits change against its base, so work an agent already
// committed still shows (Lucas, 2026-11-05: a chat that committed its file showed no Changes). A
// folder in no repository, a clean branch at its base, or a read that fails: no row.
//
// Read while Session Info shows: once as it opens, and again each time a turn ends (`key`), never on
// a timer. A read that comes back after the panel closed or the chat changed is dropped.
import { useEffect, useState } from "react";

export type ChangeCounts = { additions: number; deletions: number };

/// Reads one `git.diff` scope of the chat's folder, patch left out (direct.ts `gitDiffCounts`).
export type ReadChanges = (scope: "uncommitted" | "branch") => Promise<unknown>;

const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0);

/// A `git.diff` reply's totals, or undefined when it changes nothing (or is no reply at all).
export function countsOf(reply: unknown): ChangeCounts | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const raw = reply as Record<string, unknown>;
  const counts = { additions: count(raw.additions), deletions: count(raw.deletions) };
  return counts.additions + counts.deletions > 0 ? counts : undefined;
}

/// The folder's changes: uncommitted first, else the branch's against its base.
export async function readChangeCounts(read: ReadChanges): Promise<ChangeCounts | undefined> {
  const uncommitted = countsOf(await read("uncommitted").catch(() => undefined));
  if (uncommitted) return uncommitted;
  return countsOf(await read("branch").catch(() => undefined));
}

/// The chat folder's changes while `live`, read again whenever `key` changes (a chat, a turn's end).
export function useChangeCounts(read: ReadChanges | undefined, live: boolean, key: string): ChangeCounts | undefined {
  const [state, setState] = useState<{ key: string; counts?: ChangeCounts }>({ key: "" });
  useEffect(() => {
    if (!read || !live) return;
    let current = true;
    void readChangeCounts(read).then((counts) => {
      if (current) setState({ key, counts });
    });
    return () => {
      current = false;
    };
  }, [read, live, key]);
  // Another chat's counts never show while this chat's read is in flight.
  return state.key.split("\u0000")[0] === key.split("\u0000")[0] ? state.counts : undefined;
}
